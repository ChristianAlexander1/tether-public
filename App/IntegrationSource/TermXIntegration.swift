import Foundation
import TermXCore
import TermXPython
import TermXNode
import TermXClaude
import TermXLinux
import TermXFiles

/// Wires TermXCore's shell to Python, Node, Claude, and Linux runtimes.
///
/// **Primary session = Alpine Linux** (Blink), Docker-style: the terminal *is*
/// the guest shell, workspace at `/work`. `claude` / `node` / `npm` are
/// host-backed from inside that shell (Bun cannot run under Blink).
///
/// Host `TermXShellEngine` remains available behind `TERMX_HOST_SHELL=1` for debugging.
public final class TermXIntegration {
    private var _python: EmbeddedPythonService?
    private var _node: EmbeddedNodeService?
    private var _linux: BlinkLinuxService?
    private var _claude: ClaudeCodeService?
    private var _wasm: TetherWasmService?

    private let dispatchManifest = GuestDispatchManifest.loadDefault()

    public init() {
        SystemOpen.guestLocalhostFetcher = { [weak self] url in
            guard let self else { return .failure("app not ready") }
            return await self.fetchGuestLocalhost(url)
        }
        registerCopyLogSections()
    }

    /// Runtime facts for the Copy log clipboard (Claude, Linux, Node, open path).
    public func registerCopyLogSections() {
        CopyLogDiagnostics.shared.registerSection("App / device") {
            CopyLogDiagnostics.appAndDeviceSnapshot()
        }
        CopyLogDiagnostics.shared.registerSection("Runtime (Claude / Linux / open)") { [weak self] in
            self?.copyLogRuntimeSnapshot() ?? "(integration unavailable)"
        }
    }

    public func copyLogRuntimeSnapshot() -> String {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "?"
        let home = docs
        let lane = ClaudeRuntimeProbe.detect(home: home)
        let launcher = ClaudeRuntimeProbe.launcherPath(home: home)
        let shim = ClaudeRuntimeProbe.shimPath(home: home)
        let js = ClaudeRuntimeProbe.extractedJSPath(home: home)
        var shimHasWhichFix = false
        if let shimText = try? String(contentsOfFile: shim, encoding: .utf8) {
            shimHasWhichFix = shimText.contains("openers.has(cmd)")
        }
        var lines: [String] = [
            "engine: Alpine Linux (Blink) primary",
            "TERMX_HOST_SHELL: \(ProcessInfo.processInfo.environment["TERMX_HOST_SHELL"] ?? "0")",
            "linux.state: \(linux.state)",
            "linux.rootfs: \(linux.rootfs.path)",
            "linux.blink.ready: \(linux.state == .ready ? "yes" : "no")",
            "claude.state: \(claude.state)",
            "claude.lane: \(lane.map { String(describing: $0) } ?? "none")",
            "claude.launcher: \(fm.fileExists(atPath: launcher) ? "yes" : "no") \(launcher)",
            "claude.extractedJS: \(fm.fileExists(atPath: js) ? "yes" : "no")",
            "claude.bun-shim: \(fm.fileExists(atPath: shim) ? "yes" : "no")",
            "claude.openStub: \(fm.fileExists(atPath: (ClaudeRuntimeProbe.installRoot(home: home) as NSString).appendingPathComponent("termx-open-stub.js")) ? "yes" : "no")",
            "claude.shim.whichOpenFix: \(shimHasWhichFix ? "yes" : "NO — rebuild app")",
            "claude.nodeModules: \(ClaudeRuntimeProbe.nodeModulesReady(home: home) ? "yes" : "no")",
            "claude.browserEnv: DISPLAY=:0 BROWSER=open (linux-extract OAuth)",
            "guest.HOSTNAME: tether (expected)",
            "open.path: in-app SFSafariViewController (not Mac Safari)",
            "open.guestLocalhost: curl inside Alpine (not Simulator Safari)",
            "open.localhost.note: Mac Safari 127.0.0.1 ≠ Alpine guest 127.0.0.1 — use xdg-open in Tether only",
        ]
        if !SystemOpen.openerCommands.isEmpty {
            lines.append("open.interceptCommands: \(SystemOpen.openerCommands.sorted().joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

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
        let service = ClaudeCodeService(
            node: NodeAdapter(service: node),
            linux: LinuxAdapter(service: linux)
        )
        _claude = service
        return service
    }

    public var wasm: TetherWasmService {
        if let existing = _wasm { return existing }
        let service = TetherWasmService()
        _wasm = service
        return service
    }

    /// Primary engine: Linux login shell (Docker-like).
    public func makePrimaryEngine() -> any TerminalEngine {
        if ProcessInfo.processInfo.environment["TERMX_HOST_SHELL"] == "1" {
            return makeHostShellEngine()
        }
        return makeLinuxShellEngine()
    }

    public func makeLinuxShellEngine() -> LinuxShellEngine {
        let engine = LinuxShellEngine(linux: linux)
        engine.hostExec = { [weak self] name, argv, env, stdinFD, stdoutFD, stderrFD in
            guard let self else { return 127 }
            return self.runHostBacked(
                name: name, argv: argv, env: env,
                fds: (stdinFD, stdoutFD, stderrFD)
            )
        }
        return engine
    }

    /// Legacy in-process host shell (python/node as registered commands).
    public func makeHostShellEngine() -> TermXShellEngine {
        let engine = TermXShellEngine()
        engine.sessionConfigurator = { [weak self] session in
            self?.registerRuntimeCommands(into: session)
        }
        return engine
    }

    /// Back-compat alias for callers that still expect TermXShellEngine.
    public func makeShellEngine() -> TermXShellEngine {
        makeHostShellEngine()
    }

    public func interruptActiveRuntimes(forceNodeSignal: Bool = true) {
        _node?.interrupt(forceNodeSignal: forceNodeSignal)
        _python?.interrupt()
        _claude?.interrupt(forceNodeSignal: forceNodeSignal)
        _wasm?.interrupt()
        // Do not call _linux?.interrupt() here — the PTY ^C byte handles the guest
        // shell; termx_blink_interrupt() during an idle prompt tears down the session.
    }

    /// curl/wget inside Alpine for guest-localhost in-app preview.
    private func fetchGuestLocalhost(_ url: URL) async -> SystemOpen.GuestFetchOutcome {
        if linux.isGuestMachineActive {
            SystemOpen.log("guest fetch skipped (Blink session active — verify with curl in terminal)")
            return .failure("""
            In-app fetch is unavailable while the terminal session is running (Blink is single-session).

            Verify the server in the terminal:
              curl -sS -w '\\nHTTP %{http_code}\\n' http://127.0.0.1:\(url.port ?? 9999)/

            Mac Safari at the same URL is your MacBook — not the Alpine guest.
            """)
        }
        let escaped = url.absoluteString.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = """
        if command -v curl >/dev/null; then
          curl -sS -w '\\n__TERMX_HTTP__%{http_code}' --max-time 3 '\(escaped)'
        else
          wget -qO- -T 3 -t 1 '\(escaped)'; echo '\\n__TERMX_HTTP__000'
        fi
        """
        var lastErr = ""
        for attempt in 1...3 {
            SystemOpen.log("guest fetch attempt \(attempt) \(url.absoluteString)")
            let outPipe = Pipe()
            let errPipe = Pipe()
            let code = await linux.run(
                argv: ["/bin/sh", "-c", cmd],
                cwd: "/work",
                stdinFD: -1,
                stdoutFD: outPipe.fileHandleForWriting.fileDescriptor,
                stderrFD: errPipe.fileHandleForWriting.fileDescriptor,
                interactive: false
            )
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            let raw = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let parsed = Self.parseGuestHTTPResponse(raw), parsed.status > 0 {
                SystemOpen.log("guest fetch HTTP \(parsed.status) (\(parsed.body.count) bytes)")
                if parsed.status == 200 {
                    return .success(body: parsed.body, httpStatus: parsed.status)
                }
                let snippet = String(data: parsed.body.prefix(200), encoding: .utf8) ?? ""
                lastErr = "HTTP \(parsed.status) from guest server\(snippet.isEmpty ? "" : ": \(snippet)")"
            } else if code == 0, !raw.isEmpty {
                SystemOpen.log("guest fetch ok (\(raw.count) bytes, no status marker)")
                return .success(body: raw, httpStatus: 200)
            }
            lastErr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if lastErr.isEmpty {
                lastErr = "exit \(code), empty body"
            }
            SystemOpen.log("guest fetch fail: \(lastErr)")
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        if lastErr.contains("Connection refused") || lastErr.contains("couldn't connect") {
            return .failure("""
            Nothing listening on guest \(url.host ?? "localhost") port \(url.port ?? 80).
            Mac Safari http://127.0.0.1:\(url.port ?? 80)/ is a DIFFERENT machine — it will not show the Alpine server.
            In Tether run:
              echo test > index.html
              python3 -m http.server \(url.port ?? 9999) &
              sleep 1
              xdg-open http://127.0.0.1:\(url.port ?? 9999)/
            """)
        }
        if lastErr.contains("HTTP 404") {
            return .failure("""
            \(lastErr)
            The port answered but not with your page — often a stale server or wrong folder.
            MacBook Safari on the same URL is NOT the phone guest; ignore Mac localhost.
            Try: pkill -f http.server; echo '<h1>guest ok</h1>' > index.html; python3 -m http.server \(url.port ?? 9999) &
            """)
        }
        return .failure(lastErr.isEmpty ? "guest fetch failed after retries" : lastErr)
    }

    private static func parseGuestHTTPResponse(_ raw: Data) -> (body: Data, status: Int)? {
        let marker = Data("__TERMX_HTTP__".utf8)
        guard raw.count > marker.count,
              let range = raw.range(of: marker, options: .backwards) else { return nil }
        let body = raw.subdata(in: 0..<range.lowerBound)
        let statusStr = String(data: raw.subdata(in: range.upperBound..<raw.count), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let status = Int(statusStr), status > 0 else { return nil }
        return (body, status)
    }

    private func runHostBacked(
        name: String, argv: [String], env: [String: String],
        fds: (Int32, Int32, Int32)
    ) -> Int32 {
        let hostCwd = env["TETHER_HOST_CWD"] ?? env["TERMX_HOST_CWD"] ?? env["PWD"] ?? "/"
        let sem = DispatchSemaphore(value: 0)
        let box = ExitCodeBox()
        Task.detached {
            if self.dispatchManifest.isBrowserOpener(name) {
                let args = Array(argv.dropFirst())
                if let target = SystemOpen.resolve(command: name, arguments: args) {
                    switch SystemOpen.open(target, origin: .guestLinux) {
                    case .opened:
                        box.value = 0
                    case .failed(let why):
                        let msg = "\(name): \(why)\n"
                        let fd = fds.2 >= 0 ? fds.2 : fds.1
                        if fd >= 0 {
                            msg.withCString { _ = write(fd, $0, strlen($0)) }
                        }
                        box.value = 1
                    case .unsupported:
                        box.value = 1
                    }
                } else {
                    let msg = "\(name): nothing to open\n"
                    let fd = fds.2 >= 0 ? fds.2 : fds.1
                    if fd >= 0 {
                        msg.withCString { _ = write(fd, $0, strlen($0)) }
                    }
                    box.value = 1
                }
            } else if self.dispatchManifest.hostHandler(for: name) == "wasm3" {
                box.value = await self.wasm.run(
                    argv: argv,
                    hostCwd: hostCwd,
                    environment: env,
                    stdinFD: fds.0,
                    stdoutFD: fds.1,
                    stderrFD: fds.2
                )
            } else if self.dispatchManifest.hostHandler(for: name) == "node-mobile" {
                switch name {
                case "claude":
                    if self.claude.state == .notInstalled {
                        do {
                            _ = try await self.claude.install(
                                cwd: hostCwd, env: env, fds: fds
                            )
                        } catch {
                            let msg = "claude: \(error)\n"
                            let fd = fds.2 >= 0 ? fds.2 : fds.1
                            if fd >= 0 {
                                msg.withCString { _ = write(fd, $0, strlen($0)) }
                            }
                            box.value = 1
                            sem.signal()
                            return
                        }
                    }
                    box.value = await self.claude.execute(
                        argv: argv, cwd: hostCwd, env: env, fds: fds
                    )
                case "node", "npm", "npx":
                    let interactive = (fds.1 >= 0 && isatty(fds.1) != 0)
                        || (fds.2 >= 0 && isatty(fds.2) != 0)
                    box.value = await self.node.run(
                        argv: argv, cwd: hostCwd, env: env,
                        stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
                        interactive: interactive
                    )
                default:
                    box.value = 127
                }
            } else {
                box.value = 127
            }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            if ProcessContext.current?.shouldTerminate == true {
                interruptActiveRuntimes()
                return 130
            }
        }
        return box.value
    }

    private func registerRuntimeCommands(into session: ShellSession) {
        let state = session.state

        func currentFDs() -> (Int32, Int32, Int32) {
            if let proc = ProcessContext.current {
                return (proc.stdinFD, proc.stdoutFD, proc.stderrFD)
            }
            return (state.stdinFD, state.stdoutFD, state.stderrFD)
        }
        func isInteractive(out: Int32, err: Int32) -> Bool {
            if ProcessContext.current?.interactive == true { return true }
            if out >= 0, isatty(out) != 0 { return true }
            if err >= 0, isatty(err) != 0 { return true }
            return false
        }
        func runBlocking(_ operation: @escaping @Sendable () async -> Int32) -> Int32 {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ExitCodeBox()
            Task.detached {
                box.value = await operation()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                if ProcessContext.current?.shouldTerminate == true {
                    interruptActiveRuntimes()
                    return 130
                }
            }
            return box.value
        }
        let writeErr: @Sendable (Int32, String) -> Void = { fd, text in
            guard fd >= 0 else { return }
            text.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        }

        for name in ["python3", "python"] {
            _ = session.registry.register(name: name) { [weak self] argv in
                guard let self else { return 127 }
                let (i, o, e) = currentFDs()
                var normalized = argv
                normalized[0] = "python3"
                let forwarded = normalized
                let interactive = isInteractive(out: o, err: e)
                return runBlocking { await self.python.run(argv: forwarded, cwd: state.cwd, environment: state.environ, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: interactive) }
            }
        }
        for name in ["pip", "pip3"] {
            _ = session.registry.register(name: name) { [weak self] argv in
                guard let self else { return 127 }
                let (i, o, e) = currentFDs()
                let forwarded = ["python3", "-m", "pip"] + Array(argv.dropFirst())
                let interactive = isInteractive(out: o, err: e)
                return runBlocking { await self.python.run(argv: forwarded, cwd: state.cwd, environment: state.environ, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: interactive) }
            }
        }
        for name in ["node", "npm", "npx"] {
            _ = session.registry.register(name: name) { [weak self] argv in
                guard let self else { return 127 }
                let (i, o, e) = currentFDs()
                let interactive = isInteractive(out: o, err: e)
                return runBlocking { await self.node.run(argv: argv, cwd: state.cwd, env: state.environ, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: interactive) }
            }
        }
        _ = session.registry.register(name: "claude") { [weak self] argv in
            guard let self else { return 127 }
            let (i, o, e) = currentFDs()
            return runBlocking {
                if argv.count == 1 {
                    do {
                        return try await self.claude.run(
                            cwd: state.cwd, env: state.environ, fds: (i, o, e)
                        )
                    } catch {
                        writeErr(e, "claude: \(error)\n")
                        return 1
                    }
                }
                if argv[1] == "login" {
                    return await self.claude.login(cwd: state.cwd, env: state.environ, fds: (i, o, e))
                }
                if self.claude.state == .notInstalled {
                    do {
                        _ = try await self.claude.install(
                            cwd: state.cwd, env: state.environ, fds: (i, o, e)
                        )
                    } catch {
                        writeErr(e, "claude: \(error)\n")
                        return 1
                    }
                }
                return await self.claude.execute(
                    argv: argv, cwd: state.cwd, env: state.environ, fds: (i, o, e)
                )
            }
        }
        _ = session.registry.register(name: "linux") { [weak self] argv in
            guard let self else { return 127 }
            let (i, o, e) = currentFDs()
            let guestArgv = argv.count > 1 ? Array(argv.dropFirst()) : ["/bin/sh"]
            return self.linux.runSync(argv: guestArgv, cwd: state.cwd, stdinFD: i, stdoutFD: o, stderrFD: e, interactive: true)
        }
        _ = session.registry.register(name: "wasm") { [weak self] argv in
            guard let self else { return 127 }
            let (i, o, e) = currentFDs()
            return runBlocking {
                await self.wasm.run(
                    argv: argv,
                    hostCwd: state.cwd,
                    environment: state.environ,
                    stdinFD: i,
                    stdoutFD: o,
                    stderrFD: e
                )
            }
        }

        for name in SystemOpen.openerCommands.sorted() {
            _ = session.registry.register(name: name) { argv in
                let (_, _, e) = currentFDs()
                let args = Array(argv.dropFirst())
                guard let target = SystemOpen.resolve(command: name, arguments: args) else {
                    writeErr(e, "\(name): nothing to open\n")
                    return 1
                }
                switch SystemOpen.open(target, origin: .guestLinux) {
                case .opened:
                    return 0
                case .failed(let why):
                    writeErr(e, "\(name): \(why)\n")
                    return 1
                case .unsupported:
                    writeErr(e, "\(name): unsupported\n")
                    return 1
                }
            }
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
    func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 {
        await service.run(argv: argv, cwd: cwd, env: env, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: interactive)
    }
    func interrupt(forceNodeSignal: Bool) { service.interrupt(forceNodeSignal: forceNodeSignal) }
}

private final class LinuxAdapter: ClaudeLinuxRunner {
    let service: BlinkLinuxService
    init(service: BlinkLinuxService) { self.service = service }

    var rootfsPath: String { service.rootfs.path }

    func ensureBootstrap(progress: @escaping (String) -> Void) async throws {
        if service.state == .ready { return }
        progress("claude: bootstrapping Alpine Linux guest (one-time)…\n")
        try await service.bootstrap()
        progress("claude: Alpine ready.\n")
    }

    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32 {
        await service.run(
            argv: argv, cwd: cwd,
            stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
            interactive: interactive
        )
    }

    func interrupt() { service.interrupt() }
}
