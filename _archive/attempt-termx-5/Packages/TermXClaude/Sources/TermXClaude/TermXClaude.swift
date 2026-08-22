import Foundation
import TermXCore

public protocol NodeService: RuntimeCommandService {
    func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32
    func interrupt()
}

public enum ClaudeState: Equatable { case notInstalled, installing, ready, failed(String) }

@MainActor
public final class ClaudeLauncher: ObservableObject {
    @Published public private(set) var state: ClaudeState = .notInstalled
    private let node: NodeService
    public init(node: NodeService) { self.node = node }
    public func ensureInstalled(cwd: String, env: [String: String]) async {
        guard state != .ready else { return }
        state = .installing
        let code = await node.run(argv: ["npm", "install", "--global", "@anthropic-ai/claude-code"], cwd: cwd, env: env, stdinFD: 0, stdoutFD: 1, stderrFD: 2, interactive: true)
        state = code == 0 ? .ready : .failed("Claude Code installation exited with \(code).")
    }
    public func run(cwd: String, env: [String: String]) async -> Int32 {
        if state != .ready { await ensureInstalled(cwd: cwd, env: env) }
        guard state == .ready else { return 1 }
        return await node.run(argv: ["claude"], cwd: cwd, env: env, stdinFD: 0, stdoutFD: 1, stderrFD: 2, interactive: true)
    }
    public func interrupt() { node.interrupt() }
}
