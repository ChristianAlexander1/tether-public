import Foundation

#if os(macOS)
/// macOS / host-Node runtime: one Node process per job with @tether/shim IPC into the command engine.
final class HostNodeRuntime: NodeRuntime {
    private let spawnExecutor: SpawnExecuting
    private var currentProcess: Process?
    private var activeIPCServer: NodeJobIPCServer?
    private let lock = NSLock()

    init(spawnExecutor: SpawnExecuting) {
        self.spawnExecutor = spawnExecutor
    }

    func run(job: NodeRunningJob, shouldInterrupt: @escaping () -> Bool) -> Int32 {
        guard let nodePath = Self.resolveNodeBinary() else { return 127 }
        guard let shimPreload = NodeShim.preloadPath else { return 127 }

        var env = job.env
        let stdio = NodeJobStdio(
            stdinFD: job.stdinFD,
            stdoutFD: job.stdoutFD,
            stderrFD: job.stderrFD,
            stdinBound: job.interactive && job.stdinFD >= 0 && isatty(job.stdinFD) != 0
        )
        let server: NodeJobIPCServer
        do {
            server = try NodeJobIPCServer(executor: spawnExecutor)
        } catch {
            Self.writeAll(Data("node: IPC startup failed: \(error.localizedDescription)\n".utf8),
                          to: job.stderrFD)
            return 1
        }
        server.start(stdio: stdio, cwd: job.cwd, env: job.env)
        env["TETHER_IPC_SOCK"] = server.path
        env["TERMX_IPC_SOCKET"] = server.path
        env.removeValue(forKey: "TETHER_INTERACTIVE")
        env.removeValue(forKey: "TERMX_INTERACTIVE")

        var pump: NodeStdinPump?
        if stdio.stdinBound, job.stdinFD >= 0 {
            pump = NodeStdinPump(fd: job.stdinFD) { data in
                server.pushStdin(data)
            }
            pump?.start()
        }

        lock.lock()
        activeIPCServer = server
        lock.unlock()
        defer {
            pump?.stop()
            lock.lock()
            activeIPCServer = nil
            lock.unlock()
            server.stop()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.currentDirectoryURL = URL(fileURLWithPath: job.cwd)

        var nodeOptionsParts: [String] = []
        nodeOptionsParts.append("--require \(shimPreload)")
        env["NODE_OPTIONS"] = nodeOptionsParts.joined(separator: " ")
        env["TETHER_IPC_V2"] = "1"
        process.environment = env

        if let cmd = job.argv.first {
            if cmd == "node" || cmd.hasSuffix("/node") {
                process.executableURL = URL(fileURLWithPath: cmd.hasSuffix("/node") ? cmd : nodePath)
                process.arguments = Array(job.argv.dropFirst())
            } else if FileManager.default.isExecutableFile(atPath: cmd) {
                process.executableURL = URL(fileURLWithPath: cmd)
                process.arguments = Array(job.argv.dropFirst())
            } else if let resolved = Self.which(cmd) {
                process.executableURL = URL(fileURLWithPath: resolved)
                process.arguments = Array(job.argv.dropFirst())
            } else {
                process.executableURL = URL(fileURLWithPath: nodePath)
                process.arguments = job.argv
            }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // TTY stdin is the live IPC channel, not an OS pipe: nodejs-mobile
        // cannot poll a borrowed PTY, and the v2 shim installs its own Readable.
        // Piped (non-TTY) stdin still has a real EOF, so it is forwarded here.
        if job.stdinFD >= 0, isatty(job.stdinFD) == 0 {
            let inPipe = Pipe()
            process.standardInput = inPipe
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(job.stdinFD, &buf, buf.count)
                    if n <= 0 { break }
                    inPipe.fileHandleForWriting.write(Data(buf[0..<n]))
                }
                try? inPipe.fileHandleForWriting.close()
            }
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        lock.lock()
        currentProcess = process
        lock.unlock()

        var exitCode: Int32 = 1
        do {
            try process.run()

            let drainGroup = DispatchGroup()
            drainGroup.enter()
            DispatchQueue.global().async {
                defer { drainGroup.leave() }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if job.stdoutFD >= 0, !data.isEmpty {
                    Self.writeAll(data, to: job.stdoutFD)
                }
            }
            drainGroup.enter()
            DispatchQueue.global().async {
                defer { drainGroup.leave() }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                if job.stderrFD >= 0, !data.isEmpty {
                    Self.writeAll(data, to: job.stderrFD)
                }
            }

            var cancellationStartedAt: Date?
            var sentTerminate = false
            var sentKill = false
            while process.isRunning {
                if shouldInterrupt() || job.cancelled {
                    if cancellationStartedAt == nil {
                        cancellationStartedAt = Date()
                        process.interrupt()
                    } else if let started = cancellationStartedAt {
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed >= 2, !sentKill {
                            sentKill = true
                            _ = kill(process.processIdentifier, SIGKILL)
                        } else if elapsed >= 1, !sentTerminate {
                            sentTerminate = true
                            process.terminate()
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            exitCode = Int32(process.terminationStatus)
            drainGroup.wait()
        } catch {
            let message = Data("node: failed to launch: \(error.localizedDescription)\n".utf8)
            if job.stderrFD >= 0 {
                Self.writeAll(message, to: job.stderrFD)
            }
            exitCode = 1
        }

        lock.lock()
        currentProcess = nil
        lock.unlock()
        return exitCode
    }

    func interrupt() {
        lock.lock()
        defer { lock.unlock() }
        currentProcess?.interrupt()
    }

    func requestCancel() {
        interrupt()
    }

    /// v2: push the geometry through TJIP/2 (the child runs on PTY-less pipes,
    /// so the OS will not deliver SIGWINCH to it). v1 relied on polling.
    func resize(cols: Int, rows: Int) {
        lock.lock()
        let server = activeIPCServer
        lock.unlock()
        server?.pushResize(cols: cols, rows: rows)
    }

    /// v2: a real signal event through TJIP/2 so the program runs its own
    /// teardown. Without a v2 session, fall back to a POSIX SIGINT.
    func signalActiveJob(_ name: String) {
        lock.lock()
        let server = activeIPCServer
        lock.unlock()
        server?.pushSignal(name)
    }

    func pushStdin(_ data: Data) {
        lock.lock()
        let server = activeIPCServer
        lock.unlock()
        server?.pushStdin(data)
    }

    var foregroundIsRaw: Bool {
        lock.lock()
        let server = activeIPCServer
        lock.unlock()
        return server?.foregroundIsRaw ?? false
    }

    private static func which(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = write(fd, base.advanced(by: written), raw.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private static func resolveNodeBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["NODE_BINARY"] {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif
