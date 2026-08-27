//
//  TeardownIdempotenceTests.swift
//  TetherSessionCoreTests
//
//  The PTY hard invariant demands teardown never be issued twice. These tests
//  lock in that teardown is idempotent under duplicate requests and racing
//  shell-exit events.
//

import XCTest
@testable import TetherSessionCore

final class TeardownIdempotenceTests: XCTestCase {

    private func liveMachine() -> SessionStateMachine {
        let m = SessionStateMachine()
        _ = m.handle(.workspaceOpened)
        _ = m.handle(.bootstrapSucceeded)
        _ = m.handle(.shellStarted)
        XCTAssertEqual(m.phase, .active)
        return m
    }

    func testRepeatedCloseNeverIssuesDuplicateCommands() {
        let m = liveMachine()
        let first = m.handle(.userRequestedClose)
        XCTAssertEqual(first, Spec.fullTeardown())

        // Fire close again and again: each must return [] and not re-issue.
        for _ in 0..<3 {
            let before = m.diagnostics.count
            XCTAssertEqual(m.handle(.userRequestedClose), [])
            XCTAssertEqual(m.diagnostics.count, before + 1)
        }
    }

    func testCloseFromSuspendedUsesIdenticalFullTeardown() {
        let m = liveMachine()
        _ = m.handle(.appBackgrounded)
        XCTAssertEqual(m.phase, .suspended)

        let cmds = m.handle(.userRequestedClose)
        XCTAssertEqual(cmds, Spec.fullTeardown())
        XCTAssertEqual(m.phase, .tearingDown)
    }

    func testShellExitRacingTeardownDoesNotDoubleClose() {
        let m = liveMachine()
        _ = m.handle(.userRequestedClose)

        // shellExited fires during teardown (the engine dies mid-teardown).
        XCTAssertEqual(m.handle(.shellExited(code: 130)), [])
        XCTAssertEqual(m.phase, .tearingDown)
        // Then the real completion lands.
        XCTAssertEqual(m.handle(.teardownFinished), [])
        XCTAssertEqual(m.phase, .closed)
    }

    func testTeardownSequenceNeverClosesPTYBeforeWriterStarts() {
        // Walk the full teardown list and assert the descriptor-close step is
        // strictly after the reader-stop step in every teardown-style sequence.
        let m = liveMachine()
        let full = m.handle(.userRequestedClose)

        let stopIdx = full.firstIndex(of: .stopOutputPump)!
        let closeIdx = full.firstIndex(of: .closePTYAfterReaderStops)!
        XCTAssertLessThan(stopIdx, closeIdx, "reader must stop before PTY close")

        // Rootfs removal sequence obeys the same invariant.
        let m2 = liveMachine()
        let rootfs = m2.handle(.rootfsRemovedExternally)
        XCTAssertLessThan(rootfs.firstIndex(of: .stopOutputPump)!,
                          rootfs.firstIndex(of: .closePTYAfterReaderStops)!)
    }

    func testFailurePathAlreadyToreDownThenCloseOnlyReleasesScope() {
        let m = liveMachine()
        _ = m.handle(.ptyFailed("x"))
        XCTAssertEqual(m.phase, .failed(.ptyError("x")))

        // The failure path already ran (stopOutputPump, closePTY, ...). The
        // later close must only release the workspace scope — no duplicate teardown.
        let cmds = m.handle(.userRequestedClose)
        XCTAssertEqual(cmds, [.releaseWorkspaceScope])
        XCTAssertEqual(m.phase, .tearingDown)
        XCTAssertEqual(m.handle(.teardownFinished), [])
        XCTAssertEqual(m.phase, .closed)
    }
}
