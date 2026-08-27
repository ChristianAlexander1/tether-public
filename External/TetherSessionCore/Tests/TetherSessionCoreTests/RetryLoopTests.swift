//
//  RetryLoopTests.swift
//  TetherSessionCoreTests
//
//  Crash-loop guard: a single machine instance can fail, retry, and fail again
//  repeatedly without leaking state, and diagnostics accumulate monotonically.
//

import XCTest
@testable import TetherSessionCore

final class RetryLoopTests: XCTestCase {

    func testCrashRetryLoopTwiceOnOneInstance() {
        let m = SessionStateMachine()
        let initialDiagnostics = m.diagnostics.count

        // First round starts from idle via workspaceOpened.
        XCTAssertEqual(m.handle(.workspaceOpened), [.startBootstrap])
        XCTAssertEqual(m.phase, .bootstrapping)

        var rounds = 0
        for expectedExit in [Int32(70), Int32(71)] {
            // Deliver bootstrap + shell for the current cycle. On the first
            // cycle we are already in bootstrapping (opened above); on later
            // cycles we arrive here via retryRequested below.
            XCTAssertEqual(m.phase, .bootstrapping)
            XCTAssertEqual(m.handle(.bootstrapSucceeded), [.startShell])
            XCTAssertEqual(m.phase, .startingShell)
            XCTAssertEqual(m.handle(.shellStarted), [])
            XCTAssertEqual(m.phase, .active)

            // Crash.
            let cmds = m.handle(.shellExited(code: expectedExit))
            XCTAssertEqual(m.phase, .failed(.engineCrashed(exitCode: expectedExit)))
            XCTAssertEqual(cmds, Spec.crashed(expectedExit))
            rounds += 1

            // Retry returns to bootstrapping (the machine is reusable).
            XCTAssertEqual(m.handle(.retryRequested), [.startBootstrap])
            XCTAssertEqual(m.phase, .bootstrapping)
        }
        XCTAssertEqual(rounds, 2)

        // Prior diagnostic state was never erased across the two crash loops.
        XCTAssertGreaterThanOrEqual(m.diagnostics.count, initialDiagnostics)
    }

    func testRetryFromEveryFailureKindReturnsToBootstrap() {
        let failures: [SessionFailure] = [
            .bootstrapFailed("x"),
            .engineCrashed(exitCode: 5),
            .ptyError("x"),
            .workspaceUnavailable,
            .rootfsRemoved,
        ]
        for failure in failures {
            let m = SessionStateMachine()

            // Drive to a point from which this failure kind is legally reachable.
            switch failure {
            case .bootstrapFailed(let msg):
                _ = m.handle(.workspaceOpened)        // bootstrapping
                _ = m.handle(.bootstrapFailed(msg))
            case .engineCrashed(let code):
                _ = m.handle(.workspaceOpened)
                _ = m.handle(.bootstrapSucceeded)
                _ = m.handle(.shellStarted)           // active
                _ = m.handle(.shellExited(code: code))
            case .ptyError(let msg):
                _ = m.handle(.workspaceOpened)
                _ = m.handle(.bootstrapSucceeded)
                _ = m.handle(.shellStarted)           // active
                _ = m.handle(.ptyFailed(msg))
            case .workspaceUnavailable:
                _ = m.handle(.workspaceOpened)
                _ = m.handle(.bootstrapSucceeded)
                _ = m.handle(.shellStarted)           // active
                _ = m.handle(.workspaceBecameUnavailable)
            case .rootfsRemoved:
                _ = m.handle(.workspaceOpened)
                _ = m.handle(.bootstrapSucceeded)
                _ = m.handle(.shellStarted)           // active
                _ = m.handle(.rootfsRemovedExternally)
            }

            XCTAssertEqual(m.phase, .failed(failure), "could not reach failed(\(failure))")

            XCTAssertEqual(m.handle(.retryRequested), [.startBootstrap])
            XCTAssertEqual(m.phase, .bootstrapping, "retry from \(failure) must return to bootstrapping")
            XCTAssertEqual(m.handle(.bootstrapSucceeded), [.startShell])
            XCTAssertEqual(m.phase, .startingShell)
        }
    }

    func testDiagnosticsAreNeverResetAcrossRetries() {
        let m = SessionStateMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)
        _ = m.handle(.appBackgrounded)   // legal -> suspended

        // Illegal while suspended: workspaceBecameUnavailable.
        let countAfterIllegal = m.diagnostics.count
        _ = m.handle(.workspaceBecameUnavailable)
        XCTAssertEqual(m.diagnostics.count, countAfterIllegal + 1)

        _ = m.handle(.appForegrounded)
        _ = m.handle(.shellExited(code: 2))   // crash -> failed

        // Retry, complete, and confirm prior diagnostics are still present.
        _ = m.handle(.retryRequested)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)
        XCTAssertEqual(m.phase, .active)
        XCTAssertGreaterThanOrEqual(m.diagnostics.count, countAfterIllegal + 1)
    }
}
