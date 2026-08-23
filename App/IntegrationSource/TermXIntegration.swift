import Foundation
import TermXCore
import TermXPython
import TermXNode
import TermXClaude
import TermXLinux

/// Wires TermXCore's shell to Python, Node, Claude, and Linux runtimes.
///
/// Runtimes are **lazy**: nothing beyond path probes runs until the user actually
/// invokes `python3`, `node`, `linux`, etc. That keeps app launch light.
public final class TermXIntegration {
    private var _python: EmbeddedPythonService?
    private var _node: EmbeddedNodeService?
    private var _linux: BlinkLinuxService?
    private var _claude: ClaudeCodeService?

    public init() {}

    public var python: EmbeddedPythonService {
        if let existing = _python { return existing }
        let service = EmbeddedPythonService()
        _python = service
        return service
    }

    public var node: EmbeddedNodeService {
        if let existing = _node { return existing }
        let service = EmbeddedNodeService()
        _node = service
        return service
    }

    public var linux: BlinkLinuxService {
        if let existing = _linux { return existing }
        let service = BlinkLinuxService()
        _linux = service
        return service
    }

    public var claude: ClaudeCodeService {
        if let existing = _claude { return existing }
        let service = ClaudeCodeService(node: NodeAdapter(service: node))
        _claude = service
        return service
    }

    // MARK: - Terminal engine wiring (09-integration-contracts.md §2.2)

    public func makeShellEngine() -> TermXShellEngine {
        let engine = TermXShellEngine()
        engine.sessionConfigurator = { [weak self] session in
            self?.registerRuntimeCommands(into: session)
        }
        return engine
    }

    private func registerRuntimeCommands(into session: ShellSession) {
        let state = session.state

        func currentFDs() -> (Int32, Int32, Int32) {
            if let proc = ProcessContext.current {
                return (proc.stdinFD, proc.stdoutFD, proc.stderrFD)
            }
            return (state.stdinFD, state.stdoutFD, state.stderrFD)
        }
        func runBlocking(_ operation: @escaping @Sendable () async -> Int32) -> Int32 {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ExitCodeBox()
            Task.detached {
                box.value = await operation()
                semaphore.signal()
            }
            semaphore.wait()
            return box.value
        }

        for name in ["python3", "python"] {
            _ = session.registry.register(name: name) { [weak self] argv in
                guard let self else { return 127 }
                let (i, o, e) = currentFDs()
                var forwarded = argv; forwarded[0] = "python3"
                return runBlocking { await self.python.run(argv: forwarded, cwd: state.cwd, environment: state.environ, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: false) }
            }
        }
        for name in ["pip", "pip3"] {
            _ = session.registry.register(name: name) { [weak self] argv in
                guard let self else { return 127 }
                let (i, o, e) = currentFDs()
                let forwarded = ["python3", "-m", "pip"] + argv.dropFirst()
                return runBlocking { await self.python.run(argv: forwarded, cwd: state.cwd, environment: state.environ, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: false) }
            }
        }
        for name in ["node", "npm", "npx"] {
            _ = session.registry.register(name: name) { [weak self] argv in
                guard let self else { return 127 }
                let (i, o, e) = currentFDs()
                return runBlocking { await self.node.run(argv: argv, cwd: state.cwd, env: state.environ, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: false) }
            }
        }
        _ = session.registry.register(name: "claude") { [weak self] argv in
            guard let self else { return 127 }
            let (i, o, e) = currentFDs()
            return runBlocking {
                if argv.count > 1, argv[1] == "login" {
                    return await self.claude.login(cwd: state.cwd, env: state.environ, fds: (i, o, e))
                }
                if argv.count > 1 {
                    return await self.node.run(
                        argv: argv, cwd: state.cwd, env: state.environ,
                        stdinFD: i, stdoutFD: o, stderrFD: e, interactive: false
                    )
                }
                do {
                    _ = try await self.claude.install(cwd: state.cwd, env: state.environ, fds: (i, o, e))
                    return try await self.claude.run(cwd: state.cwd, env: state.environ, fds: (i, o, e))
                } catch {
                    let msg = "claude: \(error)\n"
                    if e >= 0 { msg.utf8CString.withUnsafeBufferPointer { _ = write(e, $0.baseAddress!, $0.count - 1) } }
                    return 1
                }
            }
        }
        _ = session.registry.register(name: "linux") { [weak self] argv in
            guard let self else { return 127 }
            let (i, o, e) = currentFDs()
            let guestArgv = argv.count > 1 ? Array(argv.dropFirst()) : ["/bin/sh"]
            return self.linux.runSync(argv: guestArgv, cwd: state.cwd, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: true)
        }

        session.registry.registerFallback { [weak self] request in
            guard let self else { return 127 }
            return self.linux.runSync(request: request, write: { message in
                let fd = ProcessContext.current?.stderrFD ?? request.stderrFD
                guard fd >= 0 else { return }
                message.utf8CString.withUnsafeBufferPointer {
                    _ = write(fd, $0.baseAddress!, $0.count - 1)
                }
            })
        }
    }
}

private final class ExitCodeBox: @unchecked Sendable {
    var value: Int32 = 1
}

private final class NodeAdapter: ClaudeNodeRunner {
    let service: EmbeddedNodeService
    init(service: EmbeddedNodeService) { self.service = service }
    func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 { await service.run(argv: argv, cwd: cwd, env: env, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: interactive) }
    func interrupt() { service.interrupt() }
}
