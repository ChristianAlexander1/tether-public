import Foundation
import TermXCore
@testable import TermXNode

/// Test double recording every spawn routed through @termx/shim IPC.
public final class RecordingSpawnExecutor: SpawnExecuting {
    public private(set) var records: [RecordedSpawn] = []
    private var nextPID: Int32 = 5000
    private var handlers: [String: (RecordedSpawn) -> SpawnResult] = [:]

    public init() {
        handlers["echo"] = { spawn in
            SpawnResult(pid: 1, exitCode: 0, stdout: spawn.args.joined(separator: " ") + "\n", stderr: "")
        }
        handlers["sh"] = { spawn in
            if spawn.args.first == "-c", spawn.args.count >= 2 {
                return SpawnResult(pid: 1, exitCode: 0, stdout: "postinstall-ok\n", stderr: "")
            }
            return SpawnResult(pid: 1, exitCode: 0, stdout: "", stderr: "")
        }
        handlers["node"] = { _ in
            SpawnResult(pid: 1, exitCode: 0, stdout: "2\n", stderr: "")
        }
    }

    public func registerHandler(for command: String, handler: @escaping (RecordedSpawn) -> SpawnResult) {
        handlers[command] = handler
    }

    public func spawnSync(file: String, args: [String], cwd: String, env: [String: String],
                          stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                          interactive: Bool) -> SpawnResult {
        let record = RecordedSpawn(file: file, args: args, cwd: cwd, interactive: interactive)
        records.append(record)
        let key = (file as NSString).lastPathComponent
        if let handler = handlers[key] ?? handlers[file] {
            return handler(record)
        }
        let pid = nextPID
        nextPID += 1
        return SpawnResult(pid: pid, exitCode: 127, stdout: "", stderr: "\(file): not found\n")
    }

    public func signal(pid: Int32, signal: Int32) {
        _ = pid
        _ = signal
    }
}
