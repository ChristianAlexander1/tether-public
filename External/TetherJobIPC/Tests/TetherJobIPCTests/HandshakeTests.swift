import XCTest
import Foundation
import TetherJobIPC
import TetherJobIPCTestSupport

/// Envelope validation, handshake state machine, id monotonicity, ENOSYS/unknown evt.
final class HandshakeTests: XCTestCase {

    private func makeHarness() -> JIPTestHarness { JIPTestHarness() }

    // MARK: Behavior 3 — invalid JSON / wrong v / missing kind => EPROTO + close

    func testInvalidJSONClosesWithEPROTO() {
        let h = makeHarness()
        // Frame whose payload is not valid JSON.
        h.sendFramedChunk(JIPFrameCodec.encode(Data("{not json".utf8)))
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
        XCTAssertTrue(h.delegate.calls.isEmpty)
        XCTAssertFalse(h.session.isHandshakeComplete)
    }

    func testWrongVersionClosesWithEPROTO() {
        let h = makeHarness()
        h.sendRequest(type: "hello", id: 1)
        h.sendJSON(["v": 3, "kind": "req", "id": 2, "type": "tty.get", "body": ["fd": 0]])
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }

    func testMissingKindClosesWithEPROTO() {
        let h = makeHarness()
        h.sendJSON(["v": 2, "id": 1, "type": "hello", "body": [:]])
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }

    // MARK: Behavior 4 — pre-handshake non-hello request

    func testPreHandshakeRequestReturnsEPROTOAndSessionStaysOpen() {
        let h = makeHarness()
        h.sendRequest(type: "tty.get", id: 5, body: ["fd": 0])
        let res = h.response(id: 5)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EPROTO")
        XCTAssertTrue(h.protocolErrors.isEmpty)          // not a connection-killing violation
        XCTAssertFalse(h.pair.isAClosed)
        XCTAssertFalse(h.session.isHandshakeComplete)    // still awaiting hello

        // Subsequent hello still works.
        h.sendHello(id: 6)
        XCTAssertEqual(h.session.isHandshakeComplete, true)
        XCTAssertEqual(h.response(id: 6)?.ok, true, "")
    }

    func testHelloSendsCanonicalHandshakeResponse() {
        let h = makeHarness()
        h.delegate.handshakeValue = JIPHandshake(ttyFds: [0, 1, 2], cols: 80, rows: 24,
                                                 termName: "xterm-256color", colorTerm: "truecolor")
        h.sendHello(id: 1)
        guard let res = h.response(id: 1) else { return XCTFail("no hello response") }
        XCTAssertEqual(res.ok, true)
        XCTAssertEqual(res.int("proto"), 2)
        XCTAssertEqual((res.body["features"] as? [String])?.sorted(), ["flow", "spawn", "tty"])
        let fds = (res.body["ttyFds"] as? [Any])?.compactMap { ($0 as? NSNumber)?.int32Value }
        XCTAssertEqual(fds, [0, 1, 2])
        XCTAssertEqual(res.int("cols"), 80)
        XCTAssertEqual(res.int("rows"), 24)
        XCTAssertEqual(res.string("termName"), "xterm-256color")
        XCTAssertEqual(res.string("colorTerm"), "truecolor")
        XCTAssertTrue(h.session.isHandshakeComplete)
    }

    // MARK: Behavior 5 — duplicate hello

    func testDuplicateHelloClosesWithEPROTO() {
        let h = makeHarness()
        h.sendHello(id: 1)
        XCTAssertEqual(h.response(id: 1)?.ok, true)
        h.sendHello(id: 2)
        XCTAssertEqual(h.response(id: 2)?.ok, false)
        XCTAssertEqual(h.response(id: 2)?.code, "EPROTO")
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }

    // MARK: Behavior 8 — request id strict monotonicity

    func testReusedRequestIdClosesWithEPROTO() {
        let h = makeHarness()
        h.sendHello(id: 1)
        h.sendRequest(type: "tty.get", id: 50, body: ["fd": 0])
        XCTAssertNotNil(h.response(id: 50))
        // Reuse id 50.
        h.sendRequest(type: "tty.get", id: 50, body: ["fd": 0])
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }

    func testDecreasingRequestIdClosesWithEPROTO() {
        let h = makeHarness()
        h.sendHello(id: 20)
        h.sendRequest(type: "tty.get", id: 21, body: ["fd": 0])
        h.sendRequest(type: "tty.get", id: 15, body: ["fd": 0]) // decreasing
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }

    // MARK: Behavior 6 — unknown request type => ENOSYS, session healthy

    func testUnknownRequestTypeReturnsENOSYS() {
        let h = makeHarness()
        h.sendHello(id: 1)
        h.sendRequest(type: "frobnicate", id: 2, body: [:] )
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "ENOSYS")
        XCTAssertTrue(h.protocolErrors.isEmpty)
        XCTAssertFalse(h.pair.isAClosed)
    }

    // MARK: Behavior 7 — unknown event type ignored

    func testUnknownEventTypeIsIgnored() {
        let h = makeHarness()
        h.sendHello(id: 1)
        h.sendEvent(type: "junk.event", body: ["x": 1])
        XCTAssertTrue(h.protocolErrors.isEmpty)
        XCTAssertFalse(h.pair.isAClosed)
        // Only the hello res was produced.
        XCTAssertEqual(h.received.filter { $0.kind == "res" }.count, 1)
    }

    // MARK: Full-duplex request/response correlation

    func testManyRequestsCorrelateById() {
        let h = makeHarness()
        h.sendHello(id: 1)
        h.sendRequest(type: "tty.get", id: 2, body: ["fd": 0])
        h.sendRequest(type: "tty.windowSize", id: 3, body: ["fd": 1])
        h.sendRequest(type: "tty.get", id: 4, body: ["fd": 2])
        XCTAssertEqual(h.response(id: 2)?.type, "tty.get")
        XCTAssertEqual(h.response(id: 3)?.type, "tty.windowSize")
        XCTAssertEqual(h.response(id: 4)?.type, "tty.get")
        XCTAssertEqual(h.response(id: 2)?.id, 2)
        XCTAssertEqual(h.response(id: 3)?.id, 3)
    }

    // MARK: Behavior 2 — oversize frame at the session level

    func testOversizeFrameClosesSessionWithEMSGSIZE() {
        let h = makeHarness()
        h.sendHello(id: 1)                       // valid handshake
        let callCount = h.delegate.calls.count
        var len = UInt32(2_000_000).bigEndian
        let oversizeHeader = withUnsafeBytes(of: &len) { Data($0) }
        h.sendFramedChunk(oversizeHeader)        // declares a 2 MB frame

        XCTAssertEqual(h.protocolErrors.last?.code, "EMSGSIZE")
        XCTAssertTrue(h.pair.isAClosed, "transport close() invoked")
        // No delegate reached for the oversized frame.
        XCTAssertEqual(h.delegate.calls.count, callCount)
    }

    // MARK: Behavior 15 — close() idempotence

    func testDoubleCloseIsSafe() {
        let h = makeHarness()
        h.sendHello(id: 1)
        h.session.close()
        h.session.close()                        // second close is a safe no-op
        XCTAssertTrue(h.pair.isAClosed)
        h.session.pushResize(cols: 1, rows: 2)   // pushes after close are no-ops
        h.session.pushStdout(pid: 42, data: Data("x".utf8))
        XCTAssertEqual(h.received.count, 1)      // only the hello res
    }

    // MARK: Missing id / type in a request

    func testRequestMissingIdClosesWithEPROTO() {
        let h = makeHarness()
        h.sendHello(id: 1)
        h.sendJSON(["v": 2, "kind": "req", "type": "tty.get", "body": ["fd": 0]])
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }

    func testRequestMissingTypeClosesWithEPROTO() {
        let h = makeHarness()
        h.sendJSON(["v": 2, "kind": "req", "id": 1, "body": [:]])
        XCTAssertEqual(h.protocolErrors.last?.code, "EPROTO")
        XCTAssertTrue(h.pair.isAClosed)
    }
}
