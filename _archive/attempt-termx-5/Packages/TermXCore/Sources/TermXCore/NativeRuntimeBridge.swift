import Foundation

public struct NativeRuntimeCallbacks: @unchecked Sendable {
    public let run: @Sendable (_ argv: [String], _ cwd: String, _ env: [String: String], _ stdinFD: Int32, _ stdoutFD: Int32, _ stderrFD: Int32, _ interactive: Bool) -> Int32
    public let interrupt: @Sendable () -> Void
    public init(run: @escaping @Sendable ([String], String, [String: String], Int32, Int32, Int32, Bool) -> Int32, interrupt: @escaping @Sendable () -> Void) { self.run = run; self.interrupt = interrupt }
}

public final class NativeRuntimeService: RuntimeCommandService {
    private let callbacks: NativeRuntimeCallbacks
    public init(callbacks: NativeRuntimeCallbacks) { self.callbacks = callbacks }
    public func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 { callbacks.run(argv, cwd, env, stdinFD, stdoutFD, stderrFD, interactive) }
    public func interrupt() { callbacks.interrupt() }
}
