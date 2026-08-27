import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TermXCore
import TetherJobControl

// MARK: - Node runtime protocol

public protocol NodeService: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt(forceNodeSignal: Bool)
    /// Terminal geometry changed; forward it to a running job.
    func resize(cols: Int, rows: Int)
}

// MARK: - Spawn bridge consumed by @tether/shim IPC

public struct RecordedSpawn: Equatable, Sendable {
    public let file: String
    public let args: [String]
    public let cwd: String
    public let interactive: Bool
}

public protocol SpawnExecuting: AnyObject {
    func spawnSync(file: String, args: [String], cwd: String, env: [String: String],
                   stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                   interactive: Bool) -> SpawnResult
    func signal(pid: Int32, signal: Int32)
}

public struct SpawnResult: Sendable {
    public let pid: Int32
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let signal: String?

    public init(pid: Int32, exitCode: Int32, stdout: String, stderr: String, signal: String? = nil) {
        self.pid = pid
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.signal = signal
    }
}

public final class RegistrySpawnExecutor: SpawnExecuting {
    /// One shared engine for all Node spawn IPC — avoids registering every builtin twice at launch.
    private static let sharedEngine = TermXCommandEngine()
    private let engine: TermXCommandEngine

    /// Job identity and signal routing. Ids handed out here are `JobID`s, so a
    /// signal aimed at one can actually be routed — the previous counter
    /// (`VirtualChildPID`) produced numbers nothing could act on, which is why
    /// `signal` was a silent no-op.
    private let backend = LaneSignalBackend()
    private let jobs: TetherJobControl.JobTable
    private let jobsLock = NSLock()

    /// Delivers a signal to whichever runtime lane is executing the job.
    /// Injected by the integration, which is the only layer that knows which
    /// lanes exist; kept generic so no command name appears here.
    public var laneSignalHandler: ((Int32, Int32) -> Bool)? {
        get { backend.handler }
        set { backend.handler = newValue }
    }

    public init(engine: TermXCommandEngine? = nil) {
        self.engine = engine ?? Self.sharedEngine
        self.jobs = TetherJobControl.JobTable(backend: backend, clock: DispatchJobClock())
    }

    public func spawnSync(file: String, args: [String], cwd: String, env: [String: String],
                          stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                          interactive: Bool) -> SpawnResult {
        jobsLock.lock()
        let id = jobs.register(
            TetherJobControl.JobSpec(argv: [file] + args, group: nil, isForegroundCandidate: interactive)
        )
        jobs.markRunning(id)
        jobsLock.unlock()
        let pid = id.raw
        defer {
            jobsLock.lock()
            jobs.markExited(id, code: nil, signal: nil)
            _ = jobs.reapExited()
            jobsLock.unlock()
        }
        var capturedOut = ""
        var capturedErr = ""
        let writeOut: (String) -> Void = { text in
            capturedOut += text
            if stdoutFD >= 0 { _ = Self.writeFD(stdoutFD, text) }
        }
        let writeErr: (String) -> Void = { text in
            capturedErr += text
            if stderrFD >= 0 { _ = Self.writeFD(stderrFD, text) }
        }
        let cmdline = ([file] + args).map(Self.shellQuote).joined(separator: " ")
        let code = engine.run(
            SpawnRequest(cmdline: cmdline, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                         cwd: cwd, environment: env, interactive: interactive),
            write: { text in writeOut(text) }
        )
        if code != 0, !capturedErr.isEmpty { /* stderr may already be written */ }
        _ = writeErr // keep signature parity for future stderr routing
        return SpawnResult(pid: pid, exitCode: code, stdout: capturedOut, stderr: capturedErr)
    }

    /// Route a signal to a live job. Unknown or already-finished pids are a
    /// no-op, exactly as `kill(2)` reports `ESRCH`; a live one reaches the
    /// runtime lane that is executing it.
    public func signal(pid: Int32, signal: Int32) {
        jobsLock.lock()
        defer { jobsLock.unlock() }
        let id = TetherJobControl.JobID(raw: pid)
        guard jobs.state(of: id) != nil else { return }
        guard let name = Self.signalName(signal) else { return }
        _ = jobs.signal(name, to: .job(id))
    }

    static func signalName(_ signal: Int32) -> TetherJobControl.JobSignal? {
        switch signal {
        case Int32(SIGINT): return .int
        case Int32(SIGTERM): return .term
        case Int32(SIGKILL): return .kill
        case Int32(SIGHUP): return .hup
        case Int32(SIGQUIT): return .quit
        case Int32(SIGWINCH): return .winch
        case Int32(SIGTSTP): return .tstp
        case Int32(SIGCONT): return .cont
        default: return nil
        }
    }

    private static func writeFD(_ fd: Int32, _ text: String) -> Int {
        text.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
    }

    private static func shellQuote(_ token: String) -> String {
        if token.isEmpty { return "''" }
        if token.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Embedded Node service

public final class EmbeddedNodeService: NodeService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.tether.node.jobs", qos: .userInitiated)
    private let runtime: NodeRuntime
    private var currentJob: NodeRunningJob?
    private var interrupted = false
    private let lock = NSLock()

    public init(spawnExecutor: SpawnExecuting = RegistrySpawnExecutor()) {
        runtime = NodeRuntimeFactory.make(spawnExecutor: spawnExecutor)
    }

    public func run(argv: [String], cwd: String, env: [String: String],
                    stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                    interactive: Bool) async -> Int32 {
        guard !argv.isEmpty else { return 2 }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: 1)
                    return
                }
                self.lock.lock()
                self.interrupted = false
                self.lock.unlock()

                var mergedEnv = NodeEnvironment.merge(base: env, cwd: cwd, interactive: interactive)
                if Self.isNpmVersionProbe(argv) {
                    // Avoid ora/progress spinners on a sub-second version probe.
                    mergedEnv["npm_config_progress"] = "false"
                    mergedEnv["npm_config_loglevel"] = "warn"
                }
                let home = mergedEnv["HOME"] ?? NSHomeDirectory() + "/Documents"

                // npm/npx bootstrap on first use, and bin-name resolution
                // (`claude` → node <resolved cli.js>). See NpmBootstrap.swift.
                var resolution = NodeCommandResolver.resolve(argv: argv, home: home)
                if case .needsNpm = resolution {
                    do {
                        try NpmBootstrap.install(home: home) { text in
                            Self.writeFD(stdoutFD, text)
                        }
                        resolution = NodeCommandResolver.resolve(argv: argv, home: home)
                    } catch {
                        Self.writeFD(stderrFD, "\(error)\n")
                        continuation.resume(returning: 1)
                        return
                    }
                }
                let finalArgv: [String]
                switch resolution {
                case .run(let rewritten):
                    finalArgv = rewritten
                case .needsNpm(let tool):
                    Self.writeFD(stderrFD, "\(tool): npm bootstrap did not produce a CLI\n")
                    continuation.resume(returning: 1)
                    return
                case .notFound(let name):
                    Self.writeFD(stderrFD, "\(name): not installed (try: npm install -g \(name))\n")
                    continuation.resume(returning: 127)
                    return
                }

                let job = NodeRunningJob(
                    argv: finalArgv, cwd: cwd, env: mergedEnv,
                    stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                    interactive: interactive
                )
                self.currentJob = job
                let code = self.runtime.run(job: job) { [weak self] in
                    self?.lock.lock()
                    defer { self?.lock.unlock() }
                    return self?.interrupted ?? false
                }
                self.currentJob = nil
                continuation.resume(returning: code)
            }
        }
    }

    public func interrupt(forceNodeSignal: Bool = false) {
        lock.lock()
        interrupted = true
        let job = currentJob
        lock.unlock()
        guard let job else { return }
        job.cancel()
        if forceNodeSignal || !job.interactive {
            if job.interactive {
                runtime.requestCancel()
            } else {
                runtime.interrupt()
            }
        } else {
            // Graceful Ctrl-C on an interactive TUI: deliver a real SIGINT
            // through the TJIP/2 session and let the program exit on its own
            // terms (restore the screen, show the cursor). The cancel-wait in
            // the runtime's reply loop is the backstop if it never does.
            runtime.signalActiveJob("SIGINT")
        }
    }

    /// Forward a terminal resize to the job currently running, if any.
    /// Without this a Node TUI never learns the window changed — the v1 lane
    /// had it poll for its own size, which is why rotation did not reflow.
    public func resize(cols: Int, rows: Int) {
        lock.lock()
        let hasJob = currentJob != nil
        lock.unlock()
        guard hasJob else { return }
        runtime.resize(cols: cols, rows: rows)
    }

    private static func isNpmVersionProbe(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        guard (first as NSString).lastPathComponent == "npm" else { return false }
        let args = Array(argv.dropFirst())
        return args == ["--version"] || args == ["-v"]
    }

    private static func writeFD(_ fd: Int32, _ text: String) {
        guard fd >= 0 else { return }
        text.withCString { ptr in
            let len = strlen(ptr)
            _ = write(fd, ptr, len)
            _ = fsync(fd)
        }
    }

    public var registryEntries: [[String: String]] {
        [
            ["name": "node", "kind": "node", "entry": "EmbeddedNodeService", "framework": "TermXNode"],
            ["name": "npm", "kind": "node", "entry": "EmbeddedNodeService", "framework": "TermXNode"],
        ]
    }

    /// Legacy single-entry accessor.
    public var registryEntry: [String: String] { registryEntries[0] }
}

public enum NodeShim {
    public static var bundleDirectory: URL? {
        if let index = Bundle.module.url(forResource: "index", withExtension: "js", subdirectory: "shim") {
            return index.deletingLastPathComponent()
        }
        return Bundle.module.resourceURL?.appendingPathComponent("shim")
    }

    public static var preloadPath: String? {
        bundleDirectory?.appendingPathComponent(useIPCv2 ? "index.v2.js" : "index.js").path
    }

    /// Selects the TJIP/2 IPC server and the v2 shim.
    ///
    /// v1 answered `isTTY` from `TETHER_INTERACTIVE`, hardcoded colour depth
    /// to 8, and polled for the window size, so no Node TUI ever received a
    /// real `SIGWINCH`. v2 derives all of it from the handshake and pushes
    /// resize events. Opt-in via `TETHER_IPC_V2=1` until the physical-device
    /// matrix in `docs/rework-plan/90-INTEGRATION-GLUE.md` passes — simulator
    /// verification alone does not clear that bar.
    public static var useIPCv2: Bool {
        let environment = ProcessInfo.processInfo.environment
        return (environment["TETHER_IPC_V2"] ?? "0") == "1"
    }

    public static var bootstrapPath: String? {
        bundleDirectory?.appendingPathComponent("bootstrap.js").path
    }

    public static var ensureIpcPath: String? {
        bundleDirectory?.appendingPathComponent("ensure-ipc.mjs").path
    }

    public static let requiredExports = ["spawn", "exec", "execSync", "fork", "spawnSync"]
}

public enum NodeEnvironment {
    public static func merge(base: [String: String], cwd: String, home: String? = nil,
                             interactive: Bool = false) -> [String: String] {
        let resolvedHome = home ?? base["HOME"] ?? NSHomeDirectory() + "/Documents"
        var env = base
        env["HOME"] = resolvedHome
        env["NODE_PATH"] = env["NODE_PATH"] ?? "\(resolvedHome)/node/lib/node_modules"
        env["npm_config_prefix"] = env["npm_config_prefix"] ?? "\(resolvedHome)/node"
        env["PATH"] = env["PATH"] ?? "/bin:\(resolvedHome)/node/bin:\(resolvedHome)/python/bin"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PWD"] = cwd
        if NodeShim.useIPCv2 {
            // On the v2 lane TTY truth comes from the TJIP/2 handshake, which
            // reports the fds that are genuinely PTY-bound. Leaving this flag
            // in the environment would only invite something to consult it.
            env.removeValue(forKey: "TETHER_INTERACTIVE")
            env.removeValue(forKey: "TERMX_INTERACTIVE")
        } else {
            let interactiveValue = interactive ? "1" : (env["TETHER_INTERACTIVE"] ?? env["TERMX_INTERACTIVE"] ?? "0")
            env["TETHER_INTERACTIVE"] = interactiveValue
            env["TERMX_INTERACTIVE"] = interactiveValue
        }
        // Quiet defaults for harness/CI; interactive terminal gets live npm output.
        env["npm_config_update_notifier"] = env["npm_config_update_notifier"] ?? "false"
        env["npm_config_fund"] = env["npm_config_fund"] ?? "false"
        env["npm_config_audit"] = env["npm_config_audit"] ?? "false"
        // npm ora spinners (progress=true) use setInterval + \\r redraws that often
        // never stop cleanly in the embedded engine — use loglevel=info lines instead.
        env["npm_config_progress"] = env["npm_config_progress"] ?? "false"
        if interactive {
            env["npm_config_loglevel"] = env["npm_config_loglevel"] ?? "info"
        }
        env["npm_config_fetch_retries"] = env["npm_config_fetch_retries"] ?? "2"
        env["npm_config_fetch_retry_mintimeout"] = env["npm_config_fetch_retry_mintimeout"] ?? "5000"
        env["npm_config_fetch_retry_maxtimeout"] = env["npm_config_fetch_retry_maxtimeout"] ?? "20000"
        env["npm_config_maxsockets"] = env["npm_config_maxsockets"] ?? "8"
        return env
    }
}

/// `JobBackend` for the registry lane. The registry itself runs commands
/// in-process, so a signal is delivered by asking the runtime lane executing
/// the job to interrupt — the integration supplies that handler.
final class LaneSignalBackend: TetherJobControl.JobBackend {
    var handler: ((Int32, Int32) -> Bool)?

    func deliver(_ signal: TetherJobControl.JobSignal, to job: TetherJobControl.JobID) -> Bool {
        guard let handler else { return false }
        return handler(job.raw, Self.number(signal))
    }

    func forceTerminate(_ job: TetherJobControl.JobID) {
        _ = handler?(job.raw, Int32(SIGKILL))
    }

    private static func number(_ signal: TetherJobControl.JobSignal) -> Int32 {
        switch signal {
        case .int: return Int32(SIGINT)
        case .term: return Int32(SIGTERM)
        case .kill: return Int32(SIGKILL)
        case .hup: return Int32(SIGHUP)
        case .quit: return Int32(SIGQUIT)
        case .winch: return Int32(SIGWINCH)
        case .tstp: return Int32(SIGTSTP)
        case .cont: return Int32(SIGCONT)
        }
    }
}
