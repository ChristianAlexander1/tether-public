import Foundation

#if os(macOS)
/// macOS / host-Node runtime: one Node process per job with @termx/shim IPC into TermXCore.
final class HostNodeRuntime: NodeRuntime {
    private let spawnExecutor: SpawnExecuting
    private var currentProcess: Process?
    private let lock = NSLock()

    init(spawnExecutor: SpawnExecuting) {
        self.spawnExecutor = spawnExecutor
    }

    func run(job: NodeRunningJob, shouldInterrupt: @escaping () -> Bool) -> Int32 {
        guard let nodePath = Self.resolveNodeBinary() else { return 127 }
        guard let shimPreload = NodeShim.preloadPath else { return 127 }

        let bridge = NodeSpawnBridge(executor: spawnExecutor)
        guard let server = NodeSocketServer(directory: job.cwd) else { return 1 }
        server.start(
            bridge: bridge,
            stdinFD: job.stdinFD, stdoutFD: job.stdoutFD, stderrFD: job.stderrFD,
            cwd: job.cwd, env: job.env, interactive: job.interactive
        )
        defer { server.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.currentDirectoryURL = URL(fileURLWithPath: job.cwd)

        var env = job.env
        env["TERMX_IPC_SOCKET"] = server.path
        env["TERMX_INTERACTIVE"] = job.interactive ? "1" : "0"
        var nodeOptionsParts: [String] = []
        if let ensureIpc = NodeShim.ensureIpcPath {
            nodeOptionsParts.append("--import \(ensureIpc)")
        }
        nodeOptionsParts.append("--require \(shimPreload)")
        env["NODE_OPTIONS"] = nodeOptionsParts.joined(separator: " ")
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
        if job.stdinFD >= 0 {
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
        }

        lock.lock()
        currentProcess = process
        lock.unlock()

        var exitCode: Int32 = 1
        do {
            try process.run()

            DispatchQueue.global().async {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if job.stdoutFD >= 0, !data.isEmpty {
                    _ = data.withUnsafeBytes { ptr in
                        write(job.stdoutFD, ptr.baseAddress!, data.count)
                    }
                }
            }
            DispatchQueue.global().async {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                if job.stderrFD >= 0, !data.isEmpty {
                    _ = data.withUnsafeBytes { ptr in
                        write(job.stderrFD, ptr.baseAddress!, data.count)
                    }
                }
            }

            while process.isRunning {
                if shouldInterrupt() || job.cancelled {
                    process.interrupt()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            exitCode = Int32(process.terminationStatus)
        } catch {
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

    private static func which(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
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
