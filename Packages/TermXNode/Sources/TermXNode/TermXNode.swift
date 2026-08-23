import Foundation
import TermXCore

// MARK: - Frozen NodeService protocol (09-integration-contracts.md §2.4)

public protocol NodeService: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt()
}

// MARK: - Spawn bridge consumed by @termx/shim IPC

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
    private let engine: TermXCommandEngine
    private var nextPID: Int32 = 9000

    public init(engine: TermXCommandEngine = TermXCommandEngine()) {
        self.engine = engine
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
    private let queue = DispatchQueue(label: "com.termx.node.jobs", qos: .userInitiated)
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

                let mergedEnv = NodeEnvironment.merge(base: env, cwd: cwd)
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

    public func interrupt() {
        lock.lock()
        interrupted = true
        let job = currentJob
        lock.unlock()
        job?.cancel()
        runtime.interrupt()
    }

    private static func writeFD(_ fd: Int32, _ text: String) {
        guard fd >= 0 else { return }
        text.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
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
    public static func merge(base: [String: String], cwd: String, home: String? = nil) -> [String: String] {
        let resolvedHome = home ?? base["HOME"] ?? NSHomeDirectory() + "/Documents"
        var env = base
        env["HOME"] = resolvedHome
        env["NODE_PATH"] = env["NODE_PATH"] ?? "\(resolvedHome)/node/lib/node_modules"
        env["npm_config_prefix"] = env["npm_config_prefix"] ?? "\(resolvedHome)/node"
        env["PATH"] = env["PATH"] ?? "/bin:\(resolvedHome)/node/bin:\(resolvedHome)/python/bin"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PWD"] = cwd
        return env
    }
}
