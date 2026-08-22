import Foundation

public enum RuntimeKind: String, Sendable { case native, python, node, claude, linux }

public protocol RuntimeCommandService: AnyObject {
    func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32
    func interrupt()
}

public final class RuntimeCoordinator: @unchecked Sendable {
    private var services: [RuntimeKind: RuntimeCommandService] = [:]
    private let lock = NSLock()
    public init() {}
    public func register(_ kind: RuntimeKind, service: RuntimeCommandService) { lock.lock(); services[kind] = service; lock.unlock() }
    public func service(for kind: RuntimeKind) -> RuntimeCommandService? { lock.lock(); defer { lock.unlock() }; return services[kind] }
    public func run(kind: RuntimeKind, argv: [String], cwd: String, env: [String: String], interactive: Bool = true) async -> Int32 {
        guard let service = service(for: kind) else { return 127 }
        return await service.run(argv: argv, cwd: cwd, env: env, stdinFD: 0, stdoutFD: 1, stderrFD: 2, interactive: interactive)
    }
    public func interrupt(kind: RuntimeKind) { service(for: kind)?.interrupt() }
}
