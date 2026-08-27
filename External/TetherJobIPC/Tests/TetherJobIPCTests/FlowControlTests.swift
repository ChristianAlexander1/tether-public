import XCTest
import Foundation
import TetherJobIPC
import TetherJobIPCTestSupport

/// Backpressure accounting: 262,144-byte per-pid unacknowledged window, chunk
/// flushing on ack, and `onFlowWindowOpen`.
final class FlowControlTests: XCTestCase {

    private let window = 262_144
    private let chunkLimit = 65_536

    private func handshaken() -> JIPTestHarness {
        let h = JIPTestHarness()
        h.sendHello(id: 1)
        XCTAssertTrue(h.session.isHandshakeComplete)
        h.resetReceived()   // clear the hello res; measure only post-handshake frames.
        return h
    }

    // MARK: Behavior 10 — window exhausts at exactly 262,144 bytes

    func testWindowSendsExactlyBudgetThenBuffersUntilAck() {
        let h = handshaken()
        let total = 300_000
        let input = Data(repeating: 0x42, count: total)

        h.session.pushStdout(pid: 42, data: input)

        // Exactly 262,144 raw bytes worth of stdout frames were sent (4 chunks).
        XCTAssertEqual(h.rawBytes(ofType: "spawn.stdout"), window, "in-flight budget")
        let sentEvents = h.messages(ofType: "spawn.stdout")
        XCTAssertEqual(sentEvents.count, window / chunkLimit)
        for e in sentEvents {
            let chunk = Data(base64Encoded: e.string("dataB64")!)!
            XCTAssertLessThanOrEqual(chunk.count, chunkLimit)
        }
        // Nothing beyond the budget should be on the wire yet.
        XCTAssertEqual(h.received.filter { $0.type != "spawn.stdout" }.count, 0)
        XCTAssertEqual(h.flowWindowReopens, 0, "no reopen before an ack")

        // Ack 100 KiB → window reopens, buffered remainder flushes in order.
        h.sendEvent(type: "flow.ack", body: ["pid": 42, "bytes": 102_400])

        // Now the full 300,000 raw bytes are on the wire.
        XCTAssertEqual(h.rawBytes(ofType: "spawn.stdout"), total)
        XCTAssertEqual(h.flowWindowReopens, 1)
        XCTAssertEqual(h.flowWindowPids, [42])

        // The flushed chunk is byte-for-byte the continuation of the stream.
        let allEvents = h.messages(ofType: "spawn.stdout")
        var reassembled = Data()
        for e in allEvents {
            reassembled.append(Data(base64Encoded: e.string("dataB64")!)!)
        }
        XCTAssertEqual(reassembled, input)
    }

    // MARK: Behavior 13 — exit flushes the pending buffer and frees accounting

    func testExitFlushesBufferedChunkLastAndFreesAccounting() {
        let h = handshaken()
        let input = Data(repeating: 0x43, count: 300_000)
        h.session.pushStdout(pid: 42, data: input)
        XCTAssertEqual(h.rawBytes(ofType: "spawn.stdout"), window)

        // Exit must flush the 37,856 buffered bytes, then send the exit frame.
        h.session.pushExit(pid: 42, code: 0, signal: nil)

        XCTAssertEqual(h.rawBytes(ofType: "spawn.stdout"), 300_000)
        XCTAssertEqual(h.received.last?.type, "spawn.exit", "exit is the last frame")

        // Accounting is freed: the pid is still marked exited (kill -> ESRCH),
        // and a late ack for it is ignored rather than resurrecting it.
        h.sendEvent(type: "flow.ack", body: ["pid": 42, "bytes": 200_000])
        XCTAssertEqual(h.received.last?.type, "spawn.exit", "no new frames after exit")
        h.sendRequest(type: "spawn.kill", id: 2, body: ["pid": 42, "signal": "SIGTERM"])
        XCTAssertEqual(h.response(id: 2)?.code, "ESRCH")
        XCTAssertEqual(h.flowWindowReopens, 0, "exit flush does not count as a reopen")
    }

    // MARK: Behavior 12 — stdin window 0 is advisory, never rejected

    func testZeroStdinWindowIsAdvisoryAndStillForwards() {
        let h = handshaken()
        h.delegate.spawnStdinWindow = 0
        let b64 = Data("hello".utf8).base64EncodedString()

        h.sendRequest(type: "spawn.stdin", id: 2, body: ["pid": 42, "dataB64": b64])
        let res1 = h.response(id: 2)
        XCTAssertEqual(res1?.ok, true)
        XCTAssertEqual(res1?.int("window"), 0)

        // The policy is: the server never rejects on a zero window; the client pauses.
        // So a second write is still forwarded to the delegate.
        h.sendRequest(type: "spawn.stdin", id: 3, body: ["pid": 42, "dataB64": b64])
        let res2 = h.response(id: 3)
        XCTAssertEqual(res2?.ok, true)
        XCTAssertEqual(res2?.int("window"), 0)
        XCTAssertEqual(h.delegate.calls.filter { $0.hasPrefix("spawnStdin") }.count, 2)
    }

    func testStdinWindowEchoesDelegateValue() {
        let h = handshaken()
        h.delegate.spawnStdinWindow = 12_345
        let b64 = Data("x".utf8).base64EncodedString()
        h.sendRequest(type: "spawn.stdin", id: 2, body: ["pid": 42, "dataB64": b64])
        XCTAssertEqual(h.response(id: 2)?.int("window"), 12_345)
    }

    // MARK: Ack for an unknown pid is ignored

    func testAckForUnknownPidIsIgnored() {
        let h = handshaken()
        h.sendEvent(type: "flow.ack", body: ["pid": 999, "bytes": 100])
        XCTAssertTrue(h.protocolErrors.isEmpty)
        XCTAssertFalse(h.pair.isAClosed)
        XCTAssertEqual(h.received.count, 0)
    }

    // MARK: stderr shares the same per-pid window

    func testStdoutAndStderrShareOneWindowPerPid() {
        let h = handshaken()
        let a = Data(repeating: 0x61, count: 131_072)  // 2 chunkLimit chunks
        let b = Data(repeating: 0x62, count: 131_072)  // 2 chunkLimit chunks
        let c = Data(repeating: 0x63, count: 65_536)   // 1 chunkLimit chunk
        h.session.pushStdout(pid: 42, data: a)
        h.session.pushStderr(pid: 42, data: b)
        h.session.pushStdout(pid: 42, data: c)         // window now full; buffers

        // 262,144 allowed and exactly filled by a+b; c is buffered.
        XCTAssertEqual(h.rawBytes(ofType: "spawn.stdout") + h.rawBytes(ofType: "spawn.stderr"),
                       window)

        h.sendEvent(type: "flow.ack", body: ["pid": 42, "bytes": 65_536])
        // Window reopened; the 65,536 buffered chunk flushes after it.
        XCTAssertEqual(h.rawBytes(ofType: "spawn.stdout") + h.rawBytes(ofType: "spawn.stderr"),
                       window + 65_536)
        XCTAssertEqual(h.flowWindowReopens, 1)

        // Reassembly preserves exact stream order (stdout, then stderr, then the
        // flushed stdout tail).
        var reassembled = Data()
        for m in h.messages(ofType: "spawn.stdout") {
            reassembled.append(Data(base64Encoded: m.string("dataB64")!)!)
        }
        XCTAssertEqual(reassembled, a + c)
        var reassembledErr = Data()
        for m in h.messages(ofType: "spawn.stderr") {
            reassembledErr.append(Data(base64Encoded: m.string("dataB64")!)!)
        }
        XCTAssertEqual(reassembledErr, b)
    }

    // MARK: Pushes after close are silent no-ops

    func testPushesAfterCloseAreNoOps() {
        let h = handshaken()
        h.session.pushStdout(pid: 42, data: Data("a".utf8))
        let before = h.received.count
        h.session.close()
        h.session.pushStdout(pid: 42, data: Data("b".utf8))
        h.session.pushExit(pid: 42, code: 0, signal: nil)
        h.session.pushResize(cols: 10, rows: 10)
        XCTAssertEqual(h.received.count, before)
    }
}
