//
//  TransitionMatrixTests.swift
//  TetherSessionCoreTests
//
//  Edge case 12: the full phase × event cross-product. Every pair either
//  matches the reference transition table or produces `[]` + exactly one
//  diagnostic line, with the phase unchanged. This enumerates the whole
//  matrix so no transition is accidental.
//

import XCTest
@testable import TetherSessionCore

final class TransitionMatrixTests: XCTestCase {

    func testFullCrossProduct() {
        let phases: [SessionPhase] = [
            .idle,
            .bootstrapping,
            .startingShell,
            .active,
            .suspended,
            .tearingDown,
            .closed,
            .failed(.bootstrapFailed("x")),
            .failed(.engineCrashed(exitCode: 1)),
            .failed(.ptyError("x")),
            .failed(.workspaceUnavailable),
            .failed(.rootfsRemoved),
        ]

        // shellExited appears twice (0 and non-zero) to cover both branches.
        let events: [SessionEvent] = [
            .workspaceOpened,
            .bootstrapSucceeded,
            .bootstrapFailed("x"),
            .shellStarted,
            .shellExited(code: 0),
            .shellExited(code: 7),
            .appBackgrounded,
            .appForegrounded,
            .rootfsRemovedExternally,
            .workspaceBecameUnavailable,
            .ptyFailed("x"),
            .userRequestedClose,
            .teardownFinished,
            .retryRequested,
        ]

        var assertions = 0

        for phase in phases {
            for event in events {
                let machine = SessionStateMachine()
                Spec.driveTo(machine, phase)
                XCTAssertTrue(Spec.samePhase(machine.phase, phase), "driveTo failed for \(phase)")

                let diagBefore = machine.diagnostics.count
                let commands = machine.handle(event)
                let reference = Spec.transition(phase, event)

                switch reference {
                case .illegal:
                    // Must return [], leave the phase unchanged, and log one line.
                    XCTAssertEqual(commands, [], "\(phase) + \(event) should be illegal")
                    XCTAssertTrue(Spec.samePhase(machine.phase, phase),
                                  "\(phase) + \(event) must not change phase")
                    XCTAssertEqual(machine.diagnostics.count, diagBefore + 1,
                                   "\(phase) + \(event) must append exactly one diagnostic")
                case .legal(let newPhase, let expectedCommands, let info):
                    XCTAssertEqual(commands, expectedCommands,
                                   "\(phase) + \(event) command list mismatch")
                    XCTAssertEqual(machine.phase, newPhase,
                                   "\(phase) + \(event) new-phase mismatch")
                    XCTAssertEqual(machine.diagnostics.count, diagBefore + (info ? 1 : 0),
                                   "\(phase) + \(event) diagnostic delta mismatch")
                }

                assertions += 4
            }
        }

        // This single test alone contributes hundreds of assertions.
        XCTAssertGreaterThan(assertions, 500)
    }

    func testIllegalEventsProduceExactlyOneDiagnosticLine() {
        // Representative: illegal events accumulate diagnostics but never break.
        let machine = SessionStateMachine()
        for event: SessionEvent in [.appBackgrounded, .shellStarted, .retryRequested, .teardownFinished] {
            let before = machine.diagnostics.count
            XCTAssertEqual(machine.handle(event), [])
            XCTAssertEqual(machine.diagnostics.count, before + 1)
        }
        XCTAssertEqual(machine.phase, .idle)
    }
}
