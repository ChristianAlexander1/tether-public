import Foundation
#if os(iOS)
import NodeMobileBridge
#endif

/// iOS nodejs-mobile runtime. Starts `node_start()` once on a dedicated thread with
/// `bootstrap.js` + `@tether/shim` preload; jobs are serialized by `EmbeddedNodeService`.
final class NodeMobileRuntime: NodeRuntime {
    #if os(macOS)
    private let hostFallback: HostNodeRuntime

    init(spawnExecutor: SpawnExecuting) {
        self.hostFallback = HostNodeRuntime(spawnExecutor: spawnExecutor)
    }

    func run(job: NodeRunningJob, shouldInterrupt: @escaping () -> Bool) -> Int32 {
        hostFallback.run(job: job, shouldInterrupt: shouldInterrupt)
    }

    func interrupt() {
        hostFallback.interrupt()
    }

    func requestCancel() {
        hostFallback.requestCancel()
    }

    func resize(cols: Int, rows: Int) {
        hostFallback.resize(cols: cols, rows: rows)
    }

    func signalActiveJob(_ name: String) {
        hostFallback.signalActiveJob(name)
    }
    #else
    private let spawnExecutor: SpawnExecuting
    private let engineLock = NSLock()
    private var engineStarted = false
    private var jobWriteFD: Int32 = -1
    private var jobReadFD: Int32 = -1
    private var launchArgvStorage: [String] = []
    /// The TJIP/2 server for the job currently running, so the terminal can
    /// push resize and signal events into it.
    private var activeIPCServer: NodeJobIPCServer?
    private var launchCStrings: [UnsafeMutablePointer<CChar>?] = []

    init(spawnExecutor: SpawnExecuting) {
        self.spawnExecutor = spawnExecutor
    }

    func run(job: NodeRunningJob, shouldInterrupt: @escaping () -> Bool) -> Int32 {
        switch ensureEngineStarted(baseEnv: job.env, cwd: job.cwd) {
        case .failure(let message):
            writeStderr(job, message)
            return 127
        case .success:
            break
        }

        // `withRedirectedIO` binds stdin to fd 0 only when the job is
        // interactive *and* its stdin descriptor is a real terminal. The
        // handshake must describe that same wiring, so compute it once here
        // and share it with both.
        let stdio = NodeJobStdio(
            stdinFD: job.stdinFD,
            stdoutFD: job.stdoutFD,
            stderrFD: job.stderrFD,
            stdinBound: job.interactive && job.stdinFD >= 0 && isatty(job.stdinFD) != 0
        )

        var env = job.env
        var ipcV2Server: NodeJobIPCServer?
        var legacyServer: NodeSocketServer?

        if NodeShim.useIPCv2 {
            guard let server = NodeJobIPCServer(executor: spawnExecutor) else { return 1 }
            server.start(stdio: stdio, cwd: job.cwd, env: job.env)
            ipcV2Server = server
            activeIPCServer = server
            env["TETHER_IPC_SOCK"] = server.path
            env["TERMX_IPC_SOCKET"] = server.path
            // No TETHER_INTERACTIVE on this lane — see NodeShim.useIPCv2.
            env.removeValue(forKey: "TETHER_INTERACTIVE")
            env.removeValue(forKey: "TERMX_INTERACTIVE")
        } else {
            let bridge = NodeSpawnBridge(executor: spawnExecutor)
            guard let server = NodeSocketServer(directory: job.cwd) else { return 1 }
            server.start(
                bridge: bridge,
                stdinFD: job.stdinFD, stdoutFD: job.stdoutFD, stderrFD: job.stderrFD,
                cwd: job.cwd, env: job.env, interactive: job.interactive
            )
            legacyServer = server
            env["TETHER_IPC_SOCK"] = server.path
            env["TERMX_IPC_SOCKET"] = server.path
            env["TETHER_INTERACTIVE"] = job.interactive ? "1" : "0"
            env["TERMX_INTERACTIVE"] = job.interactive ? "1" : "0"
        }

        defer {
            ipcV2Server?.stop()
            legacyServer?.stop()
            if activeIPCServer === ipcV2Server { activeIPCServer = nil }
        }

        guard let payload = Self.makeBootstrapPayload(from: job, env: env),
              let line = try? JSONSerialization.data(withJSONObject: payload) else {
            return 1
        }

        var request = line
        request.append(0x0A)

        return NodeStdioBridge.withRedirectedIO(
            stdinFD: job.stdinFD,
            stdoutFD: job.stdoutFD,
            stderrFD: job.stderrFD,
            interactive: job.interactive
        ) {
            // Piped stdin is declared on the job payload (`stdinFD`) and read in
            // bootstrap.js. Do not pump into STDIN_FILENO — that never delivers
            // EOF and leaked listeners into later jobs.
            let wrote = request.withUnsafeBytes { raw in
                write(jobWriteFD, raw.baseAddress!, request.count)
            }
            guard wrote == request.count else { return 1 }

            guard let reply = Self.readReply(
                from: jobReadFD,
                interactive: job.interactive,
                shouldInterrupt: shouldInterrupt
            ) else {
                return job.cancelled ? 130 : 1
            }
            if let err = reply["error"] as? String, !err.isEmpty {
                writeStderr(job, err.hasSuffix("\n") ? err : err + "\n")
            }
            if let code = reply["exitCode"] as? Int {
                return Int32(code)
            }
            if let code = reply["exitCode"] as? NSNumber {
                return code.int32Value
            }
            return 1
        }
    }

    func interrupt() {
        // On the v2 lane a running job's foreground child gets a real SIGINT
        // through the protocol before we fall back to aborting the engine.
        activeIPCServer?.pushSignal("SIGINT")
        termx_node_request_interrupt()
    }

    /// Push a new terminal size into the running job (real `SIGWINCH` for a
    /// Node TUI — impossible on the v1 lane, which polled instead).
    func resize(cols: Int, rows: Int) {
        activeIPCServer?.pushResize(cols: cols, rows: rows)
    }

    /// Graceful signal into the running job over TJIP/2, with no engine-level
    /// interrupt: the program gets to run its own teardown (a TUI leaves the
    /// alternate screen, restores the cursor) instead of being aborted.
    func signalActiveJob(_ name: String) {
        activeIPCServer?.pushSignal(name)
    }

    func requestCancel() {
        guard jobWriteFD >= 0 else { return }
        let line = Data("{\"kind\":\"cancel\"}\n".utf8)
        _ = line.withUnsafeBytes { raw in
            write(jobWriteFD, raw.baseAddress!, line.count)
        }
    }

    private enum EngineStartResult {
        case success
        case failure(String)
    }

    private func ensureEngineStarted(baseEnv: [String: String], cwd: String) -> EngineStartResult {
        engineLock.lock()
        defer { engineLock.unlock() }
        if engineStarted { return .success }

        guard let shim = NodeShim.preloadPath, let bootstrap = NodeShim.bootstrapPath else {
            return .failure("node: @tether/shim resources missing from bundle\n")
        }

        guard let jobPipe = NodePipe.pair(), let replyPipe = NodePipe.pair() else {
            return .failure("node: failed to create job IPC pipes\n")
        }

        jobWriteFD = jobPipe.write
        jobReadFD = replyPipe.read

        // bootstrap.js polls the job fd with fs.readSync on an unref'd timer
        // (so 'beforeExit' can fire when a script's event loop drains); the fd
        // must be non-blocking or the first empty poll would block the engine.
        let flags = fcntl(jobPipe.read, F_GETFL)
        _ = fcntl(jobPipe.read, F_SETFL, flags | O_NONBLOCK)

        var env = NodeEnvironment.merge(base: baseEnv, cwd: cwd)
        // The engine is launched once; bootstrap.js reads this to pick the same
        // lane the Swift side did, so the v1 module shims are never layered
        // over v2's.
        env["TETHER_IPC_V2"] = NodeShim.useIPCv2 ? "1" : "0"
        env["TETHER_JOB_FD"] = String(jobPipe.read)
        env["TETHER_JOB_REPLY_FD"] = String(replyPipe.write)
        env["TERMX_JOB_FD"] = String(jobPipe.read)
        env["TERMX_JOB_REPLY_FD"] = String(replyPipe.write)
        for (key, value) in env {
            setenv(key, value, 1)
        }

        // iOS forbids writable+executable pages, so the shared Node engine
        // must never try to allocate JIT code. Keep this as an engine-start
        // flag rather than allowing individual jobs to override it.
        let argv = ["node", "--jitless", "--require", shim, bootstrap]
        guard storeLaunchArgv(argv) else {
            return .failure("node: failed to prepare node_start argv\n")
        }

        let rc = launchCStrings.withUnsafeMutableBufferPointer { buf in
            termx_node_launch(Int32(argv.count), buf.baseAddress!)
        }
        guard rc == 0 else {
            return .failure("node: node_start thread failed to launch (rc=\(rc))\n")
        }

        guard let ready = Self.readReply(from: jobReadFD, interactive: false, shouldInterrupt: { false }),
              ready["ready"] as? Bool == true else {
            let err = (try? Self.readReply(from: jobReadFD, interactive: false, shouldInterrupt: { false }))?["error"] as? String
            return .failure(err ?? "node: embedded engine did not become ready\n")
        }

        engineStarted = true
        return .success
    }

    private func storeLaunchArgv(_ argv: [String]) -> Bool {
        launchArgvStorage = argv
        launchCStrings = argv.map { strdup($0) }
        return launchCStrings.allSatisfy { $0 != nil }
    }

    private static func makeBootstrapPayload(from job: NodeRunningJob, env: [String: String]) -> [String: Any]? {
        var payload: [String: Any] = [
            "argv": job.argv,
            "cwd": job.cwd,
            "env": env,
            "interactive": job.interactive,
        ]
        // Pipe stdin is slurped in Swift (NodeStdinSlurp) and sent as base64 so the
        // engine never relies on libuv polling a borrowed fd after npm.
        if job.stdinFD >= 0, isatty(job.stdinFD) == 0,
           let slurped = NodeStdinSlurp.readPipeIfNeeded(fd: job.stdinFD) {
            payload["stdinData"] = slurped.base64EncodedString()
        }
        payload["stdinFD"] = -1

        var nodeArgs = job.argv
        let isNode = nodeArgs.first == "node" || (nodeArgs.first?.hasSuffix("/node") ?? false)
        if isNode {
            nodeArgs = Array(nodeArgs.dropFirst())
        }

        // Bare `node` has no script for runMain(), which crashed with
        // "paths[0] must be of type string"; the in-process REPL isn't wired up.
        if isNode, nodeArgs.isEmpty {
            payload["kind"] = "usageError"
            payload["message"] = "node: the interactive REPL isn't supported yet — "
                + "use node <script.js>, node -e \"code\", or node -p \"expr\""
            return payload
        }

        // Node's own CLI flags. Without these every flag falls through to the
        // module loader, so `node --version` came back as
        // "Cannot find module '--version'".
        if isNode, let flag = nodeArgs.first, flag.hasPrefix("-") {
            switch flag {
            case "--version", "-v":
                payload["kind"] = "version"
                return payload
            case "-h", "--help":
                payload["kind"] = "help"
                return payload
            case "-e", "--eval", "-p", "--print":
                guard nodeArgs.count >= 2 else {
                    payload["kind"] = "usageError"
                    payload["message"] = "node: \(flag) requires an argument"
                    return payload
                }
                payload["kind"] = (flag == "-p" || flag == "--print") ? "print" : "eval"
                payload["source"] = nodeArgs[1]
                return payload
            default:
                payload["kind"] = "usageError"
                payload["message"] = "node: bad option: \(flag)"
                return payload
            }
        }

        payload["kind"] = "script"
        return payload
    }

    private static func readReply(
        from fd: Int32,
        interactive: Bool,
        shouldInterrupt: @escaping () -> Bool
    ) -> [String: Any]? {
        guard fd >= 0 else { return nil }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var cancelWaitStart: Date?
        while true {
            if shouldInterrupt() {
                if interactive {
                    if cancelWaitStart == nil { cancelWaitStart = Date() }
                    if Date().timeIntervalSince(cancelWaitStart!) > 8.0 { return nil }
                } else {
                    termx_node_request_interrupt()
                    return nil
                }
            } else {
                cancelWaitStart = nil
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return nil
                }
                return obj
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func writeStderr(_ job: NodeRunningJob, _ message: String) {
        guard job.stderrFD >= 0 else { return }
        message.withCString { ptr in
            _ = write(job.stderrFD, ptr, strlen(ptr))
        }
    }
    #endif
}

#if os(iOS)
private extension Data {
    func firstIndex(of byte: UInt8) -> Data.Index? {
        for i in indices where self[i] == byte { return i }
        return nil
    }
}
#endif
