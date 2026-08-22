import Foundation

// MARK: - C API Bridge (termx_core.h)

/// Swift mirror of `termx_spawn_req` from `include/termx_core.h` (ABI-compatible layout).
public struct termx_spawn_req {
    public var cmdline: UnsafePointer<CChar>?
    public var stdin_fd: Int32
    public var stdout_fd: Int32
    public var stderr_fd: Int32
    public var cwd: UnsafePointer<CChar>?
    public var envp: UnsafePointer<UnsafePointer<CChar>?>?
    public var interactive: Bool

    public init(cmdline: UnsafePointer<CChar>? = nil,
                stdin_fd: Int32 = -1, stdout_fd: Int32 = -1, stderr_fd: Int32 = -1,
                cwd: UnsafePointer<CChar>? = nil,
                envp: UnsafePointer<UnsafePointer<CChar>?>? = nil,
                interactive: Bool = false) {
        self.cmdline = cmdline
        self.stdin_fd = stdin_fd
        self.stdout_fd = stdout_fd
        self.stderr_fd = stderr_fd
        self.cwd = cwd
        self.envp = envp
        self.interactive = interactive
    }
}

/// Global engine backing the frozen C API from docs/09-integration-contracts.md §2.1.
public final class TermXCoreRuntime: @unchecked Sendable {
    public static let shared = TermXCoreRuntime()

    public let engine: TermXShellEngine
    public let registry: CommandRegistry
    private let initLock = NSLock()
    private var didInstallDefaults = false

    private init() {
        registry = CommandRegistry()
        engine = TermXShellEngine(registry: registry)
        installDefaults()
    }

    private func installDefaults() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !didInstallDefaults else { return }

        _ = registry.register(name: "true") { _ in 0 }
        _ = registry.register(name: "false") { _ in 1 }
        _ = registry.register(name: "echo") { argv in
            let text = Array(argv.dropFirst()).joined(separator: " ")
            if let proc = ProcessContext.current {
                proc.writeStdout(text + "\n")
            }
            return 0
        }
        _ = registry.register(name: "pwd") { _ in
            if let proc = ProcessContext.current {
                proc.writeStdout(proc.cwd + "\n")
            }
            return 0
        }

        let builtins = Builtins()
        builtins.install(into: registry)
        CoreCommands.registerAll(into: registry)
        ToolCommands.registerAll(into: registry)
        ExternalCommands.registerAll(into: registry)
        didInstallDefaults = true
    }

    func spawnRequest(from req: termx_spawn_req) -> SpawnRequest? {
        guard let cmdline = req.cmdline, let cwd = req.cwd else { return nil }
        var env: [String: String] = [:]
        if let envp = req.envp {
            var idx = 0
            while let entry = envp[idx] {
                let pair = String(cString: entry)
                if let eq = pair.firstIndex(of: "=") {
                    let key = String(pair[pair.startIndex..<eq])
                    let value = String(pair[pair.index(after: eq)...])
                    env[key] = value
                }
                idx += 1
            }
        }
        return SpawnRequest(
            cmdline: String(cString: cmdline),
            stdinFD: req.stdin_fd,
            stdoutFD: req.stdout_fd,
            stderrFD: req.stderr_fd,
            cwd: String(cString: cwd),
            environment: env,
            interactive: req.interactive
        )
    }
}

private func makeCStringArray(from argv: [String]) -> [UnsafeMutablePointer<CChar>?] {
    argv.map { strdup($0) }
}

private func freeCStringArray(_ arr: [UnsafeMutablePointer<CChar>?]) {
    for ptr in arr { free(ptr) }
}

private func loadSpawnRequest(_ raw: UnsafeRawPointer?) -> termx_spawn_req? {
    guard let raw else { return nil }
    return raw.assumingMemoryBound(to: termx_spawn_req.self).pointee
}

@_cdecl("termx_spawn")
public func termx_spawn(_ req: UnsafeRawPointer?) -> Int32 {
    guard let cReq = loadSpawnRequest(req) else { return -Int32(EINVAL) }
    guard let spawnReq = TermXCoreRuntime.shared.spawnRequest(from: cReq) else {
        return -Int32(EINVAL)
    }
    let pid = TermXCoreRuntime.shared.engine.termxSpawn(spawnReq)
    return pid > 0 ? pid : -Int32(EINVAL)
}

@_cdecl("termx_wait")
public func termx_wait(_ pid: Int32, _ exitCode: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let exitCode else { return -Int32(EINVAL) }
    var code: Int32 = 0
    let result = TermXCoreRuntime.shared.engine.termxWait(pid, exitCode: &code)
    exitCode.pointee = code
    return result
}

@_cdecl("termx_signal")
public func termx_signal(_ pid: Int32, _ sig: Int32) -> Int32 {
    TermXCoreRuntime.shared.engine.signal(pid: pid, sig)
    return 0
}

@_cdecl("termx_run")
public func termx_run(_ req: UnsafeRawPointer?, _ exitCode: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let cReq = loadSpawnRequest(req) else { return -Int32(EINVAL) }
    guard let exitCode else { return -Int32(EINVAL) }
    guard let spawnReq = TermXCoreRuntime.shared.spawnRequest(from: cReq) else {
        return -Int32(EINVAL)
    }
    var code: Int32 = 0
    let result = TermXCoreRuntime.shared.engine.termxRun(spawnReq, exitCode: &code)
    exitCode.pointee = code
    return result
}

@_cdecl("termx_register_command")
public func termx_register_command(_ name: UnsafePointer<CChar>?,
                                   _ entry: (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?) -> Int32 {
    guard let name, let entry else { return -1 }
    let cmdName = String(cString: name)
    let ok = TermXCoreRuntime.shared.registry.register(name: cmdName) { argv in
        var cArgs = makeCStringArray(from: argv)
        defer { freeCStringArray(cArgs) }
        return cArgs.withUnsafeMutableBufferPointer { buf in
            entry(Int32(argv.count), buf.baseAddress)
        }
    }
    return ok ? 0 : -1
}

@_cdecl("termx_register_fallback")
public func termx_register_fallback(_ canRun: (@convention(c) (UnsafePointer<CChar>?) -> Bool)?,
                                    _ run: (@convention(c) (UnsafeRawPointer?) -> Int32)?) -> Int32 {
    guard let canRun, let run else { return -1 }
    TermXCoreRuntime.shared.registry.registerFallback { request in
        let tokens = ShellLexer.lex(request.cmdline)
        guard let cmd = tokens.first else { return 127 }
        let cmdCString = (cmd as NSString).utf8String
        guard canRun(cmdCString) else { return 127 }

        var cReq = termx_spawn_req(
            cmdline: (request.cmdline as NSString).utf8String,
            stdin_fd: request.stdinFD,
            stdout_fd: request.stdoutFD,
            stderr_fd: request.stderrFD,
            cwd: (request.cwd as NSString).utf8String,
            envp: nil,
            interactive: request.interactive
        )
        return withUnsafePointer(to: &cReq) { run(UnsafeRawPointer($0)) }
    }
    return 0
}
