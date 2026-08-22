import Foundation

/// Bridges @termx/shim JSON IPC to TermXCore spawn execution.
final class NodeSpawnBridge {
    private let executor: SpawnExecuting
    private let queue = DispatchQueue(label: "com.termx.node.ipc")

    init(executor: SpawnExecuting) {
        self.executor = executor
    }

    func handle(requestData: Data, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                defaultCWD: String, defaultEnv: [String: String], interactive: Bool) -> Data {
        guard let line = String(data: requestData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let op = json["op"] as? String else {
            return Self.replyJSON(["error": "invalid request"])
        }

        switch op {
        case "spawn", "spawnSync":
            let file = json["file"] as? String ?? ""
            let args = json["args"] as? [String] ?? []
            let cwd = json["cwd"] as? String ?? defaultCWD
            var env = defaultEnv
            if let override = json["env"] as? [String: String] {
                env.merge(override) { _, new in new }
            }
            let isInteractive = (json["interactive"] as? Bool) ?? interactive
            if !file.isEmpty, !FileManager.default.isExecutableFile(atPath: file),
               !file.hasPrefix("/") {
                let pathEnv = env["PATH"] ?? defaultEnv["PATH"] ?? "/bin"
                let resolved = pathEnv.split(separator: ":").map { "\($0)/\(file)" }.first {
                    FileManager.default.isExecutableFile(atPath: $0)
                }
                if resolved == nil, file != "sh", file != "/bin/sh" {
                    return Self.replyJSON([
                        "pid": Int32.random(in: 9000..<99999),
                        "exitCode": NSNull(),
                        "stdout": "",
                        "stderr": "",
                        "signal": NSNull(),
                        "error": "spawn \(file) ENOENT",
                        "code": "ENOENT",
                    ])
                }
            }
            let result = executor.spawnSync(
                file: file, args: args, cwd: cwd, env: env,
                stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                interactive: isInteractive
            )
            var reply: [String: Any] = [
                "pid": result.pid,
                "exitCode": result.exitCode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "signal": result.signal as Any,
            ]
            if result.exitCode != 0, result.stderr.contains("command not found")
                || result.stderr.contains("No such file") {
                reply["exitCode"] = NSNull()
                reply["error"] = "spawn \(file) ENOENT"
                reply["code"] = "ENOENT"
            }
            return Self.replyJSON(reply)
        case "signal":
            let pid = json["pid"] as? Int32 ?? -1
            let sigName = json["signal"] as? String ?? "SIGINT"
            executor.signal(pid: pid, signal: Self.signalNumber(sigName))
            return Self.replyJSON(["ok": true])
        default:
            return Self.replyJSON(["error": "unknown op \(op)"])
        }
    }

    private static func replyJSON(_ obj: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func signalNumber(_ name: String) -> Int32 {
        switch name {
        case "SIGINT": return Int32(SIGINT)
        case "SIGTERM": return Int32(SIGTERM)
        case "SIGKILL": return Int32(SIGKILL)
        default: return Int32(SIGTERM)
        }
    }
}

/// Creates a pipe pair and returns (readFD, writeFD).
enum NodePipe {
    static func pair() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        return (fds[0], fds[1])
    }

    static func close(_ fd: Int32) {
        if fd >= 0 { _ = Darwin.close(fd) }
    }
}

enum NodeStdioBridge {
    /// Redirects process stdout/stderr to target fds for the duration of `body`.
    static func withRedirectedOutput(stdoutFD: Int32, stderrFD: Int32, body: () -> Int32) -> Int32 {
        guard stdoutFD >= 0 || stderrFD >= 0 else { return body() }
        let origOut = dup(STDOUT_FILENO)
        let origErr = dup(STDERR_FILENO)
        if stdoutFD >= 0 { dup2(stdoutFD, STDOUT_FILENO) }
        if stderrFD >= 0 { dup2(stderrFD, STDERR_FILENO) }
        let code = body()
        if origOut >= 0 { dup2(origOut, STDOUT_FILENO); close(origOut) }
        if origErr >= 0 { dup2(origErr, STDERR_FILENO); close(origErr) }
        return code
    }
}
