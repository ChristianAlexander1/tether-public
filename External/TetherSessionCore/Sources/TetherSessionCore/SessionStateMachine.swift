//
//  SessionStateMachine.swift
//  TetherSessionCore
//
//  A pure, synchronous state machine describing the entire lifecycle of a
//  terminal session in an iOS host app. It receives `SessionEvent`s and
//  returns ordered lists of `SessionCommand`s. It never touches a PTY, file,
//  or process — the integrator executes the returned commands and feeds the
//  resulting events back in.
//
//  Design constraints this machine is built around:
//   * The app can be suspended at any moment (iOS may freeze our processes).
//   * A security-scoped folder bookmark can go stale while suspended.
//   * The emulated-Linux rootfs directory can be deleted from a Storage screen
//     while a shell is running.
//   * Only one guest machine may run at a time.
//   * HARD INVARIANT: a PTY descriptor must NEVER be closed while a reader
//     thread is still blocked on it. That is why teardown is expressed as an
//     ordered command list, not a single "close" event.
//

// MARK: - Public value types
// MARK: Failure

/// A terminal, human-presentable reason why a session stopped.
public enum SessionFailure: Equatable, Sendable {
    case bootstrapFailed(String)
    case engineCrashed(exitCode: Int32)
    case ptyError(String)
    case workspaceUnavailable
    case rootfsRemoved
}

// MARK: Phase

/// The lifecycle phase of a single terminal session.
public enum SessionPhase: Equatable, Sendable {
    /// Not yet opened. No workspace, nothing running.
    case idle
    /// Workspace opened; rootfs bootstrap in progress.
    case bootstrapping
    /// Bootstrap done; shell starting.
    case startingShell
    /// Shell running and interactive.
    case active
    /// App backgrounded while a live session is active.
    case suspended
    /// Teardown in progress (ordered commands in flight).
    case tearingDown
    /// The session failed; waiting for `retryRequested` or `userRequestedClose`.
    case failed(SessionFailure)
    /// Fully closed; the machine is reusable from a fresh `workspaceOpened`.
    case closed
}

// MARK: Event

/// Events the host app feeds into the machine.
public enum SessionEvent: Equatable, Sendable {
    case workspaceOpened
    case bootstrapSucceeded
    case bootstrapFailed(String)
    case shellStarted
    case shellExited(code: Int32)
    case appBackgrounded
    case appForegrounded
    case rootfsRemovedExternally
    case workspaceBecameUnavailable
    case ptyFailed(String)
    case userRequestedClose
    case teardownFinished
    case retryRequested
}

// MARK: Command

/// Imperative things the integrator should do, in the order returned.
public enum SessionCommand: Equatable, Sendable {
    case startBootstrap
    case startShell
    case emitRestoreSequence
    case restoreSavedScrollback
    case snapshotScrollback
    case stopOutputPump
    case signalShell(String)
    case waitForEngineExit(graceMillis: Int)
    case closePTYAfterReaderStops
    case releaseWorkspaceScope
    case showFailure(SessionFailure)
    case markNeedsBootstrap
}

// MARK: - The machine

/// A pure state machine for one terminal session.
///
/// ## Ordering rationale preserved by every command list
/// The following ordering invariants are intentional and MUST be preserved by
/// the integrator (they correspond to the statements in the specification):
///
///  * **`snapshotScrollback` before `emitRestoreSequence`** — the snapshot
///    captures the live TUI bytes and the terminal-mode repair they require;
///    the restore command then repairs the current live renderer. Snapshot
///    first, repair second. Saved snapshot replay is a separate startup
///    command (`restoreSavedScrollback`).
///
///  * **`signalShell` → `waitForEngineExit` → `stopOutputPump` →
///    `closePTYAfterReaderStops`** — we politely signal the guest (drain
///    remaining output), wait for the engine to actually exit, then stop the
///    output pump (reader), and only **after** the reader has stopped do we
///    close the PTY descriptor. This satisfies the hard invariant that a PTY
///    must never be closed while a reader thread is blocked on it.
///
///  * **`releaseWorkspaceScope` always last** — the security-scoped bookmark
///    scope is released only after every reader/descriptor touching the
///    workspace has been torn down.
public final class SessionStateMachine {

    /// The current phase. Read-only from the public API.
    public private(set) var phase: SessionPhase = .idle

    /// Human-readable lines describing illegal or informational transitions.
    /// Grows monotonically; never reset.
    public private(set) var diagnostics: [String] = []

    public init() {}

    // MARK: Transition table helpers (command lists, in the exact mandated order)

    /// Full teardown from a *live* session (active or suspended close).
    private static func fullTeardown() -> [SessionCommand] {
        [
            .snapshotScrollback,
            .emitRestoreSequence,
            .signalShell("SIGHUP"),
            .waitForEngineExit(graceMillis: 2000),
            .stopOutputPump,
            .closePTYAfterReaderStops,
            .releaseWorkspaceScope,
        ]
    }

    /// Engine exited non-zero while `active`/`suspended`.
    private static func crashedCommands(_ code: Int32) -> [SessionCommand] {
        [
            .emitRestoreSequence,
            .showFailure(.engineCrashed(exitCode: code)),
            .stopOutputPump,
            .closePTYAfterReaderStops,
            .releaseWorkspaceScope,
        ]
    }

    /// `ptyFailed` while `active`/`suspended`.
    private static func ptyFailedCommands(_ msg: String) -> [SessionCommand] {
        [
            .showFailure(.ptyError(msg)),
            .stopOutputPump,
            .closePTYAfterReaderStops,
            .releaseWorkspaceScope,
        ]
    }

    /// The rootfs was deleted out from under a live shell.
    private static func rootfsRemovedCommands() -> [SessionCommand] {
        [
            .emitRestoreSequence,
            .signalShell("SIGHUP"),
            .waitForEngineExit(graceMillis: 1000),
            .stopOutputPump,
            .closePTYAfterReaderStops,
            .markNeedsBootstrap,
            .showFailure(.rootfsRemoved),
            .releaseWorkspaceScope,
        ]
    }

    /// The workspace became unavailable while a live shell was running.
    /// Identical to rootfs removal except: no `.markNeedsBootstrap` (the
    /// workspace itself is gone, so re-bootstrapping is pointless) and the
    /// failure is `.workspaceUnavailable`.
    private static func workspaceUnavailableCommands() -> [SessionCommand] {
        [
            .emitRestoreSequence,
            .signalShell("SIGHUP"),
            .waitForEngineExit(graceMillis: 1000),
            .stopOutputPump,
            .closePTYAfterReaderStops,
            .showFailure(.workspaceUnavailable),
            .releaseWorkspaceScope,
        ]
    }

    /// A clean shell exit (code==0) while live: user typed `exit`.
    private static func cleanExitCommands() -> [SessionCommand] {
        [
            .stopOutputPump,
            .closePTYAfterReaderStops,
            .releaseWorkspaceScope,
        ]
    }

    // MARK: The transition table

    /// Apply one event. Returns the ordered command list for the transition
    /// (possibly empty). An illegal event for the current phase returns `[]`,
    /// leaves the phase unchanged, and appends a human-readable line to
    /// `diagnostics`. It never traps or crashes.
    public func handle(_ event: SessionEvent) -> [SessionCommand] {
        switch phase {

        // ---------------- From .idle ----------------
        case .idle:
            switch event {
            case .workspaceOpened:
                return transition(.bootstrapping, [.startBootstrap], event)
            default:
                return illegal(event)
            }

        // ---------------- From .bootstrapping ----------------
        case .bootstrapping:
            switch event {
            case .bootstrapSucceeded:
                return transition(.startingShell, [.startShell], event)
            case .bootstrapFailed(let msg):
                let failure = SessionFailure.bootstrapFailed(msg)
                return transition(
                    .failed(failure),
                    [.showFailure(failure), .releaseWorkspaceScope],
                    event
                )
            case .userRequestedClose:
                return transition(.tearingDown, [.releaseWorkspaceScope], event)
            case .workspaceBecameUnavailable:
                return transition(
                    .failed(.workspaceUnavailable),
                    [.showFailure(.workspaceUnavailable), .releaseWorkspaceScope],
                    event
                )
            default:
                return illegal(event)
            }

        // ---------------- From .startingShell ----------------
        case .startingShell:
            switch event {
            case .shellStarted:
                return transition(.active, [.restoreSavedScrollback], event)
            case .ptyFailed(let msg):
                let failure = SessionFailure.ptyError(msg)
                return transition(
                    .failed(failure),
                    [.showFailure(failure), .releaseWorkspaceScope],
                    event
                )
            case .shellExited(let code):
                let failure = SessionFailure.engineCrashed(exitCode: code)
                return transition(
                    .failed(failure),
                    [
                        .showFailure(failure),
                        .stopOutputPump,
                        .closePTYAfterReaderStops,
                        .releaseWorkspaceScope,
                    ],
                    event
                )
            case .userRequestedClose:
                return transition(.tearingDown, Self.fullTeardown(), event)
            default:
                return illegal(event)
            }

        // ---------------- From .active ----------------
        case .active:
            switch event {
            case .userRequestedClose:
                return transition(.tearingDown, Self.fullTeardown(), event)
            case .shellExited(let code):
                if code == 0 {
                    return transition(.tearingDown, Self.cleanExitCommands(), event)
                } else {
                    return transition(.failed(.engineCrashed(exitCode: code)), Self.crashedCommands(code), event)
                }
            case .ptyFailed(let msg):
                return transition(.failed(.ptyError(msg)), Self.ptyFailedCommands(msg), event)
            case .rootfsRemovedExternally:
                return transition(.failed(.rootfsRemoved), Self.rootfsRemovedCommands(), event)
            case .workspaceBecameUnavailable:
                return transition(.failed(.workspaceUnavailable), Self.workspaceUnavailableCommands(), event)
            case .appBackgrounded:
                return transition(.suspended, [.snapshotScrollback], event)
            default:
                return illegal(event)
            }

        // ---------------- From .suspended ----------------
        case .suspended:
            switch event {
            case .appForegrounded:
                return transition(.active, [], event)
            case .shellExited(let code):
                // "As in active": preserve the clean-exit (code==0) vs crash split.
                if code == 0 {
                    return transition(.tearingDown, Self.cleanExitCommands(), event)
                } else {
                    return transition(.failed(.engineCrashed(exitCode: code)), Self.crashedCommands(code), event)
                }
            case .rootfsRemovedExternally:
                return transition(.failed(.rootfsRemoved), Self.rootfsRemovedCommands(), event)
            case .userRequestedClose:
                return transition(.tearingDown, Self.fullTeardown(), event)
            default:
                return illegal(event)
            }

        // ---------------- From .tearingDown ----------------
        case .tearingDown:
            switch event {
            case .teardownFinished:
                return transition(.closed, [], event)
            case .shellExited:
                // Already tearing down — informational only; never duplicate close commands.
                note("Informational: shellExited during tearingDown; teardown already in progress.")
                return []
            case .userRequestedClose:
                // Idempotent teardown — never a duplicate command list.
                note("Informational: repeated userRequestedClose during tearingDown; ignored.")
                return []
            default:
                return illegal(event)
            }

        // ---------------- From .failed(_) ----------------
        case .failed:
            switch event {
            case .retryRequested:
                return transition(.bootstrapping, [.startBootstrap], event)
            case .userRequestedClose:
                // Rest was already done on the failure path; just release the scope.
                return transition(.tearingDown, [.releaseWorkspaceScope], event)
            default:
                return illegal(event)
            }

        // ---------------- From .closed ----------------
        case .closed:
            switch event {
            case .workspaceOpened:
                return transition(.bootstrapping, [.startBootstrap], event)
            default:
                return illegal(event)
            }
        }
    }

    // MARK: Private helpers

    /// Execute a legal transition: set the phase and return the commands.
    @discardableResult
    private func transition(
        _ newPhase: SessionPhase,
        _ commands: [SessionCommand],
        _ event: SessionEvent
    ) -> [SessionCommand] {
        phase = newPhase
        return commands
    }

    /// Illegal (phase, event) pair: leave phase unchanged, return `[]`, log a
    /// human-readable line. Never traps.
    private func illegal(_ event: SessionEvent) -> [SessionCommand] {
        let line = "Illegal event \(event) for phase \(phase); ignored."
        diagnostics.append(line)
        return []
    }

    /// Append an informational note to diagnostics without changing the phase.
    private func note(_ line: String) {
        diagnostics.append(line)
    }
}
