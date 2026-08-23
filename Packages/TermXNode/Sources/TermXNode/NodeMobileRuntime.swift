import Foundation
#if os(iOS)
import NodeMobileBridge
#endif

/// iOS nodejs-mobile runtime. Starts `node_start()` once on a dedicated thread with
/// `bootstrap.js` + `@termx/shim` preload; jobs are serialized by `EmbeddedNodeService`.
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
    #else
    private let spawnExecutor: SpawnExecuting
    private let engineLock = NSLock()
    private var engineStarted = false
    private var jobWriteFD: Int32 = -1
    private var jobReadFD: Int32 = -1
    private var launchArgvStorage: [String] = []
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

        let bridge = NodeSpawnBridge(executor: spawnExecutor)
        guard let server = NodeSocketServer(directory: job.cwd) else { return 1 }
        server.start(
            bridge: bridge,
            stdinFD: job.stdinFD, stdoutFD: job.stdoutFD, stderrFD: job.stderrFD,
            cwd: job.cwd, env: job.env, interactive: job.interactive
        )
        defer { server.stop() }

        var env = job.env
        env["TERMX_IPC_SOCKET"] = server.path
        env["TERMX_INTERACTIVE"] = job.interactive ? "1" : "0"

        guard let payload = Self.makeBootstrapPayload(from: job, env: env),
              let line = try? JSONSerialization.data(withJSONObject: payload) else {
            return 1
        }

        var request = line
        request.append(0x0A)

        return NodeStdioBridge.withRedirectedOutput(stdoutFD: job.stdoutFD, stderrFD: job.stderrFD) {
            let stdinPump = Self.startStdinPump(from: job.stdinFD)
            defer { stdinPump?.stop() }

            let wrote = request.withUnsafeBytes { raw in
                write(jobWriteFD, raw.baseAddress!, request.count)
            }
            guard wrote == request.count else { return 1 }

            guard let reply = Self.readReply(from: jobReadFD, shouldInterrupt: shouldInterrupt) else {
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
        termx_node_request_interrupt()
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
            return .failure("node: @termx/shim resources missing from bundle\n")
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

        guard let ready = Self.readReply(from: jobReadFD, shouldInterrupt: { false }),
              ready["ready"] as? Bool == true else {
            let err = (try? Self.readReply(from: jobReadFD, shouldInterrupt: { false }))?["error"] as? String
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

    private static func readReply(from fd: Int32, shouldInterrupt: @escaping () -> Bool) -> [String: Any]? {
        guard fd >= 0 else { return nil }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if shouldInterrupt() {
                termx_node_request_interrupt()
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

    /// Forwards the job's stdin into the embedded engine for as long as the job runs.
    ///
    /// The pump must be stoppable: `DispatchWorkItem.cancel()` cannot interrupt a thread
    /// already blocked in `read()`, and this fd is the terminal's pty. Left running, a
    /// finished job's pump keeps swallowing everything the user types afterwards, so the
    /// loop polls with a timeout and checks a stop flag instead of blocking forever.
    final class StdinPump {
        private let fd: Int32
        private let lock = NSLock()
        private var stopped = false
        private let finished = DispatchSemaphore(value: 0)

        init(fd: Int32) {
            self.fd = fd
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.loop()
            }
        }

        private var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }; return stopped
        }

        private func loop() {
            defer { finished.signal() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while !isStopped {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                if pfd.revents & Int16(POLLNVAL) != 0 { return }
                let n = read(fd, &buf, buf.count)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if n <= 0 { return }
                _ = buf.withUnsafeBytes { raw in
                    write(STDIN_FILENO, raw.baseAddress!, n)
                }
            }
        }

        func stop() {
            lock.lock(); stopped = true; lock.unlock()
            _ = finished.wait(timeout: .now() + 1.0)
        }
    }

    private static func startStdinPump(from fd: Int32) -> StdinPump? {
        guard fd >= 0 else { return nil }
        return StdinPump(fd: fd)
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
