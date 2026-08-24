import Foundation

public protocol ClaudeNodeRunner: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt(forceNodeSignal: Bool)
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
    private let node: ClaudeNodeRunner
    private let linux: ClaudeLinuxRunner?
    private let defaults: UserDefaults
    private let authKey = "termx.claude.authenticated"
    private let installedKey = "termx.claude.installed"
    private let laneKey = "termx.claude.lane"

    /// Last-resort pure-JS npm pin when Bun extract cannot run.
    public static let legacyJSPackage = "@anthropic-ai/claude-code@2.1.110"

    public init(node: ClaudeNodeRunner, linux: ClaudeLinuxRunner? = nil,
                defaults: UserDefaults = .standard) {
        self.node = node
        self.linux = linux
        self.defaults = defaults
    }

    public var state: ClaudeState {
        if defaults.bool(forKey: authKey) { return .authenticated }
        if defaults.bool(forKey: installedKey) { return .installed }
        return .notInstalled
    }

    public static func launchEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env["TETHER_INTERACTIVE"] = "1"
        env["TERMX_INTERACTIVE"] = "1"
        env["DISABLE_AUTOUPDATER"] = env["DISABLE_AUTOUPDATER"] ?? "1"
        env["DISABLE_UPDATES"] = env["DISABLE_UPDATES"] ?? "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] =
            env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] ?? "1"
        // Extracted Claude JS hardcodes platform "linux" (Bun linux tarball). Its open
        // helper skips the browser when DISPLAY/WAYLAND are unset (no_display).
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["WAYLAND_DISPLAY"] = env["WAYLAND_DISPLAY"] ?? "tether"
        env["BROWSER"] = env["BROWSER"] ?? "open"
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

        emit("claude: using Node + extracted JS (world approach — Bun ELF cannot run under Blink).\n")
        do {
            try ClaudeNodeInstaller.installIntoHome(home: home) { emit($0) }
            remember(lane: .embeddedNode)
            return await ensureClaudeNodeDeps(home: home, cwd: cwd, env: env, fds: fds)
        } catch {
            emit("claude: Bun→Node install failed (\(error)); trying legacy JS pin…\n")
        }

        return try await installLegacyJS(cwd: cwd, env: env, fds: fds)
    }

    public func login(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async -> Int32 {
        let code = await execute(argv: ["claude", "login"], cwd: cwd, env: env, fds: fds)
        if code == 0 { defaults.set(true, forKey: authKey) }
        return code
    }

    public func run(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async throws -> Int32 {
        let home = env["HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        if ClaudeRuntimeProbe.detect(home: home) == nil && rememberedLane() == nil {
            _ = try await install(cwd: cwd, env: env, fds: fds)
        }
        guard state == .authenticated || state == .installed else {
            throw ClaudeError.authenticationRequired
        }
        return await execute(argv: ["claude"], cwd: cwd, env: env, fds: fds)
    }

    /// Run any `claude …` argv on the detected lane (no reinstall).
    public func execute(argv: [String], cwd: String, env: [String: String],
                        fds: (Int32, Int32, Int32)) async -> Int32 {
        let home = env["HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        let lane = ClaudeRuntimeProbe.detect(home: home) ?? rememberedLane()
        var launchEnv = Self.launchEnvironment(base: env)

        switch lane {
        case .embeddedNode:
            if !ClaudeRuntimeProbe.nodeModulesReady(home: home) {
                _ = await ensureClaudeNodeDeps(home: home, cwd: cwd, env: env, fds: fds)
            }
            // Always refresh launcher/shim from the app bundle (Segmenter polyfill, etc.).
            try? ClaudeNodeInstaller.ensureLauncherFiles(home: home)
            let launcher = ClaudeRuntimeProbe.launcherPath(home: home)
            launchEnv["CLAUDE_CODE_JS"] = ClaudeRuntimeProbe.extractedJSPath(home: home)
            let forwarded = Array(argv.dropFirst())
            return await node.run(
                argv: ["node", launcher] + forwarded,
                cwd: cwd,
                env: launchEnv,
                stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
                interactive: true
            )
        case .legacyJS, .none:
            return await node.run(
                argv: argv.isEmpty ? ["claude"] : argv,
                cwd: cwd,
                env: launchEnv,
                stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
                interactive: true
            )
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

    // MARK: - Private

    private func rememberedLane() -> ClaudeRuntimeLane? {
        switch defaults.string(forKey: laneKey) {
        case "node", "linux": return .embeddedNode // "linux" was old lane key; treat as node extract
        case "legacy": return .legacyJS
        default: return nil
        }
    }

    private func remember(lane: ClaudeRuntimeLane) {
        defaults.set(true, forKey: installedKey)
        defaults.set(lane == .legacyJS ? "legacy" : "node", forKey: laneKey)
    }

    private func installLegacyJS(cwd: String, env: [String: String],
                                 fds: (Int32, Int32, Int32)) async throws -> Int32 {
        let home = env["HOME"] ?? NSHomeDirectory() + "/Documents"
        if ClaudeRuntimeProbe.jsEntryPath(home: home) != nil {
            remember(lane: .legacyJS)
            return 0
        }
        var installEnv = env
        installEnv["npm_config_prefix"] = installEnv["npm_config_prefix"] ?? "\(home)/node"
        installEnv["npm_config_progress"] = "false"
        let code = await node.run(
            argv: ["npm", "install", "-g", Self.legacyJSPackage],
            cwd: cwd,
            env: installEnv,
            stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
            interactive: true
        )
        if code == 0 {
            remember(lane: .legacyJS)
        } else {
            throw ClaudeError.installationFailed(code)
        }
        return code
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
}
