import Foundation
import TermXCore
import TermXClaude

public final class EmbeddedNodeService: NodeService {
    private let bridge: NativeRuntimeService?
    public init(callbacks: NativeRuntimeCallbacks? = nil) { bridge = callbacks.map(NativeRuntimeService.init) }
    public func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 {
        guard let bridge else { return 127 }
        return await bridge.run(argv: argv, cwd: cwd, env: env, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: interactive)
    }
    public func interrupt() { bridge?.interrupt() }
}
