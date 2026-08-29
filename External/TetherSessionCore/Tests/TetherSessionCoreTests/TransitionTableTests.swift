//
//  TransitionTableTests.swift
//  TetherSessionCoreTests
//
//  Every legal row of the behavioral-specification table asserted verbatim,
//  plus the numbered edge cases 1–7.
//

import XCTest
@testable import TetherSessionCore

final class TransitionTableTests: XCTestCase {

    private func newMachine() -> SessionStateMachine { SessionStateMachine() }

    // MARK: Edge case 1 — full happy path

    func testHappyPathVerbatim() {
        let m = newMachine()
        XCTAssertEqual(m.phase, .idle)

        // idle -> bootstrapping
        XCTAssertEqual(m.handle(.workspaceOpened), [.startBootstrap])
        XCTAssertEqual(m.phase, .bootstrapping)

        // bootstrapping -> startingShell
        XCTAssertEqual(m.handle(.bootstrapSucceeded), [.startShell])
        XCTAssertEqual(m.phase, .startingShell)

        // startingShell -> active
        XCTAssertEqual(m.handle(.shellStarted), [.restoreSavedScrollback])
        XCTAssertEqual(m.phase, .active)

        // active -> tearingDown (full teardown, verbatim)
        XCTAssertEqual(m.handle(.userRequestedClose), Spec.fullTeardown())
        XCTAssertEqual(m.diagnostics.count, 0)
        XCTAssertEqual(m.phase, .tearingDown)

        // tearingDown -> closed
        XCTAssertEqual(m.handle(.teardownFinished), [])
        XCTAssertEqual(m.phase, .closed)

        XCTAssertEqual(m.diagnostics.count, 0)
    }

    // MARK: Edge case 2 — rootfs removed while active

    func testRootfsRemovedWhileActive() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        let cmds = m.handle(.rootfsRemovedExternally)
        XCTAssertEqual(m.phase, .failed(.rootfsRemoved))
        XCTAssertEqual(cmds, Spec.rootfsRemoved())

        // .markNeedsBootstrap must come BEFORE .showFailure(_: .rootfsRemoved).
        let markIndex = cmds.firstIndex(of: .markNeedsBootstrap)!
        let showIndex = cmds.firstIndex(of: .showFailure(.rootfsRemoved))!
        XCTAssertLessThan(markIndex, showIndex)
        // And .showFailure must come before .releaseWorkspaceScope.
        XCTAssertLessThan(showIndex, cmds.firstIndex(of: .releaseWorkspaceScope)!)
    }

    // MARK: Edge case 3 — double userRequestedClose

    func testDoubleUserRequestedClose() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        let first = m.handle(.userRequestedClose)
        XCTAssertEqual(first, Spec.fullTeardown())

        let diagCount = m.diagnostics.count
        let second = m.handle(.userRequestedClose)
        XCTAssertEqual(second, [])                       // never a duplicate command list
        XCTAssertEqual(m.phase, .tearingDown)
        XCTAssertEqual(m.diagnostics.count, diagCount + 1)
    }

    // MARK: Edge case 4 — shellExited during tearingDown

    func testShellExitedDuringTeardownDoesNotDuplicateClose() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)
        _ = m.handle(.userRequestedClose)

        let diagCount = m.diagnostics.count
        let cmds = m.handle(.shellExited(code: 9))
        XCTAssertEqual(cmds, [])
        XCTAssertEqual(m.phase, .tearingDown)
        XCTAssertEqual(m.diagnostics.count, diagCount + 1)
        XCTAssertTrue(m.diagnostics.last!.contains("tearingDown"))

        // Machine still proceeds to closed from teardownFinished.
        XCTAssertEqual(m.handle(.teardownFinished), [])
        XCTAssertEqual(m.phase, .closed)
    }

    // MARK: Edge case 5 — crash loop guard, twice on one instance

    func testCrashLoopRetryTwice() {
        let m = newMachine()
        let diagnosticsStart = m.diagnostics.count

        for _ in 1...2 {
            _ = m.handle(.workspaceOpened)
            XCTAssertEqual(m.phase, .bootstrapping)
            _ = m.handle(.bootstrapSucceeded)
            _ = m.handle(.shellStarted)
            XCTAssertEqual(m.phase, .active)

            let cmds = m.handle(.shellExited(code: 7))
            XCTAssertEqual(m.phase, .failed(.engineCrashed(exitCode: 7)))
            XCTAssertEqual(cmds, Spec.crashed(7))

            _ = m.handle(.retryRequested)
            XCTAssertEqual(m.phase, .bootstrapping)
        }

        // Diagnostics accumulated (illegal events only here — but also ensure
        // the machine carried no state between rounds incorrectly).
        _ = m.handle(.bootstrapSucceeded)
        XCTAssertEqual(m.phase, .startingShell)
        _ = m.handle(.shellStarted)
        XCTAssertEqual(m.phase, .active)
        XCTAssertGreaterThanOrEqual(m.diagnostics.count, diagnosticsStart)
    }

    // MARK: Edge case 6 — appBackgrounded during bootstrapping/startingShell

    func testAppBackgroundedDuringBootstrapIsIllegal() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)          // bootstrapping

        let diagCount = m.diagnostics.count
        let cmds = m.handle(.appBackgrounded)
        XCTAssertEqual(cmds, [])
        XCTAssertEqual(m.phase, .bootstrapping) // unchanged
        XCTAssertEqual(m.diagnostics.count, diagCount + 1)

        // Bootstrap simply continues (iOS grants background time during bootstrap).
        XCTAssertEqual(m.handle(.bootstrapSucceeded), [.startShell])
        XCTAssertEqual(m.phase, .startingShell)
        XCTAssertEqual(m.handle(.shellStarted), [.restoreSavedScrollback])
        // Shell is live before any suspension is possible.
        XCTAssertEqual(m.phase, .active)
    }

    func testAppBackgroundedDuringStartingShellIsIllegal() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)       // startingShell

        let diagCount = m.diagnostics.count
        let cmds = m.handle(.appBackgrounded)
        XCTAssertEqual(cmds, [])
        XCTAssertEqual(m.phase, .startingShell)
        XCTAssertEqual(m.diagnostics.count, diagCount + 1)

        XCTAssertEqual(m.handle(.shellStarted), [.restoreSavedScrollback])
        XCTAssertEqual(m.phase, .active)
    }

    // MARK: Edge case 7 — deferred workspace check

    func testWorkspaceUnavailableWhileSuspendedIsDeferred() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)
        _ = m.handle(.appBackgrounded)
        XCTAssertEqual(m.phase, .suspended)

        // Not in the table: tolerated, phase unchanged, diagnostic recorded.
        let diagCount = m.diagnostics.count
        XCTAssertEqual(m.handle(.workspaceBecameUnavailable), [])
        XCTAssertEqual(m.phase, .suspended)
        XCTAssertEqual(m.diagnostics.count, diagCount + 1)

        // On foreground the integrator re-checks and may send it from active.
        XCTAssertEqual(m.handle(.appForegrounded), [])
        XCTAssertEqual(m.phase, .active)
        let cmds = m.handle(.workspaceBecameUnavailable)
        XCTAssertEqual(cmds, Spec.workspaceUnavailable())
        XCTAssertEqual(m.phase, .failed(.workspaceUnavailable))
    }

    // MARK: Additional table rows (verbatim)

    func testIdleRows() {
        let m = newMachine()
        // All other events illegal in idle.
        for event: SessionEvent in [.bootstrapSucceeded, .shellStarted, .shellExited(code: 0),
                                    .appBackgrounded, .appForegrounded, .rootfsRemovedExternally,
                                    .workspaceBecameUnavailable, .ptyFailed("x"), .userRequestedClose,
                                    .teardownFinished, .retryRequested, .bootstrapFailed("x")] {
            XCTAssertEqual(m.handle(event), [])
            XCTAssertEqual(m.phase, .idle)
        }
    }

    func testBootstrappingFailRows() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)

        // bootstrapFailed -> failed + showFailure
        let failCmds = m.handle(.bootstrapFailed("no init"))
        XCTAssertEqual(m.phase, .failed(.bootstrapFailed("no init")))
        XCTAssertEqual(
            failCmds,
            [.showFailure(.bootstrapFailed("no init")), .releaseWorkspaceScope]
        )

        // failed -> retry -> bootstrapping -> bootstrapSucceeded...
        _ = m.handle(.retryRequested)
        XCTAssertEqual(m.phase, .bootstrapping)
        _ = m.handle(.workspaceBecameUnavailable)
        XCTAssertEqual(m.phase, .failed(.workspaceUnavailable))
        XCTAssertEqual(m.diagnostics.count, 0)
    }

    func testStartingShellFailRows() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)

        // ptyFailed during startingShell
        let pty = m.handle(.ptyFailed("no pty"))
        XCTAssertEqual(m.phase, .failed(.ptyError("no pty")))
        XCTAssertEqual(pty, [.showFailure(.ptyError("no pty")), .releaseWorkspaceScope])

        _ = m.handle(.retryRequested)
        _ = m.handle(.bootstrapSucceeded)

        // shellExited during startingShell -> engineCrashed
        let exit = m.handle(.shellExited(code: 11))
        XCTAssertEqual(m.phase, .failed(.engineCrashed(exitCode: 11)))
        XCTAssertEqual(exit, [.showFailure(.engineCrashed(exitCode: 11)),
                              .stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope])
    }

    func testActiveCleanExitGoesToTeardownNotFailed() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        XCTAssertEqual(m.handle(.shellExited(code: 0)), Spec.cleanExit())
        XCTAssertEqual(m.phase, .tearingDown)
        XCTAssertTrue(m.diagnostics.isEmpty)
        XCTAssertEqual(m.handle(.teardownFinished), [])
        XCTAssertEqual(m.phase, .closed)
    }

    func testActiveCrashSequenceOrdering() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        // code != 0
        let cmds = m.handle(.shellExited(code: 42))
        XCTAssertEqual(m.phase, .failed(.engineCrashed(exitCode: 42)))
        XCTAssertEqual(cmds, Spec.crashed(42))
        // emitRestoreSequence before showFailure; showFailure before stopOutputPump;
        // stopOutputPump before closePTYAfterReaderStops; close before release.
        let order: [SessionCommand] = [.emitRestoreSequence, .showFailure(.engineCrashed(exitCode: 42)),
                                       .stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope]
        var idx = 0
        for cmd in order {
            let i = cmds.firstIndex(of: cmd)!
            XCTAssertGreaterThanOrEqual(i, idx)
            idx = i
        }
    }

    func testActiveWorkspaceUnavailableSequence() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        let cmds = m.handle(.workspaceBecameUnavailable)
        XCTAssertEqual(m.phase, .failed(.workspaceUnavailable))
        XCTAssertEqual(cmds, Spec.workspaceUnavailable())
        // No .markNeedsBootstrap in the workspace-unavailable case.
        XCTAssertFalse(cmds.contains(.markNeedsBootstrap))
    }

    func testActivePtyFailedSequence() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        let cmds = m.handle(.ptyFailed("hangup"))
        XCTAssertEqual(m.phase, .failed(.ptyError("hangup")))
        XCTAssertEqual(cmds, Spec.ptyFailed("hangup"))
    }

    func testSuspendResumeCycleKeepsSessionAlive() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)

        XCTAssertEqual(m.handle(.appBackgrounded), [.snapshotScrollback])
        XCTAssertEqual(m.phase, .suspended)
        XCTAssertEqual(m.handle(.appForegrounded), [])
        XCTAssertEqual(m.phase, .active)
    }

    func testFailedFromBootstrapCloseReleasesScope() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapFailed("boom"))
        XCTAssertEqual(m.phase, .failed(.bootstrapFailed("boom")))

        let cmds = m.handle(.userRequestedClose)
        XCTAssertEqual(cmds, [.releaseWorkspaceScope])
        XCTAssertEqual(m.phase, .tearingDown)
        XCTAssertEqual(m.handle(.teardownFinished), [])
        XCTAssertEqual(m.phase, .closed)
    }

    func testClosedMachineIsReusable() {
        let m = newMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)
        _ = m.handle(.userRequestedClose)
        _ = m.handle(.teardownFinished)
        XCTAssertEqual(m.phase, .closed)

        XCTAssertEqual(m.handle(.workspaceOpened), [.startBootstrap])
        XCTAssertEqual(m.phase, .bootstrapping)
        XCTAssertEqual(m.handle(.bootstrapSucceeded), [.startShell])
        XCTAssertEqual(m.phase, .startingShell)
    }
}
