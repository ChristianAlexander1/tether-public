import Foundation
import TermXLinux
import TermXUI
import TetherSessionCore
import TetherStorageCore

/// Executes `SessionCommand`s against the live app services for one workspace.
///
/// Before this existed, lifecycle work was spread across `WorkspaceView`'s
/// `onDisappear`, a rootfs-removal notification handler, and teardown inside
/// `TerminalSession` — three places that each knew part of the ordering. Here
/// the ordering comes from the tested state machine and this type only carries
/// out the steps.
@MainActor
final class WorkspaceSessionServices: SessionServices {
    private let workspaceID: String
    private let integration: TermXIntegration
    private let scrollback: ScrollbackStore
    private let releaseScope: () -> Void
    private let presentFailure: (SessionFailure) -> Void
    private let makeShell: () -> TerminalSession
    private let didStartShell: (TerminalSession) -> Void

    /// The live session. Lifecycle services retain the resource they own until
    /// teardown is complete; relying only on SwiftUI state made startup
    /// cancellation capable of deallocating the session mid-bootstrap.
    private(set) var session: TerminalSession?
    /// Routes the engine callback back into the session state machine.
    var shellExited: ((Int32) -> Void)?
    /// Supplies the terminal's current mode state for a snapshot.
    var modeStateProvider: (() -> Data)?

    /// Bytes recovered from a previous run, replayed on the next open.
    private(set) var pendingRestore: ScrollbackSnapshot?

    /// Lease owner for this session. Unique per session so two open
    /// workspaces each hold their own, and Storage can name who is blocking.
    private lazy var leaseOwner = "terminal-session-\(workspaceID)"
    private var holdsRootfsLease = false
    private var bootstrapTask: Task<Void, Never>?

    init(
        workspaceID: String,
        integration: TermXIntegration,
        scrollback: ScrollbackStore,
        makeShell: @escaping () -> TerminalSession,
        didStartShell: @escaping (TerminalSession) -> Void,
        releaseScope: @escaping () -> Void,
        presentFailure: @escaping (SessionFailure) -> Void
    ) {
        self.workspaceID = workspaceID
        self.integration = integration
        self.scrollback = scrollback
        self.makeShell = makeShell
        self.didStartShell = didStartShell
        self.releaseScope = releaseScope
        self.presentFailure = presentFailure
        self.pendingRestore = scrollback.take(for: workspaceID)
    }

    // MARK: - SessionServices

    func startBootstrap(completion: @escaping (Result<Void, Error>) -> Void) {
        acquireRootfsLeaseIfNeeded()
        let linux = integration.linux
        bootstrapTask?.cancel()
        bootstrapTask = Task {
            defer { bootstrapTask = nil }
            do {
                linux.invalidateIfRootfsMissing()
                if linux.state != .ready {
                    try await linux.bootstrap()
                }
                guard !Task.isCancelled else { return }
                completion(.success(()))
            } catch {
                guard !Task.isCancelled else { return }
                completion(.failure(error))
            }
        }
    }

    func startShell(completion: @escaping (Result<Void, Error>) -> Void) {
        acquireRootfsLeaseIfNeeded()
        do {
            let started = makeShell()
            session = started
            modeStateProvider = { [weak started] in
                started?.terminalRestoreProvider?() ?? Data()
            }
            started.onShellExited = { [weak self] code in
                self?.shellExited?(code)
            }
            try started.start()
            didStartShell(started)
            completion(.success(()))
        } catch {
            session = nil
            completion(.failure(error))
        }
    }

    func emitRestoreSequence() {
        session?.repairTerminalModes()
    }

    func restoreSavedScrollback() {
        guard let snapshot = pendingRestore, let session else { return }
        pendingRestore = nil
        var payload = Data("\r\n[restored session view]\r\n".utf8)
        payload.append(snapshot.rawBytes)
        payload.append(snapshot.trailingModeState)
        session.renderWithoutRecording(payload)
    }

    func snapshotScrollback() {
        guard let session else { return }
        let snapshot = ScrollbackSnapshot(
            cols: session.cols,
            rows: session.rows,
            rawBytes: session.recentOutputTail(maxBytes: ScrollbackSnapshot.maxRawBytes),
            // The mode state is the sequence that returns a terminal to a sane
            // state, so a restore never reopens inside a dead alternate screen.
            trailingModeState: modeStateProvider?() ?? Data()
        )
        scrollback.save(snapshot, for: workspaceID)
    }

    func stopOutputPump() {
        session?.stopOutputPumpForTeardown()
    }

    func signalShell(_ name: String) {
        // Signalling and closing are separate lifecycle commands. Calling
        // terminate() here used to close the PTY before the state machine's
        // wait/reader-stop steps, recreating the crash this layer exists to
        // prevent.
        session?.signalShell(name)
    }

    func waitForEngineExit(graceMillis: Int) {
        session?.waitForEngineExit(graceMillis: graceMillis)
    }

    func closePTYAfterReaderStops() {
        session?.closePTYAfterReaderStops()
    }

    func releaseWorkspaceScope() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        // The lease outlives every other teardown step for the same reason the
        // scope does: anything still draining may touch the rootfs.
        if holdsRootfsLease {
            TetherStorage.shared.endSessionUse(.linuxRootfs, owner: leaseOwner)
            holdsRootfsLease = false
        }
        releaseScope()
    }

    private func acquireRootfsLeaseIfNeeded() {
        guard !holdsRootfsLease else { return }
        TetherStorage.shared.beginSessionUse(.linuxRootfs, owner: leaseOwner)
        holdsRootfsLease = true
    }

    func showFailure(_ failure: SessionFailure) {
        presentFailure(failure)
    }

    func markNeedsBootstrap() {
        integration.linux.markNeedsBootstrap()
    }
}
