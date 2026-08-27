import Foundation
@testable import TetherJobControl
import XCTest

final class RegistrationTests: XCTestCase {
    func testBasicRegistration() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: true))
        XCTAssertEqual(id.raw, 1000)
        XCTAssertEqual(table.state(of: id), .spawning)
        XCTAssertNotNil(table.foreground)
        XCTAssertEqual(table.foreground?.raw, 1000)
        XCTAssertFalse(table.jobs(in: ProcessGroupID(raw: id.raw)).isEmpty)
        XCTAssertTrue(table.diagnostics.isEmpty)
        XCTAssertEqual(table.jobs(in: ProcessGroupID(raw: id.raw)).count, 1)
    }

    func testUnknownGroupCreatesGroup() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let group = ProcessGroupID(raw: 999)
        let id = table.register(JobSpec(argv: ["a"], group: group, isForegroundCandidate: false))
        XCTAssertTrue(table.diagnostics.contains { $0.contains("unknown group created: 999") })
        XCTAssertEqual(table.jobs(in: group), [id])
        XCTAssertEqual(table.jobs(in: group).count, 1)
        XCTAssertFalse(table.diagnostics.isEmpty)
    }

    func testMonotonicIds() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id1 = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        let id2 = table.register(JobSpec(argv: ["b"], group: nil, isForegroundCandidate: false))
        XCTAssertEqual(id2.raw, id1.raw + 1)
        XCTAssertNotEqual(id1.raw, id2.raw)
        XCTAssertTrue(id2.raw > id1.raw)
    }

    func testNewGroupForNilGroup() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        XCTAssertEqual(table.jobs(in: ProcessGroupID(raw: id.raw)), [id])
        XCTAssertEqual(table.jobs(in: ProcessGroupID(raw: id.raw)).count, 1)
        XCTAssertEqual(table.foreground, nil)
    }

    func testDoubleExitNoCrash() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        table.markExited(id, code: 0, signal: nil)
        table.markExited(id, code: 1, signal: nil) // double exit, no-op
        XCTAssertEqual(table.state(of: id), .exited(code: 0, signal: nil))
        XCTAssertTrue(table.diagnostics.isEmpty)
    }
}

final class RoutingTests: XCTestCase {
    func testSignalToUnknownJob() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let result = table.signal(.int, to: .job(JobID(raw: 9999)))
        XCTAssertTrue(result.noSuchTarget)
        XCTAssertTrue(result.delivered.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(result.noSuchTarget == false)
    }

    func testSignalToUnknownGroup() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let result = table.signal(.int, to: .group(ProcessGroupID(raw: 9999)))
        XCTAssertTrue(result.noSuchTarget)
        XCTAssertTrue(result.delivered.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testForegroundWithNoForeground() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let result = table.signal(.int, to: .foreground)
        XCTAssertTrue(result.noSuchTarget)
        XCTAssertTrue(result.delivered.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testGroupHalfExited() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        backend.setDeliverable([.int], for: JobID(raw: 1000))
        backend.setDeliverable([.int], for: JobID(raw: 1001))

        let id1 = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        let id2 = table.register(JobSpec(argv: ["b"], group: ProcessGroupID(raw: id1.raw), isForegroundCandidate: false))
        table.markRunning(id2)
        table.markExited(id1, code: 0, signal: nil)

        let result = table.signal(.int, to: .group(ProcessGroupID(raw: id1.raw)))
        XCTAssertFalse(result.noSuchTarget)
        XCTAssertEqual(result.delivered, [id2])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.delivered.count, 1)
        XCTAssertEqual(table.state(of: id1), .exited(code: 0, signal: nil))
    }

    func testWinchBroadcastToGroup() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let groupId = ProcessGroupID(raw: 2000)
        for _ in 0..<50 {
            let id = table.register(JobSpec(argv: ["a"], group: groupId, isForegroundCandidate: false))
            table.markRunning(id)
        }
        let allIds = table.jobs(in: groupId).sorted { $0.raw < $1.raw }
        for i in 7..<50 {
            backend.setDeliverable([.winch], for: allIds[i])
        }

        let result = table.signal(.winch, to: .group(groupId))
        XCTAssertEqual(result.delivered.count, 43)
        XCTAssertEqual(result.failed.count, 7)
        XCTAssertEqual(result.delivered.sorted { $0.raw < $1.raw }, result.delivered)
        XCTAssertFalse(result.noSuchTarget)
        XCTAssertTrue(result.delivered.contains(allIds[7]))
        XCTAssertTrue(result.failed.contains(allIds[0]))
    }

    func testCtrlCStorm() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        backend.setDeliverable([.int], for: JobID(raw: 1000))

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: true))
        table.markRunning(id)

        let r1 = table.signal(.int, to: .foreground)
        let r2 = table.signal(.int, to: .foreground)
        let r3 = table.signal(.int, to: .foreground)

        XCTAssertEqual(r1.delivered, [id])
        XCTAssertEqual(r2.delivered, [id])
        XCTAssertEqual(r3.delivered, [id])
        XCTAssertTrue(r1.noSuchTarget == false)
        XCTAssertTrue(r2.noSuchTarget == false)
        XCTAssertTrue(r3.noSuchTarget == false)
    }

    func testReentrancyStateObservation() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        var observedState: JobState?
        table.onStateChange = { id, state in
            observedState = table.state(of: id)
        }

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        XCTAssertEqual(observedState, .running)
        XCTAssertNotNil(observedState)
    }

    func testUnknownTargetEverywhere() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        let r1 = table.signal(.kill, to: .job(JobID(raw: 1)))
        let r2 = table.signal(.term, to: .group(ProcessGroupID(raw: 2)))
        let r3 = table.signal(.cont, to: .foreground)
        XCTAssertTrue(r1.noSuchTarget)
        XCTAssertTrue(r2.noSuchTarget)
        XCTAssertTrue(r3.noSuchTarget)
    }
}

final class StopContQueueTests: XCTestCase {
    func testTSTPAndCONT() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        backend.setDeliverable([.tstp, .cont], for: JobID(raw: 1000))

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)

        let stopResult = table.signal(.tstp, to: .job(id))
        XCTAssertEqual(stopResult.delivered, [id])
        XCTAssertEqual(stopResult.failed, [])
        XCTAssertFalse(stopResult.noSuchTarget)
        XCTAssertEqual(table.state(of: id), .stopped)

        let contResult = table.signal(.cont, to: .job(id))
        XCTAssertEqual(contResult.delivered, [id])
        XCTAssertTrue(contResult.failed.isEmpty)
        XCTAssertEqual(table.state(of: id), .running)
    }

    func testQueuedSignalsAfterStop() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        backend.setDeliverable([.tstp, .cont], for: JobID(raw: 1000))
        backend.setDeliverable([.int, .winch], for: JobID(raw: 1000))

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)

        table.signal(.tstp, to: .job(id))
        XCTAssertEqual(table.state(of: id), .stopped)

        table.signal(.int, to: .job(id))
        table.signal(.winch, to: .job(id))
        table.signal(.int, to: .job(id))

        let contResult = table.signal(.cont, to: .job(id))
        XCTAssertEqual(contResult.delivered.sorted { $0.raw < $1.raw }, [id])
        XCTAssertFalse(contResult.noSuchTarget)
        XCTAssertTrue(table.state(of: id) == .running || table.state(of: id) == .stopped)
    }

    func testCONTOnRunningJob() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        backend.setDeliverable([.cont], for: JobID(raw: 1000))

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)

        let result = table.signal(.cont, to: .job(id))
        XCTAssertTrue(result.delivered.contains(id))
        XCTAssertEqual(table.state(of: id), .running)
        XCTAssertTrue(result.failed.isEmpty)
    }
}

final class TerminateEscalationTests: XCTestCase {
    func testTERMToKILLToOrphan() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        var orphanCalled = false
        table.onOrphanDetected = { id in orphanCalled = true }

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        backend.setDeliverable([.term], for: id)

        table.terminate(id, graceMillis: 100)
        XCTAssertTrue(backend.forceTerminated.isEmpty)
        XCTAssertFalse(table.diagnostics.contains { $0.contains("reentrancy") })

        clock.advance(millis: 100)
        XCTAssertEqual(backend.forceTerminated.count, 1)
        XCTAssertFalse(orphanCalled)
        XCTAssertTrue(backend.forceTerminated.contains(id))

        clock.advance(millis: 100)
        XCTAssertTrue(orphanCalled)
        XCTAssertTrue(table.diagnostics.isEmpty)
    }

    func testJobExitsBeforeKill() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        backend.setDeliverable([.term], for: id)

        table.terminate(id, graceMillis: 100)
        table.markExited(id, code: 0, signal: nil)

        clock.advance(millis: 100)
        XCTAssertTrue(backend.forceTerminated.isEmpty)
        XCTAssertEqual(table.state(of: id), .exited(code: 0, signal: nil))
        XCTAssertTrue(table.diagnostics.isEmpty)
    }

    func testLateMarkExited() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        var orphanCalled = false
        table.onOrphanDetected = { id in orphanCalled = true }

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        backend.setDeliverable([.term], for: id)

        table.terminate(id, graceMillis: 50)
        clock.advance(millis: 100)
        clock.advance(millis: 50)
        XCTAssertTrue(orphanCalled)

        table.markExited(id, code: 0, signal: nil)
        XCTAssertEqual(table.state(of: id), .exited(code: 0, signal: nil))
    }

    func testTerminateTwice() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        backend.setDeliverable([.term], for: id)

        table.terminate(id, graceMillis: 100)
        table.terminate(id, graceMillis: 50)
        clock.advance(millis: 100)
        XCTAssertTrue(backend.forceTerminated.count >= 1)
        XCTAssertTrue(table.state(of: id) == .running || table.state(of: id) == .stopped || table.state(of: id) == .spawning)
    }

    func testNegativeGrace() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        backend.setDeliverable([.term], for: id)
        table.terminate(id, graceMillis: -10)
        clock.advance(millis: 0)
        XCTAssertEqual(backend.forceTerminated.count, 1)
    }
}

final class ReapTests: XCTestCase {
    func testReapRemovesExited() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markExited(id, code: 0, signal: nil)
        let reaped = table.reapExited()
        XCTAssertEqual(reaped, [id])
        XCTAssertNil(table.state(of: id))
        XCTAssertTrue(table.jobs(in: ProcessGroupID(raw: id.raw)).isEmpty)
    }

    func testReapClearsForeground() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: true))
        table.markExited(id, code: 0, signal: nil)
        table.reapExited()
        XCTAssertNil(table.foreground)
        XCTAssertTrue(table.jobs(in: ProcessGroupID(raw: id.raw)).isEmpty)
        XCTAssertEqual(table.state(of: id), nil)
    }

    func testReapPrunesEmptyGroup() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let groupId = ProcessGroupID(raw: 3000)
        let id = table.register(JobSpec(argv: ["a"], group: groupId, isForegroundCandidate: false))
        table.markExited(id, code: 0, signal: nil)
        let reaped = table.reapExited()
        XCTAssertEqual(reaped, [id])
        XCTAssertTrue(table.jobs(in: groupId).isEmpty)
        XCTAssertEqual(table.jobs(in: groupId).count, 0)
        XCTAssertFalse(table.diagnostics.contains { $0.contains("reentrancy") })
    }

    func testReapMultipleExitedInOrder() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id1 = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        let id2 = table.register(JobSpec(argv: ["b"], group: nil, isForegroundCandidate: false))
        table.markExited(id1, code: 0, signal: nil)
        table.markExited(id2, code: 1, signal: "SIGTERM")
        let reaped = table.reapExited()
        XCTAssertEqual(reaped, [id1, id2])
        XCTAssertTrue(reaped.count == 2)
    }
}

final class ForegroundTests: XCTestCase {
    func testForegroundCandidateTakesForeground() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        XCTAssertNil(table.foreground)
        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: true))
        XCTAssertNotNil(table.foreground)
        XCTAssertEqual(table.foreground?.raw, id.raw)
    }

    func testForegroundHandOffAfterReap() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id1 = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: true))
        table.markExited(id1, code: 0, signal: nil)
        table.reapExited()

        let id2 = table.register(JobSpec(argv: ["b"], group: nil, isForegroundCandidate: true))
        XCTAssertNotNil(table.foreground)
        XCTAssertEqual(table.foreground?.raw, id2.raw)
        XCTAssertTrue(table.diagnostics.isEmpty)
    }
}

final class ReentrancyTests: XCTestCase {
    func testReentrantMarkExitedRejected() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)

        table.onStateChange = { id, state in
            table.markExited(id, code: 0, signal: nil)
        }

        table.markExited(id, code: 0, signal: nil)
        XCTAssertTrue(table.diagnostics.contains { $0.contains("reentrancy blocked") })
        XCTAssertEqual(table.state(of: id), .exited(code: 0, signal: nil))
        XCTAssertNotNil(table.state(of: id))
    }

    func testReentrancyDoesNotCorruptTable() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        let id = table.register(JobSpec(argv: ["a"], group: nil, isForegroundCandidate: false))
        table.markRunning(id)
        table.onStateChange = { id, state in
            // Try mutation
            _ = table.register(JobSpec(argv: ["b"], group: nil, isForegroundCandidate: false))
        }
        table.markExited(id, code: 0, signal: nil)
        XCTAssertTrue(table.diagnostics.contains { $0.contains("reentrancy blocked") })
    }
}

final class ScaleTests: XCTestCase {
    func testScalePerformance() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)

        let groupId = ProcessGroupID(raw: 5000)
        for i in 0..<10000 {
            let id = table.register(JobSpec(argv: ["a"], group: groupId, isForegroundCandidate: false))
            if i % 2 == 0 {
                backend.setDeliverable([.winch], for: id)
            }
        }

        let start = Date()
        let result = table.signal(.winch, to: .group(groupId))
        let duration = Date().timeIntervalSince(start)

        XCTAssertEqual(result.delivered.count, 5000)
        XCTAssertLessThan(duration, 1.0)
        XCTAssertFalse(result.noSuchTarget)
        XCTAssertTrue(duration >= 0)
    }

    func testScaleGroupMembership() {
        let backend = FakeJobBackend()
        let clock = FakeJobClock()
        let table = JobTable(backend: backend, clock: clock)
        let groupId = ProcessGroupID(raw: 6000)
        for _ in 0..<100 {
            _ = table.register(JobSpec(argv: ["a"], group: groupId, isForegroundCandidate: false))
        }
        XCTAssertEqual(table.jobs(in: groupId).count, 100)
    }
}
