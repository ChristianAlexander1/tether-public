import Foundation

public protocol ClaudeNodeRunner: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt(forceNodeSignal: Bool)
    /// Terminal geometry changed; forward it to a running job.
    func resize(cols: Int, rows: Int)
}

/// Linux guest (Blink) — used for Alpine tools (`apk`, git, …), not for Claude.
/// Kept so the app can still wire a guest when present.
public protocol ClaudeLinuxRunner: AnyObject {
    var rootfsPath: String { get }
    func ensureBootstrap(progress: @escaping (String) -> Void) async throws
    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt()
}

public enum ClaudeState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case authenticated
    case failed(String)
}

public enum ClaudeError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case authenticationRequired
    case installationFailed(Int32)
    case bootstrapFailed(String)

    public var description: String {
        switch self {
        case .notInstalled: return "not installed"
        case .authenticationRequired: return "authentication required"
        case .installationFailed(let code): return "installation failed (exit \(code))"
        case .bootstrapFailed(let why): return "install failed: \(why)"
        }
    }
}

public final class ClaudeCodeService {
    public typealias RuntimeInstaller = (
        _ home: String,
        _ progress: @escaping (String) -> Void
    ) throws -> Void

    private let node: ClaudeNodeRunner
    private let linux: ClaudeLinuxRunner?
    private let defaults: UserDefaults
    private let runtimeInstaller: RuntimeInstaller
    private let authKey = "termx.claude.authenticated"
    private let installedKey = "termx.claude.installed"
    private let laneKey = "termx.claude.lane"

    public init(
        node: ClaudeNodeRunner,
        linux: ClaudeLinuxRunner? = nil,
        defaults: UserDefaults = .standard,
        runtimeInstaller: @escaping RuntimeInstaller = { home, progress in
            try ClaudeNodeInstaller.installIntoHome(home: home, progress: progress)
        }
    ) {
        self.node = node
        self.linux = linux
        self.defaults = defaults
        self.runtimeInstaller = runtimeInstaller
    }

    public var state: ClaudeState {
        if defaults.bool(forKey: authKey) { return .authenticated }
        if defaults.bool(forKey: installedKey) { return .installed }
        return .notInstalled
    }

    /// Files are authoritative for a concrete runtime home. Preferences alone
    /// cannot prove installation because Files/Storage may remove program data.
    public func state(home: String) -> ClaudeState {
        guard ClaudeRuntimeProbe.detect(home: home) != nil else { return .notInstalled }
        if defaults.bool(forKey: authKey) { return .authenticated }
        return .installed
    }

    /// The platform opener's command name, supplied by the host from
    /// `GuestDispatchManifest`. No opener name is written in this package.
    public nonisolated(unsafe) static var platformOpenerName: String?

    public static func launchEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        // Only meaningful on the legacy IPC lane. On TJIP/2 the handshake
        // reports which fds are really PTY-bound, and the flag is removed
        // from the environment before the engine starts.
        env["TETHER_INTERACTIVE"] = "1"
        env["TERMX_INTERACTIVE"] = "1"
        env["DISABLE_AUTOUPDATER"] = env["DISABLE_AUTOUPDATER"] ?? "1"
        env["DISABLE_UPDATES"] = env["DISABLE_UPDATES"] ?? "1"
        // Do not force CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC — that changes
        // Claude's own feature gates (including fullscreen / alternate screen)
        // versus a normal Mac/Linux terminal. Callers may still set it explicitly.
        // Extracted Claude JS hardcodes platform "linux" (Bun linux tarball). Its open
        // helper skips the browser when DISPLAY/WAYLAND are unset (no_display).
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["WAYLAND_DISPLAY"] = env["WAYLAND_DISPLAY"] ?? "tether"
        // The opener name comes from the dispatch manifest, the one file that
        // owns program-name policy. Both variables are what desktop CLIs read.
        if let opener = platformOpenerName ?? env["BROWSER"], !opener.isEmpty {
            env["BROWSER"] = env["BROWSER"] ?? opener
            env["TETHER_OPENER"] = opener
        }
        if let preload = ProcessInfo.processInfo.environment["TETHER_SHIM_PRELOAD"]
            ?? ProcessInfo.processInfo.environment["TERMX_SHIM_PRELOAD"] {
            env["NODE_OPTIONS"] = "--require \(preload)"
        }
        return env
    }

    // MARK: - Install / run

    /// Install once: download current Bun package → extract JS → Node launcher.
    /// Never re-downloads when already present. Always ensures `ws` / `js-yaml`.
    public func install(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async throws -> Int32 {
        let home = env["HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        if let lane = ClaudeRuntimeProbe.detect(home: home) {
            remember(lane: lane)
            return await ensureClaudeNodeDeps(home: home, cwd: cwd, env: env, fds: fds)
        }

        let emit: (String) -> Void = { text in
            guard fds.1 >= 0 else { return }
            text.withCString { ptr in _ = Darwin.write(fds.1, ptr, strlen(ptr)) }
        }

        emit("claude: preparing its embedded Node compatibility runtime (the official Bun executable cannot run inside Blink).\n")
        do {
            try runtimeInstaller(home) { emit($0) }
            remember(lane: .embeddedNode)
            return await ensureClaudeNodeDeps(home: home, cwd: cwd, env: env, fds: fds)
        } catch {
            emit("claude: runtime install failed: \(error)\n")
            throw ClaudeError.bootstrapFailed(String(describing: error))
        }
    }

    public func login(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async -> Int32 {
        do {
            return try await run(
                argv: ["claude", "auth", "login"], cwd: cwd, env: env, fds: fds
            )
        } catch {
            emit("claude: \(error)\n", to: fds.2 >= 0 ? fds.2 : fds.1)
            return 1
        }
    }

    public func run(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async throws -> Int32 {
        try await run(argv: ["claude"], cwd: cwd, env: env, fds: fds)
    }

    /// Validate the on-disk installation for every command. This is the single
    /// launch path used by both the Linux guest proxy and the host debug shell,
    /// so manual folder deletion repairs itself instead of using stale flags.
    public func run(
        argv: [String], cwd: String, env: [String: String],
        fds: (Int32, Int32, Int32)
    ) async throws -> Int32 {
        let home = env["HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        if let installedLane = ClaudeRuntimeProbe.detect(home: home) {
            remember(lane: installedLane)
        } else {
            defaults.removeObject(forKey: installedKey)
            defaults.removeObject(forKey: laneKey)
            let installCode = try await install(cwd: cwd, env: env, fds: fds)
            guard installCode == 0 else { throw ClaudeError.installationFailed(installCode) }
            guard ClaudeRuntimeProbe.detect(home: home) != nil else {
                throw ClaudeError.bootstrapFailed("runtime files missing after installation")
            }
        }
        let code = await execute(
            argv: argv.isEmpty ? ["claude"] : argv,
            cwd: cwd, env: env, fds: fds
        )
        if code == 0, Self.isAuthenticationLogin(argv) {
            defaults.set(true, forKey: authKey)
        }
        return code
    }

    private static func isAuthenticationLogin(_ argv: [String]) -> Bool {
        Array(argv.dropFirst().prefix(2)) == ["auth", "login"]
    }

    /// Run any `claude …` argv on the detected lane (no reinstall).
    public func execute(argv: [String], cwd: String, env: [String: String],
                        fds: (Int32, Int32, Int32)) async -> Int32 {
        let home = env["HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        let lane = ClaudeRuntimeProbe.detect(home: home)
        var launchEnv = Self.launchEnvironment(base: env)

        switch lane {
        case .embeddedNode:
            do {
                try ClaudeNodeInstaller.ensureBundleLocation(home: home)
            } catch {
                emit(
                    "claude: installed module graph could not be relocated: \(error)\n",
                    to: fds.2 >= 0 ? fds.2 : fds.1
                )
                return 126
            }
            if !ClaudeRuntimeProbe.nodeModulesReady(home: home) {
                _ = await ensureClaudeNodeDeps(home: home, cwd: cwd, env: env, fds: fds)
            }
            // Always refresh launcher/shim from the app bundle (Segmenter polyfill, etc.).
            try? ClaudeNodeInstaller.ensureLauncherFiles(home: home)
            let launcher = ClaudeRuntimeProbe.launcherPath(home: home)
            let applicationEntry = ClaudeRuntimeProbe.applicationEntryPath(home: home)
                ?? ClaudeRuntimeProbe.extractedJSPath(home: home)
            launchEnv["CLAUDE_CODE_JS"] = applicationEntry
            if ClaudeRuntimeProbe.usesSplitBundle(home: home) {
                launchEnv["CLAUDE_CODE_ESM"] = "1"
                launchEnv["CLAUDE_BUNFS_ROOT"] = (
                    ClaudeRuntimeProbe.splitBundleRoot(home: home) as NSString
                ).appendingPathComponent("root")
            } else {
                launchEnv.removeValue(forKey: "CLAUDE_CODE_ESM")
                launchEnv.removeValue(forKey: "CLAUDE_BUNFS_ROOT")
            }
            let forwarded = Array(argv.dropFirst())
            return await node.run(
                argv: ["node", launcher] + forwarded,
                cwd: cwd,
                env: launchEnv,
                stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
                interactive: true
            )
        case .legacyJS:
            return await node.run(
                argv: argv.isEmpty ? ["claude"] : argv,
                cwd: cwd,
                env: launchEnv,
                stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
                interactive: true
            )
        case .none:
            emit(
                "claude: installation is incomplete; run claude again to repair it.\n",
                to: fds.2 >= 0 ? fds.2 : fds.1
            )
            return 127
        }
    }

    /// Install Node deps that Bun bundles but Node does not (`ws`, `js-yaml` — same as QNX port).
    private func ensureClaudeNodeDeps(
        home: String, cwd: String, env: [String: String], fds: (Int32, Int32, Int32)
    ) async -> Int32 {
        if ClaudeRuntimeProbe.nodeModulesReady(home: home) { return 0 }
        let emit: (String) -> Void = { text in
            guard fds.1 >= 0 else { return }
            text.withCString { ptr in _ = Darwin.write(fds.1, ptr, strlen(ptr)) }
        }
        do {
            try ClaudeNodeInstaller.ensurePackageManifest(home: home)
        } catch {
            emit("claude: could not write package.json: \(error)\n")
            return 1
        }
        emit("claude: installing Node deps (ws, js-yaml)…\n")
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        var installEnv = env
        installEnv["npm_config_progress"] = "false"
        let code = await node.run(
            argv: ["npm", "install", "--omit=dev", "--no-fund", "--no-audit"],
            cwd: root,
            env: installEnv,
            stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
            interactive: true
        )
        if code != 0 {
            emit("claude: npm install of ws/js-yaml failed (exit \(code))\n")
        }
        return code
    }

    public func interrupt(forceNodeSignal: Bool = false) {
        node.interrupt(forceNodeSignal: forceNodeSignal)
    }

    /// Claude runs its TUI on the shared Node engine, so a window change has to
    /// travel the same path as any other host job.
    public func resize(cols: Int, rows: Int) {
        node.resize(cols: cols, rows: rows)
    }

    // MARK: - Private

    private func remember(lane: ClaudeRuntimeLane) {
        defaults.set(true, forKey: installedKey)
        defaults.set(lane == .legacyJS ? "legacy" : "node", forKey: laneKey)
    }

    private func emit(_ message: String, to fd: Int32) {
        guard fd >= 0 else { return }
        message.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
    }
}

@MainActor
public final class ClaudeLauncher: ObservableObject {
    @Published public private(set) var state: ClaudeState = .notInstalled
    private let service: ClaudeCodeService

    public init(service: ClaudeCodeService) {
        self.service = service
        self.state = service.state
    }

    public func ensureInstalled(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async {
        guard state == .notInstalled || state == .failed("") else { return }
        state = .installing
        do {
            _ = try await service.install(cwd: cwd, env: env, fds: fds)
            state = .installed
        } catch {
            state = .failed(String(describing: error))
        }
    }

    public func login(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async -> Int32 {
        let code = await service.login(cwd: cwd, env: env, fds: fds)
        state = code == 0 ? .authenticated : .failed("login exit \(code)")
        return code
    }

    public func run(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async throws -> Int32 {
        if state == .notInstalled { await ensureInstalled(cwd: cwd, env: env, fds: fds) }
        return try await service.run(cwd: cwd, env: env, fds: fds)
    }

    public func interrupt(forceNodeSignal: Bool = false) { service.interrupt(forceNodeSignal: forceNodeSignal) }

    public func resize(cols: Int, rows: Int) { service.resize(cols: cols, rows: rows) }
}
