import XCTest
import Foundation
import TetherJobIPC
import TetherJobIPCTestSupport

final class TtyDomainTests: XCTestCase {

    private func handshaken() -> JIPTestHarness {
        let h = JIPTestHarness()
        h.sendHello(id: 1)
        XCTAssertTrue(h.session.isHandshakeComplete)
        return h
    }

    func testTtyGetSuccess() {
        let h = handshaken()
        h.delegate.ttyGetResult = (isTTY: true, isRaw: true, cols: 100, rows: 32)
        h.sendRequest(type: "tty.get", id: 2, body: ["fd": 0])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, true)
        XCTAssertEqual(res?.bool("isTTY"), true)
        XCTAssertEqual(res?.bool("isRaw"), true)
        XCTAssertEqual(res?.int("cols"), 100)
        XCTAssertEqual(res?.int("rows"), 32)
        XCTAssertTrue(h.delegate.calls.contains { $0.hasPrefix("ttyGet(") })
    }

    func testTtyGetNotATTY() {
        let h = handshaken()
        h.delegate.ttyGetThrows = JIPError(code: JIPErrorCode.eperm, message: "not a tty we own")
        h.sendRequest(type: "tty.get", id: 2, body: ["fd": 0])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EPERM")
    }

    func testTtySetRawModeSuccess() {
        let h = handshaken()
        h.delegate.ttySetRawModeResult = true   // previously raw
        h.sendRequest(type: "tty.setRawMode", id: 2, body: ["fd": 0, "mode": false])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, true)
        XCTAssertEqual(res?.bool("wasRaw"), true)
        XCTAssertTrue(h.delegate.calls.contains { $0.hasPrefix("ttySetRawMode(") })
    }

    func testTtySetRawModeEINVALWhenNotTTY() {
        let h = handshaken()
        h.delegate.ttySetRawModeThrows = JIPError(code: JIPErrorCode.einval, message: "not a tty")
        h.sendRequest(type: "tty.setRawMode", id: 2, body: ["fd": 5, "mode": true])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EINVAL")
    }

    func testTtyWindowSizeSuccess() {
        let h = handshaken()
        h.delegate.ttyGetResult = (isTTY: true, isRaw: false, cols: 120, rows: 40)
        h.sendRequest(type: "tty.windowSize", id: 2, body: ["fd": 1])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, true)
        XCTAssertEqual(res?.int("cols"), 120)
        XCTAssertEqual(res?.int("rows"), 40)
    }

    func testTtyWindowSizeEINVAL() {
        let h = handshaken()
        h.delegate.ttyGetThrows = JIPError(code: JIPErrorCode.einval, message: "bad fd")
        h.sendRequest(type: "tty.windowSize", id: 2, body: ["fd": 9])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EINVAL")
    }

    func testNonJIPErrorBodyBecomesEINVAL() {
        let h = handshaken()
        h.delegate.ttySetRawModeThrows = nil
        h.delegate.ttySetRawModeOverride = { _, _ in throw NSError(domain: "x", code: 1) }
        h.sendRequest(type: "tty.setRawMode", id: 2, body: ["fd": 0, "mode": true])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EINVAL")
    }

    // MARK: Server → client pushes

    func testPushResizeEmitsTtyResizeEvent() {
        let h = handshaken()
        h.session.pushResize(cols: 120, rows: 40)
        let evt = h.messages(ofType: "tty.resize").last
        XCTAssertEqual(evt?.kind, "evt")
        XCTAssertEqual(evt?.id, nil)
        XCTAssertEqual(evt?.int("cols"), 120)
        XCTAssertEqual(evt?.int("rows"), 40)
    }

    func testPushSignalEmitsTtySignalEvent() {
        let h = handshaken()
        h.session.pushSignal("SIGTERM")
        let evt = h.messages(ofType: "tty.signal").last
        XCTAssertEqual(evt?.kind, "evt")
        XCTAssertEqual(evt?.string("signal"), "SIGTERM")
    }

    func testPushesBeforeHandshakeAreSilentNoOps() {
        let h = JIPTestHarness()
        h.session.pushResize(cols: 1, rows: 2)
        h.session.pushSignal("SIGINT")
        h.session.pushStdout(pid: 42, data: Data("x".utf8))
        XCTAssertTrue(h.received.isEmpty)
    }
}
