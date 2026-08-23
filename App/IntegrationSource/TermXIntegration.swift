import Foundation
import TermXCore
import TermXPython
import TermXNode
import TermXClaude
import TermXLinux

public final class TermXIntegration {
    public let core: TermXCommandEngine
    public let python: EmbeddedPythonService
    public let node: EmbeddedNodeService
    public let linux: BlinkLinuxService
    public let claude: ClaudeCodeService

    public init() {
        core = TermXCommandEngine()
        python = EmbeddedPythonService()
        node = EmbeddedNodeService()
        linux = BlinkLinuxService()
        claude = ClaudeCodeService(node: NodeAdapter(service: node))
        core.registry.registerFallback { [weak linux] request in
            guard let linux else { return 127 }
            return linux.runSync(request: request, write: { msg in
                if request.stderrFD >= 0 {
                    msg.utf8CString.withUnsafeBufferPointer { _ = write(request.stderrFD, $0.baseAddress!, $0.count - 1) }
                }
            })
        }
    }

    // MARK: - Terminal engine wiring (09-integration-contracts.md §2.2)

    /// The engine the app hands to TermXUI: TermXCore's interactive shell with the
    /// Python, Node, Claude, and Linux runtime commands registered into every session.
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
                // With any CLI args (`--version`, a prompt, …) run the real
                // installed package through Node — same as typing it on a Mac.
                // Bare `claude` keeps the first-run install + interactive TUI.
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

        // Unknown command? Try the Linux guest, so anything installed with `apk add`
        // (git, curl, vim …) runs by bare name. Each shell session owns its own
        // registry, so the fallback has to be attached here as well as on the engine.
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
