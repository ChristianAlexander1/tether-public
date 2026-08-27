import Foundation
import TetherSessionCore
import XCTest
@testable import TermXIntegration

/// Records every command in the order it was executed, so the ordering
/// guarantees the state machine makes can be asserted end to end through the
/// runner — not just inside the pure package.
private final class RecordingServices: SessionServices {
    enum Step: Equatable {
        case startBootstrap
        case startShell
        case emitRestoreSequence
        case snapshotScrollback
        case stopOutputPump
        case signalShell(String)
        case waitForEngineExit(Int)
        case closePTY
        case releaseScope
        case showFailure(SessionFailure)
        case markNeedsBootstrap
    }

    private(set) var steps: [Step] = []
    var bootstrapResult: Result<Void, Error> = .success(())
    var shellResult: Result<Void, Error> = .success(())
    /// When set, completions are stored instead of fired, so a test can control
    /// exactly when the feedback event arrives.
    var deferCompletions = false
    private var pendingBootstrap: ((Result<Void, Error>) -> Void)?
    private var pendingShell: ((Result<Void, Error>) -> Void)?

    func startBootstrap(completion: @escaping (Result<Void, Error>) -> Void) {
        steps.append(.startBootstrap)
        if deferCompletions { pendingBootstrap = completion } else { completion(bootstrapResult) }
    }

    func startShell(completion: @escaping (Result<Void, Error>) -> Void) {
        steps.append(.startShell)
        if deferCompletions { pendingShell = completion } else { completion(shellResult) }
    }

    func finishBootstrap() { pendingBootstrap?(bootstrapResult); pendingBootstrap = nil }
    func finishShell() { pendingShell?(shellResult); pendingShell = nil }

    func emitRestoreSequence() { steps.append(.emitRestoreSequence) }
    func snapshotScrollback() { steps.append(.snapshotScrollback) }
    func stopOutputPump() { steps.append(.stopOutputPump) }
    func signalShell(_ name: String) { steps.append(.signalShell(name)) }
    func waitForEngineExit(graceMillis: Int) { steps.append(.waitForEngineExit(graceMillis)) }
    func closePTYAfterReaderStops() { steps.append(.closePTY) }
    func releaseWorkspaceScope() { steps.append(.releaseScope) }
    func showFailure(_ failure: SessionFailure) { steps.append(.showFailure(failure)) }
    func markNeedsBootstrap() { steps.append(.markNeedsBootstrap) }
}

private struct TestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SessionCommandRunnerTests: XCTestCase {
    func testHappyPathRunsBootstrapThenShellAndReachesActive() {
        let services = RecordingServices()
        let runner = SessionCommandRunner(services: services)

        runner.send(.workspaceOpened)

        XCTAssertEqual(services.steps, [.startBootstrap, .startShell])
        XCTAssertEqual(runner.phase, .active)
    }

    /// The invariant the whole component exists to protect: the PTY descriptor
    /// is closed only after the reader thread has been stopped. Closing it
    /// under a blocked reader is a crash, so this order is not cosmetic.
    func testTeardownStopsTheReaderBeforeClosingThePTY() {
        let services = RecordingServices()
        let runner = SessionCommandRunner(services: services)
        runner.send(.workspaceOpened)

        runner.send(.userRequestedClose)

        let teardown = services.steps.drop { $0 == .startBootstrap || $0 == .startShell }
        let stopIndex = try? XCTUnwrap(teardown.firstIndex(of: .stopOutputPump))
        let closeIndex = try? XCTUnwrap(teardown.firstIndex(of: .closePTY))
        let releaseIndex = try? XCTUnwrap(teardown.firstIndex(of: .releaseScope))
        XCTAssertNotNil(stopIndex)
        XCTAssertNotNil(closeIndex)
        XCTAssertLessThan(stopIndex!, closeIndex!, "the reader must stop before the PTY closes")
        XCTAssertLessThan(closeIndex!, releaseIndex!, "the scope is released last")

        runner.send(.teardownFinished)
        XCTAssertEqual(runner.phase, .closed)
    }

    func testBootstrapFailureSurfacesAFailureAndStopsShortOfTheShell() {
        let services = RecordingServices()
        services.bootstrapResult = .failure(TestError(message: "no network"))
        let runner = SessionCommandRunner(services: services)

        runner.send(.workspaceOpened)

        XCTAssertFalse(services.steps.contains(.startShell), "must not start a shell on a failed rootfs")
        XCTAssertTrue(services.steps.contains { step in
            if case .showFailure(.bootstrapFailed(let message)) = step { return message.contains("no network") }
            return false
        })
    }

    /// A completion that fires while an earlier command list is still being
    /// executed must not interleave two orderings.
    func testReentrantCompletionIsQueuedRatherThanInterleaved() {
        let services = RecordingServices()
        services.deferCompletions = true
        let runner = SessionCommandRunner(services: services)

        runner.send(.workspaceOpened)
        XCTAssertEqual(services.steps, [.startBootstrap])
        XCTAssertEqual(runner.phase, .bootstrapping)

        services.finishBootstrap()
        XCTAssertEqual(services.steps, [.startBootstrap, .startShell])

        services.finishShell()
        XCTAssertEqual(runner.phase, .active)
    }

    func testRootfsRemovedMarksNeedsBootstrapBeforeSurfacingTheFailure() {
        let services = RecordingServices()
        let runner = SessionCommandRunner(services: services)
        runner.send(.workspaceOpened)

        runner.send(.rootfsRemovedExternally)

        guard let markIndex = services.steps.firstIndex(of: .markNeedsBootstrap) else {
            return XCTFail("rootfs removal must flag a re-bootstrap")
        }
        guard let failureIndex = services.steps.firstIndex(of: .showFailure(.rootfsRemoved)) else {
            return XCTFail("rootfs removal must surface a defined failure, not crash")
        }
        XCTAssertLessThan(markIndex, failureIndex)
    }

    func testBackgroundingAnActiveSessionSnapshotsScrollback() {
        let services = RecordingServices()
        let runner = SessionCommandRunner(services: services)
        runner.send(.workspaceOpened)

        runner.send(.appBackgrounded)

        XCTAssertEqual(runner.phase, .suspended)
        XCTAssertTrue(services.steps.contains(.snapshotScrollback))
    }
}
