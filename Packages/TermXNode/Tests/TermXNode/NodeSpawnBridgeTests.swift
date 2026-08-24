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

    func testGuestStylePathIsResolvedByExecutorNotHostFilesystem() throws {
        let executor = RecordingSpawnExecutor()
        let bridge = NodeSpawnBridge(executor: executor)
        let request: [String: Any] = [
            "kind": "spawnSync",
            "file": "future-package-command",
            "args": ["--version"],
            "env": ["PATH": "/usr/local/bin:/usr/bin:/bin"],
        ]
        let data = try JSONSerialization.data(withJSONObject: request)

        _ = bridge.handle(
            requestData: data,
            stdinFD: -1, stdoutFD: -1, stderrFD: -1,
            defaultCWD: "/work", defaultEnv: [:], interactive: false
        )

        XCTAssertEqual(executor.records.last?.file, "future-package-command")
    }

    func testWhichOpenReturnsInstalledGuestLauncherPath() throws {
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
        XCTAssertEqual((reply["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "/usr/local/bin/open")
        XCTAssertTrue(recorder.records.isEmpty)
    }

    func testExit127UsesNodeENOENTContract() throws {
        let bridge = NodeSpawnBridge(executor: Exit127SpawnExecutor())
        let data = try JSONSerialization.data(withJSONObject: [
            "op": "spawnSync",
            "file": "not-installed",
            "args": [],
        ])
        let replyData = bridge.handle(
            requestData: data,
            stdinFD: -1, stdoutFD: -1, stderrFD: -1,
            defaultCWD: "/work", defaultEnv: [:], interactive: false
        )
        let reply = try JSONSerialization.jsonObject(with: replyData.dropLast()) as! [String: Any]
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "ENOENT")
        XCTAssertTrue(reply["exitCode"] is NSNull)
    }
}

private final class Exit127SpawnExecutor: SpawnExecuting {
    func spawnSync(file: String, args: [String], cwd: String, env: [String: String],
                   stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                   interactive: Bool) -> SpawnResult {
        SpawnResult(pid: VirtualChildPID.next(), exitCode: 127, stdout: "", stderr: "")
    }

    func signal(pid: Int32, signal: Int32) {}
}
