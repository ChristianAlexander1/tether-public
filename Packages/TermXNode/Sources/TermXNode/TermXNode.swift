import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TermXCore

// MARK: - Frozen NodeService protocol (09-integration-contracts.md §2.4)

public protocol NodeService: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt(forceNodeSignal: Bool)
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
    private var nextPID: Int32 = 9000

    public init(engine: TermXCommandEngine? = nil) {
        self.engine = engine ?? Self.sharedEngine
    }

    public func spawnSync(file: String, args: [String], cwd: String, env: [String: String],
                          stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                          interactive: Bool) -> SpawnResult {
        let pid = nextPID
        nextPID += 1
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

    public func signal(pid: Int32, signal: Int32) {
        _ = pid
        _ = signal
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

public final class EmbeddedNodeService: NodeService {
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
                if interactive {
                    // Belt-and-suspenders: clear any stuck ora spinner line on the PTY.
                    Self.writeFD(stderrFD, "\u{1B}[?25h\u{1B}[2K\r")
                }
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
        }
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
        bundleDirectory?.appendingPathComponent("index.js").path
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
        let interactiveValue = interactive ? "1" : (env["TETHER_INTERACTIVE"] ?? env["TERMX_INTERACTIVE"] ?? "0")
        env["TETHER_INTERACTIVE"] = interactiveValue
        env["TERMX_INTERACTIVE"] = interactiveValue
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
