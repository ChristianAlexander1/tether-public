import XCTest
import TermXFiles
@testable import TermXNode

final class NodeSpawnBridgeTests: XCTestCase {
    func testSpawnSyncOpenDoesNotHitExecutor() throws {
        let recorder = RecordingSpawnExecutor()
        let bridge = NodeSpawnBridge(executor: recorder) { target, origin in
            XCTAssertEqual(target, .url(URL(string: "https://example.com/oauth/test")!))
            XCTAssertEqual(origin, .hostRuntime)
            return .opened
        }
        let url = "https://example.com/oauth/test"
        let req: [String: Any] = [
            "op": "spawnSync",
            "file": "xdg-open",
            "args": [url],
        ]
        let data = try JSONSerialization.data(withJSONObject: req)
        let replyData = bridge.handle(
            requestData: data,
            stdinFD: -1, stdoutFD: -1, stderrFD: -1,
            defaultCWD: "/work", defaultEnv: [:], interactive: true
        )
        let line = String(data: replyData.dropLast(), encoding: .utf8)!
        let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(reply["exitCode"] as? Int, 0)
        XCTAssertTrue(recorder.records.isEmpty, "xdg-open URL should not reach spawn executor")
    }

    func testSpawnSyncNonOpenerStillHitsExecutor() throws {
        let recorder = RecordingSpawnExecutor()
        let bridge = NodeSpawnBridge(executor: recorder)
        let req: [String: Any] = [
            "op": "spawnSync",
            "file": "sh",
            "args": ["-c", "curl https://example.com"],
        ]
        let data = try JSONSerialization.data(withJSONObject: req)
        _ = bridge.handle(
            requestData: data,
            stdinFD: -1, stdoutFD: -1, stderrFD: -1,
            defaultCWD: "/work", defaultEnv: [:], interactive: true
        )
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(recorder.records.first?.file, "sh")
    }

    func testWhichOpenReturnsVirtualPath() throws {
        let recorder = RecordingSpawnExecutor()
        let bridge = NodeSpawnBridge(executor: recorder)
        let req: [String: Any] = [
            "op": "spawnSync",
            "file": "which",
            "args": ["open"],
        ]
        let data = try JSONSerialization.data(withJSONObject: req)
        let replyData = bridge.handle(
            requestData: data,
            stdinFD: -1, stdoutFD: -1, stderrFD: -1,
            defaultCWD: "/work", defaultEnv: [:], interactive: true
        )
        let line = String(data: replyData.dropLast(), encoding: .utf8)!
        let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(reply["exitCode"] as? Int, 0)
        XCTAssertEqual((reply["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "/usr/bin/open")
        XCTAssertTrue(recorder.records.isEmpty)
    }
}
