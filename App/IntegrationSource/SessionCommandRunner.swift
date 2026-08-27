import Foundation
import TetherSessionCore

/// The real services a `SessionCommand` acts on.
///
/// Split out as a protocol so the ordering guarantees the state machine makes
/// can be tested without a PTY, a rootfs, or a security-scoped bookmark. The
/// app supplies the live implementation; tests supply a recorder.
public protocol SessionServices: AnyObject {
    /// Begin rootfs bootstrap. Must report back with
    /// `.bootstrapSucceeded` / `.bootstrapFailed`.
    func startBootstrap(completion: @escaping (Result<Void, Error>) -> Void)
    /// Spawn the guest engine and attach the PTY reader. Must report back with
    /// `.shellStarted` / `.ptyFailed`.
    func startShell(completion: @escaping (Result<Void, Error>) -> Void)
    /// Re-render the screen from the most recent snapshot.
    func emitRestoreSequence()
    /// Serialize the current scrollback and persist it.
    func snapshotScrollback()
    /// Stop the reader thread and join it.
    func stopOutputPump()
    /// Send a signal to the guest shell.
    func signalShell(_ name: String)
    /// Wait up to `graceMillis` for the engine to exit, then continue anyway.
    func waitForEngineExit(graceMillis: Int)
    /// Close the PTY — only legal once the reader has stopped.
    func closePTYAfterReaderStops()
    /// Release the security-scoped bookmark.
    func releaseWorkspaceScope()
    /// Surface a failure to the user.
    func showFailure(_ failure: SessionFailure)
    /// Flag the rootfs as needing a fresh bootstrap.
    func markNeedsBootstrap()
}

/// Drives `SessionStateMachine` against real services.
///
/// This replaces lifecycle logic that used to be spread across
/// `WorkspaceView.onDisappear`, a rootfs-removal notification handler, and ad
/// hoc teardown in `TerminalSession`. The value is not just tidiness: the
/// machine encodes the teardown order — signal, wait for exit, stop the
/// reader, *then* close the PTY — that keeps the app from closing a descriptor
/// a thread is still blocked on.
///
/// Not thread-safe by design, matching the machine. Drive it from one queue;
/// the app drives it from the main actor.
public final class SessionCommandRunner {
    private let machine: SessionStateMachine
    private let services: SessionServices
    /// Guards against a completion callback re-entering `send` while an
    /// earlier command list is still being executed, which would interleave
    /// two orderings.
    private var isExecuting = false
    private var queuedEvents: [SessionEvent] = []

    public init(machine: SessionStateMachine = SessionStateMachine(), services: SessionServices) {
        self.machine = machine
        self.services = services
    }

    public var phase: SessionPhase { machine.phase }
    public var diagnostics: [String] { machine.diagnostics }

    /// Feed an event and execute whatever the machine asks for, in order.
    public func send(_ event: SessionEvent) {
        queuedEvents.append(event)
        guard !isExecuting else { return }
        isExecuting = true
        defer { isExecuting = false }
        while !queuedEvents.isEmpty {
            let next = queuedEvents.removeFirst()
            for command in machine.handle(next) {
                execute(command)
            }
        }
    }

    private func execute(_ command: SessionCommand) {
        switch command {
        case .startBootstrap:
            services.startBootstrap { [weak self] result in
                switch result {
                case .success:
                    self?.send(.bootstrapSucceeded)
                case .failure(let error):
                    self?.send(.bootstrapFailed(error.localizedDescription))
                }
            }
        case .startShell:
            services.startShell { [weak self] result in
                switch result {
                case .success:
                    self?.send(.shellStarted)
                case .failure(let error):
                    self?.send(.ptyFailed(error.localizedDescription))
                }
            }
        case .emitRestoreSequence:
            services.emitRestoreSequence()
        case .snapshotScrollback:
            services.snapshotScrollback()
        case .stopOutputPump:
            services.stopOutputPump()
        case .signalShell(let name):
            services.signalShell(name)
        case .waitForEngineExit(let graceMillis):
            services.waitForEngineExit(graceMillis: graceMillis)
        case .closePTYAfterReaderStops:
            services.closePTYAfterReaderStops()
        case .releaseWorkspaceScope:
            services.releaseWorkspaceScope()
        case .showFailure(let failure):
            services.showFailure(failure)
        case .markNeedsBootstrap:
            services.markNeedsBootstrap()
        }
    }
}
