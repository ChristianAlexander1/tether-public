import Foundation

public protocol TerminalEngine {
    func startShell(cwd: String, env: [String:String], ptySlave: Int32, onExit: @escaping (Int32)->Void) throws -> Int32
    func signal(pid: Int32, _ sig: Int32)
}

public final class CoreTerminalEngine: TerminalEngine {
    public init() {}
    public func startShell(cwd: String, env: [String:String], ptySlave: Int32, onExit: @escaping (Int32)->Void) throws -> Int32 {
        throw NSError(domain: "TermXCore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Build the native termx_core target and link it before starting a shell."])
    }
    public func signal(pid: Int32, _ sig: Int32) { _ = Darwin.kill(pid, sig) }
}
