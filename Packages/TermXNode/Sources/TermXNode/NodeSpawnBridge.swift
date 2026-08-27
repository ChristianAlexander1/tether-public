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

        case "tty":
            return handleTty(json, stdinFD: stdinFD, stdoutFD: stdoutFD)

        default:
            return Self.replyJSON(["error": "unknown kind \(kind)", "ok": false])
        }
    }

    private func handleTty(_ json: [String: Any], stdinFD: Int32, stdoutFD: Int32) -> Data {
        let op = (json["op"] as? String) ?? ""
        switch op {
        case "setRawMode":
            let enabled = json["mode"] as? Bool ?? false
            // Prefer the live job PTY (stdin); fall back to stdout when stdin was slurped.
            let fd = stdinFD >= 0 ? stdinFD : stdoutFD
            guard fd >= 0 else {
                return Self.replyJSON(["ok": false, "error": "no tty fd"])
            }
            let ok = PtyTermios.setRawMode(fd: fd, enabled: enabled)
            return Self.replyJSON(["ok": ok])
        case "windowSize":
            let fd = stdoutFD >= 0 ? stdoutFD : stdinFD
            if let size = PtyTermios.windowSize(fd: fd) {
                return Self.replyJSON(["ok": true, "cols": size.cols, "rows": size.rows])
            }
            return Self.replyJSON(["ok": false, "error": "winsize unavailable"])
        default:
            return Self.replyJSON(["ok": false, "error": "unknown tty op \(op)"])
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

            // `which` is not special-cased. Guest launchers for the openers
            // live on PATH in /usr/local/bin, so a real PATH scan finds them —
            // faking the answer here also meant `which` lied about anything
            // else the manifest happened to name.

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
    /// Redirects process stdio to the job's PTY fds for the duration of `body`.
    /// Interactive stdin must use fd 0 on the engine thread so TUIs read the live PTY
    /// and emit their own teardown sequences (1049l, rmcup, etc.) — not host synthesis.
    static func withRedirectedIO(
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32,
        interactive: Bool,
        body: () -> Int32
    ) -> Int32 {
        let bindStdin = interactive && stdinFD >= 0 && isatty(stdinFD) != 0
        guard bindStdin || stdoutFD >= 0 || stderrFD >= 0 else { return body() }

        let origIn = bindStdin ? dup(STDIN_FILENO) : -1
        let origOut = stdoutFD >= 0 ? dup(STDOUT_FILENO) : -1
        let origErr = stderrFD >= 0 ? dup(STDERR_FILENO) : -1

        if bindStdin { _ = dup2(stdinFD, STDIN_FILENO) }
        if stdoutFD >= 0 { _ = dup2(stdoutFD, STDOUT_FILENO) }
        if stderrFD >= 0 { _ = dup2(stderrFD, STDERR_FILENO) }


        let code = body()

        if origIn >= 0 { dup2(origIn, STDIN_FILENO); close(origIn) }
        if origOut >= 0 { dup2(origOut, STDOUT_FILENO); close(origOut) }
        if origErr >= 0 { dup2(origErr, STDERR_FILENO); close(origErr) }
        return code
    }

    /// Redirects process stdout/stderr to target fds for the duration of `body`.
    static func withRedirectedOutput(stdoutFD: Int32, stderrFD: Int32, body: () -> Int32) -> Int32 {
        withRedirectedIO(stdinFD: -1, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: false, body: body)
    }

}

/// Applies real termios raw/cooked mode on the Darwin PTY backing an interactive job.
/// Node's `tty.setRawMode` shim calls this over IPC so Ink-style TUIs get character input.
enum PtyTermios {
    private static let lock = NSLock()
    private static var saved: [Int32: termios] = [:]

    static func setRawMode(fd: Int32, enabled: Bool) -> Bool {
        guard fd >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            var original = termios()
            guard tcgetattr(fd, &original) == 0 else { return false }
            if saved[fd] == nil {
                saved[fd] = original
            }
            var raw = original
            cfmakeraw(&raw)
            raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
            return tcsetattr(fd, TCSANOW, &raw) == 0
        } else {
            if var original = saved.removeValue(forKey: fd) {
                return tcsetattr(fd, TCSANOW, &original) == 0
            }
            var current = termios()
            guard tcgetattr(fd, &current) == 0 else { return false }
            current.c_lflag |= tcflag_t(ECHO | ICANON | ISIG)
            current.c_iflag |= tcflag_t(ICRNL | IXON)
            current.c_oflag |= tcflag_t(OPOST)
            return tcsetattr(fd, TCSANOW, &current) == 0
        }
    }

    /// Whether the terminal is currently in raw mode, read from the live
    /// termios rather than from bookkeeping — a program can change the mode
    /// behind our back, and the protocol must report what is true now.
    static func isRawMode(fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var current = termios()
        guard tcgetattr(fd, &current) == 0 else { return false }
        return (current.c_lflag & tcflag_t(ICANON)) == 0 && (current.c_lflag & tcflag_t(ECHO)) == 0
    }

    static func windowSize(fd: Int32) -> (cols: Int, rows: Int)? {
        guard fd >= 0 else { return nil }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        let cols = Int(size.ws_col)
        let rows = Int(size.ws_row)
        guard cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    /// Push a new window size onto a PTY master and notify the foreground job.
    @discardableResult
    static func setWindowSize(fd: Int32, cols: Int, rows: Int) -> Bool {
        guard fd >= 0, cols > 0, rows > 0 else { return false }
        var size = winsize()
        size.ws_col = UInt16(min(cols, Int(UInt16.max)))
        size.ws_row = UInt16(min(rows, Int(UInt16.max)))
        return ioctl(fd, TIOCSWINSZ, &size) == 0
    }
}