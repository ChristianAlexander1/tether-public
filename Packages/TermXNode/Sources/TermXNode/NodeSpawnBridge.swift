import Foundation
import TermXFiles

/// Bridges @tether/shim JSON IPC to command execution.
final class NodeSpawnBridge {
    private let executor: SpawnExecuting
    private let openTarget: (SystemOpen.Target, SystemOpen.OpenOrigin) -> SystemOpen.Result

    init(
        executor: SpawnExecuting,
        openTarget: @escaping (SystemOpen.Target, SystemOpen.OpenOrigin) -> SystemOpen.Result = {
            SystemOpen.open($0, origin: $1)
        }
    ) {
        self.executor = executor
        self.openTarget = openTarget
    }

    func handle(requestData: Data, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                defaultCWD: String, defaultEnv: [String: String], interactive: Bool) -> Data {
        guard let line = String(data: requestData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return Self.replyJSON(["error": "invalid request", "ok": false])
        }

        let kind = (json["kind"] as? String) ?? (json["op"] as? String)
        guard let kind else {
            return Self.replyJSON(["error": "missing kind/op", "ok": false])
        }

        switch kind {
        case "cancel", "signal":
            let pid = json["pid"] as? Int32 ?? -1
            if kind == "signal" {
                let sigName = json["signal"] as? String ?? "SIGINT"
                executor.signal(pid: pid, signal: Self.signalNumber(sigName))
            } else {
                executor.signal(pid: pid, signal: Int32(SIGINT))
            }
            return Self.replyJSON(["ok": true, "exitCode": 130, "stdout": "", "stderr": "", "pid": pid])

        case "spawn", "spawnSync":
            return handleSpawn(
                json, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                defaultCWD: defaultCWD, defaultEnv: defaultEnv, interactive: interactive
            )

        default:
            return Self.replyJSON(["error": "unknown kind \(kind)", "ok": false])
        }
    }

    private func handleSpawn(
        _ json: [String: Any],
        stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
        defaultCWD: String, defaultEnv: [String: String], interactive: Bool
    ) -> Data {
            let file = json["file"] as? String ?? ""
            let args = json["args"] as? [String] ?? []
            let cwd = json["cwd"] as? String ?? defaultCWD
            var env = defaultEnv
            if let override = json["env"] as? [String: String] {
                env.merge(override) { _, new in new }
            }
            let isInteractive = (json["interactive"] as? Bool) ?? interactive

            SystemOpen.log("node spawn \(file) \(args.prefix(2).joined(separator: " "))")

            // Desktop programs commonly probe an opener with `which` before using it.
            let whichBase = (file as NSString).lastPathComponent
            if whichBase == "which", args.count == 1, SystemOpen.openerCommands.contains(args[0]) {
                let path = "/usr/local/bin/\(args[0])"
                SystemOpen.log("which \(args[0]) -> \(path) (guest platform launcher)")
                return Self.replyJSON([
                    "ok": true,
                    "pid": VirtualChildPID.next(),
                    "exitCode": 0,
                    "stdout": path + "\n",
                    "stderr": "",
                    "signal": NSNull(),
                ])
            }

            // Desktop CLIs call open/xdg-open; provide the platform opener for any package.
            if let target = SystemOpen.resolve(command: file, arguments: args) {
                SystemOpen.log("spawn intercept \(file) \(args.prefix(1))")
                let result = openTarget(target, .hostRuntime)
                if result == .opened {
                    return Self.replyJSON([
                        "ok": true,
                        "pid": VirtualChildPID.next(),
                        "exitCode": 0,
                        "stdout": "",
                        "stderr": "",
                        "signal": NSNull(),
                    ])
                }
                if case .failed(let why) = result {
                    SystemOpen.log("open failed: \(why)")
                    return Self.replyJSON([
                        "ok": false,
                        "pid": VirtualChildPID.next(),
                        "exitCode": 1,
                        "stdout": "",
                        "stderr": "\(file): \(why)\n",
                        "signal": NSNull(),
                    ])
                }
            }

            // Do not probe the iOS host filesystem for a guest PATH entry.
            // The executor owns resolution across native commands and other
            // runtime lanes; only it can return an authoritative ENOENT.
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
            if result.exitCode == 127 || (result.exitCode != 0 && (
                result.stderr.contains("command not found") ||
                result.stderr.contains("No such file")
            )) {
                reply["exitCode"] = NSNull()
                reply["error"] = "spawn \(file) ENOENT"
                reply["code"] = "ENOENT"
                reply["ok"] = false
            } else {
                reply["ok"] = true
            }
            return Self.replyJSON(reply)
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

/// Process IDs in the Node shim identify in-process child jobs, not Darwin
/// processes. A locked monotonic namespace keeps cancellation and replies
/// stable without pretending they are host PIDs.
enum VirtualChildPID {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var nextValue: Int32 = 1

    static func next() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue = nextValue == Int32.max ? 1 : nextValue + 1
        return value
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
