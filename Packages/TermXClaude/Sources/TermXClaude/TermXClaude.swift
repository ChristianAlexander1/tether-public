import Foundation

public protocol ClaudeNodeRunner: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
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

public enum ClaudeError: Error, Equatable {
    case notInstalled
    case authenticationRequired
    case installationFailed(Int32)
}

public final class ClaudeCodeService {
    private let node: ClaudeNodeRunner
    private let defaults: UserDefaults
    private let authKey = "termx.claude.authenticated"
    private let installedKey = "termx.claude.installed"

    public init(node: ClaudeNodeRunner, defaults: UserDefaults = .standard) {
        self.node = node
        self.defaults = defaults
    }

    public var state: ClaudeState {
        if defaults.bool(forKey: authKey) { return .authenticated }
        if defaults.bool(forKey: installedKey) { return .installed }
        return .notInstalled
    }

    /// Global install of @anthropic-ai/claude-code under $HOME/node via npm.
    public func install(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async throws -> Int32 {
        var installEnv = env
        let home = env["HOME"] ?? NSHomeDirectory() + "/Documents"
        installEnv["npm_config_prefix"] = installEnv["npm_config_prefix"] ?? "\(home)/node"
        let code = await node.run(
            argv: ["npm", "install", "-g", "@anthropic-ai/claude-code"],
            cwd: cwd,
            env: installEnv,
            stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
            interactive: true
        )
        if code == 0 { defaults.set(true, forKey: installedKey) }
        else { throw ClaudeError.installationFailed(code) }
        return code
    }

    public func login(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async -> Int32 {
        let code = await node.run(
            argv: ["claude", "login"],
            cwd: cwd,
            env: env,
            stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
            interactive: true
        )
        if code == 0 { defaults.set(true, forKey: authKey) }
        return code
    }

    /// Launch Claude Code attached to PTY fds (interactive TUI).
    public func run(cwd: String, env: [String: String], fds: (Int32, Int32, Int32)) async throws -> Int32 {
        if state == .notInstalled {
            _ = try await install(cwd: cwd, env: env, fds: fds)
        }
        guard state == .authenticated || state == .installed else {
            throw ClaudeError.authenticationRequired
        }
        var runEnv = env
        runEnv["TERMX_INTERACTIVE"] = "1"
        if let preload = ProcessInfo.processInfo.environment["TERMX_SHIM_PRELOAD"] {
            runEnv["NODE_OPTIONS"] = "--require \(preload)"
        }
        return await node.run(
            argv: ["claude"],
            cwd: cwd,
            env: runEnv,
            stdinFD: fds.0, stdoutFD: fds.1, stderrFD: fds.2,
            interactive: true
        )
    }

    public func interrupt() { node.interrupt() }
}

/// Observable launcher for SwiftUI first-run UX.
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
        let code = try await service.run(cwd: cwd, env: env, fds: fds)
        return code
    }

    public func interrupt() { service.interrupt() }
}
