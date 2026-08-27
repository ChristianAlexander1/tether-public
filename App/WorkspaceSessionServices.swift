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
    private let startShellHandler: (@escaping (Result<Void, Error>) -> Void) -> Void

    /// The live session, set once the shell starts and cleared on teardown.
    weak var session: TerminalSession?
    /// Supplies the terminal's current mode state for a snapshot.
    var modeStateProvider: (() -> Data)?

    /// Bytes recovered from a previous run, replayed on the next open.
    private(set) var pendingRestore: ScrollbackSnapshot?

    /// Lease owner for this session. Unique per session so two open
    /// workspaces each hold their own, and Storage can name who is blocking.
    private lazy var leaseOwner = "terminal-session-\(workspaceID)"
    private var holdsRootfsLease = false

    init(
        workspaceID: String,
        integration: TermXIntegration,
        scrollback: ScrollbackStore,
        startShell: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void,
        releaseScope: @escaping () -> Void,
        presentFailure: @escaping (SessionFailure) -> Void
    ) {
        self.workspaceID = workspaceID
        self.integration = integration
        self.scrollback = scrollback
        self.startShellHandler = startShell
        self.releaseScope = releaseScope
        self.presentFailure = presentFailure
        self.pendingRestore = scrollback.take(for: workspaceID)
    }

    // MARK: - SessionServices

    func startBootstrap(completion: @escaping (Result<Void, Error>) -> Void) {
        let linux = integration.linux
        Task {
            do {
                try await linux.bootstrap()
                await MainActor.run { completion(.success(())) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    func startShell(completion: @escaping (Result<Void, Error>) -> Void) {
        // Take the lease before the shell exists: Storage must never be able to
        // delete the rootfs a session is about to execute out of.
        if !holdsRootfsLease {
            TetherStorage.shared.beginSessionUse(.linuxRootfs, owner: leaseOwner)
            holdsRootfsLease = true
        }
        startShellHandler(completion)
    }

    func emitRestoreSequence() {
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
        switch name {
        case "SIGINT": session?.interrupt()
        default: session?.terminate()
        }
    }

    func waitForEngineExit(graceMillis: Int) {
        session?.waitForEngineExit(graceMillis: graceMillis)
    }

    func closePTYAfterReaderStops() {
        session?.closePTYAfterReaderStops()
    }

    func releaseWorkspaceScope() {
        // The lease outlives every other teardown step for the same reason the
        // scope does: anything still draining may touch the rootfs.
        if holdsRootfsLease {
            TetherStorage.shared.endSessionUse(.linuxRootfs, owner: leaseOwner)
            holdsRootfsLease = false
        }
        releaseScope()
    }

    func showFailure(_ failure: SessionFailure) {
        presentFailure(failure)
    }

    func markNeedsBootstrap() {
        integration.linux.markNeedsBootstrap()
    }
}
