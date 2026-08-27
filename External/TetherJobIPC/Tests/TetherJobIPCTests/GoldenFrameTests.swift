import XCTest
import Foundation
import TetherJobIPC
import TetherJobIPCTestSupport

/// Behavior 16 — the golden fixtures are the byte-for-byte interop contract with the
/// JS client. The codec must round-trip each committed byte array exactly.
final class GoldenFrameTests: XCTestCase {

    func testAtLeastTwelveCanonicalFramesExist() {
        XCTAssertGreaterThanOrEqual(GoldenFrames.all.count, 12)
        // Names are unique.
        XCTAssertEqual(Set(GoldenFrames.all.map(\.name)).count, GoldenFrames.all.count)
    }

    /// For each fixture: framed bytes decode to exactly one payload equal to the
    /// canonical JSON, and re-encoding that payload reproduces the committed bytes.
    func testEachFixtureDecodesAndReEncodesExactly() {
        for frame in GoldenFrames.all {
            var codec = JIPFrameCodec()
            let payload = Data(frame.payloadJSON.utf8)

            let decoded = try! codec.append(Data(frame.bytes))
            XCTAssertEqual(decoded.count, 1,
                           "\(frame.name): exactly one frame per fixture")
            XCTAssertEqual(decoded[0], payload, "\(frame.name): payload bytes")

            XCTAssertEqual(JIPFrameCodec.encode(payload), Data(frame.bytes),
                           "\(frame.name): re-encode must reproduce committed bytes")
        }
    }

    /// Each fixture must parse as a valid TJIP/2 envelope.
    func testEachFixtureIsAValidEnvelope() throws {
        for frame in GoldenFrames.all {
            let obj = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(frame.payloadJSON.utf8)) as? [String: Any],
                "\(frame.name): must be a JSON object")
            let version = try XCTUnwrap(obj["v"] as? NSNumber, "\(frame.name): v")
            XCTAssertEqual(version.intValue, 2, "\(frame.name): v must be 2")
            let kind = try XCTUnwrap(obj["kind"] as? String, "\(frame.name): kind")
            XCTAssertTrue(["req", "res", "evt"].contains(kind), "\(frame.name): kind")

            let body = obj["body"] as? [String: Any]
            if kind == "evt" {
                XCTAssertNil(obj["id"], "\(frame.name): evt has no id")
            } else {
                XCTAssertNotNil(obj["id"], "\(frame.name): \(kind) has an id")
                XCTAssertNotNil(obj["type"], "\(frame.name): \(kind) has a type")
            }
            if kind == "res" {
                let ok = try XCTUnwrap(body?["ok"] as? NSNumber, "\(frame.name): res.ok")
                XCTAssertTrue(ok.intValue == 0 || ok.intValue == 1, "\(frame.name): ok is bool")
                if ok.intValue == 0 {
                    XCTAssertNotNil(body?["code"], "\(frame.name): error res has code")
                    XCTAssertNotNil(body?["message"], "\(frame.name): error res has message")
                }
            }
            XCTAssertNotNil(body, "\(frame.name): has a body")
        }
    }

    /// Replay a canonical request frame through the session and compare the emitted
    /// response against the canonical response frame. For request fixtures other than
    /// `hello`, a real `hello` is performed first (the fixtures assume a handshaken
    /// session), then the request is replayed and the *last* emitted frame compared.
    func testReplayRequestFixturesProduceExactResponseBytes() {
        let pairs = [("hello.req", "hello.res"),
                     ("tty.get.req", "tty.get.res"),
                     ("tty.setRawMode.req", "tty.setRawMode.res"),
                     ("tty.windowSize.req", "tty.windowSize.res")]

        for (reqName, resName) in pairs {
            let req = GoldenFrames.named(reqName)!
            let res = GoldenFrames.named(resName)!
            let h = JIPTestHarness()
            if reqName != "hello.req" {
                // Handshake first; the request fixtures assume a handshaken session.
                h.sendFramedChunk(Data(GoldenFrames.named("hello.req")!.bytes))
            }
            h.sendFramedChunk(Data(req.bytes))
            let emitted = h.receivedPayloads.last
            XCTAssertNotNil(emitted, "\(reqName): one response")
            XCTAssertEqual(emitted, Data(res.payloadJSON.utf8), "\(reqName): payload")
            XCTAssertEqual(emitted.map { JIPFrameCodec.encode($0) }, Data(res.bytes),
                           "\(reqName): exact wire bytes")
        }
    }

    /// The error-resolution fixture is replayed from a delegate that throws ENOENT.
    func testReplayErrorResponseFixture() {
        let req = GoldenFrames.named("spawn.start.req")!
        let res = GoldenFrames.named("error.res")!
        let h = JIPTestHarness()
        h.delegate.spawnStartThrows = JIPError(code: JIPErrorCode.enoent,
                                               message: "no such file or directory")
        h.sendFramedChunk(Data(GoldenFrames.named("hello.req")!.bytes))
        h.sendFramedChunk(Data(req.bytes))
        let emitted = h.receivedPayloads.last
        XCTAssertEqual(emitted, Data(res.payloadJSON.utf8))
        XCTAssertEqual(emitted.map { JIPFrameCodec.encode($0) }, Data(res.bytes))
    }
}
