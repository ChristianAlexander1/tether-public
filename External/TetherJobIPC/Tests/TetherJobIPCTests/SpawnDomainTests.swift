import XCTest
import Foundation
import TetherJobIPC
import TetherJobIPCTestSupport

final class SpawnDomainTests: XCTestCase {

    private func handshaken() -> JIPTestHarness {
        let h = JIPTestHarness()
        h.sendHello(id: 1)
        XCTAssertTrue(h.session.isHandshakeComplete)
        return h
    }

    // MARK: Behavior 9 — spawn lifecycle

    func testSpawnLifecycle_startStdoutExit() {
        let h = handshaken()
        h.delegate.spawnStartPid = 42
        h.sendRequest(type: "spawn.start", id: 2,
                      body: ["argv": ["ls", "-la"], "cwd": "/work",
                             "env": ["PATH": "/usr/bin"],
                             "stdio": ["pipe", "pipe", "pipe"], "pty": false])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, true)
        XCTAssertEqual(res?.int32("pid"), 42)
        XCTAssertTrue(h.delegate.calls.contains { $0.hasPrefix("spawnStart") })

        h.session.pushStdout(pid: 42, data: Data("hello".utf8))
        h.session.pushExit(pid: 42, code: 0, signal: nil)

        // Exit is the very last frame for the pid.
        let last = h.received.last
        XCTAssertEqual(last?.type, "spawn.exit")
        XCTAssertEqual(last?.kind, "evt")
        XCTAssertEqual(last?.int32("pid"), 42)
        XCTAssertEqual(last?.int("code"), 0)
        XCTAssertTrue(last?.body["signal"] is NSNull, "signal is null when a code is present")
    }

    func testSpawnExitWithOnlySignal() {
        let h = handshaken()
        h.sendRequest(type: "spawn.start", id: 2, body: ["argv": ["cat"]])
        XCTAssertEqual(h.response(id: 2)?.ok, true)
        h.session.pushExit(pid: 42, code: nil, signal: "SIGKILL")
        let last = h.received.last
        XCTAssertEqual(last?.type, "spawn.exit")
        XCTAssertTrue(last?.body["code"] is NSNull)
        XCTAssertEqual(last?.string("signal"), "SIGKILL")
    }

    func testKillAfterExitReturnsESRCHWithoutDelegateCall() {
        let h = handshaken()
        h.delegate.spawnStartPid = 42
        h.sendRequest(type: "spawn.start", id: 2, body: ["argv": ["sleep"]])
        h.session.pushExit(pid: 42, code: 1, signal: nil)
        XCTAssertEqual(h.received.last?.type, "spawn.exit")

        h.sendRequest(type: "spawn.kill", id: 3, body: ["pid": 42, "signal": "SIGTERM"])
        let res = h.response(id: 3)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "ESRCH")
        // The delegate must not have been consulted.
        XCTAssertFalse(h.delegate.calls.contains { $0.hasPrefix("spawnKill") })
    }

    func testStdinAfterExitReturnsEPIPEWithoutDelegateCall() {
        let h = handshaken()
        h.session.pushExit(pid: 42, code: 0, signal: nil)
        h.sendRequest(type: "spawn.stdin", id: 2, body: ["pid": 42, "dataB64": "aGVsbG8="])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EPIPE")
        XCTAssertFalse(h.delegate.calls.contains { $0.hasPrefix("spawnStdin") })
    }

    func testKillBeforeExitReachesDelegateAndSucceeds() {
        let h = handshaken()
        h.sendRequest(type: "spawn.kill", id: 2, body: ["pid": 42, "signal": "SIGINT"])
        XCTAssertEqual(h.response(id: 2)?.ok, true)
        XCTAssertTrue(h.delegate.calls.contains { $0.hasPrefix("spawnKill(") })
    }

    // MARK: Behavior 11 — chunk splitting preserves bytes in order

    func testChunkSplitting_200KBEmitsOrderedBase64Chunks() {
        let h = handshaken()
        let input = Data(repeating: 0x21, count: 200_000) // repeated '!'
        h.session.pushStdout(pid: 42, data: input)

        let events = h.messages(ofType: "spawn.stdout")
        XCTAssertGreaterThan(events.count, 1)
        var reassembled = Data()
        for e in events {
            let b64 = try! XCTUnwrap(e.string("dataB64"))
            let chunk = try! XCTUnwrap(Data(base64Encoded: b64))
            XCTAssertLessThanOrEqual(chunk.count, 65_536, "chunk must be <= 64KiB raw")
            reassembled.append(chunk)
        }
        XCTAssertEqual(reassembled, input)
    }

    // MARK: Behavior 14 — delegate throws

    func testDelegateThrowsJIPErrorProducesCode() {
        let h = handshaken()
        h.delegate.spawnStartThrows = JIPError(code: JIPErrorCode.enoent, message: "no such file")
        h.sendRequest(type: "spawn.start", id: 2, body: ["argv": ["missing"]])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "ENOENT")
        XCTAssertEqual(res?.string("message"), "no such file")
        // Session remains healthy.
        XCTAssertFalse(h.pair.isAClosed)
        XCTAssertTrue(h.protocolErrors.isEmpty)
        h.sendRequest(type: "tty.get", id: 3, body: ["fd": 0])
        XCTAssertEqual(h.response(id: 3)?.ok, true)
    }

    func testDelegateThrowsOtherErrorMapsToEINVAL() {
        let h = handshaken()
        h.delegate.spawnStartOverride = { _, _, _, _, _ in throw NSError(domain: "x", code: 9) }
        h.sendRequest(type: "spawn.start", id: 2, body: ["argv": ["x"]])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EINVAL")
        XCTAssertTrue(h.protocolErrors.isEmpty)
    }

    // MARK: Other spawn paths

    func testSpawnResizeSuccess() {
        let h = handshaken()
        h.sendRequest(type: "spawn.resize", id: 2, body: ["pid": 42, "cols": 90, "rows": 30])
        XCTAssertEqual(h.response(id: 2)?.ok, true)
        XCTAssertTrue(h.delegate.calls.contains { $0.hasPrefix("spawnResize(") })
    }

    func testSpawnResizeEINVALWhenNotPty() {
        let h = handshaken()
        h.delegate.spawnResizeThrows = JIPError(code: JIPErrorCode.einval, message: "not a pty")
        h.sendRequest(type: "spawn.resize", id: 2, body: ["pid": 42, "cols": 90, "rows": 30])
        let res = h.response(id: 2)
        XCTAssertEqual(res?.ok, false)
        XCTAssertEqual(res?.code, "EINVAL")
    }

    func testSpawnStdinEndSuccess() {
        let h = handshaken()
        h.sendRequest(type: "spawn.stdinEnd", id: 2, body: ["pid": 42])
        XCTAssertEqual(h.response(id: 2)?.ok, true)
        XCTAssertTrue(h.delegate.calls.contains { $0.hasPrefix("spawnStdinEnd(") })
    }
}
