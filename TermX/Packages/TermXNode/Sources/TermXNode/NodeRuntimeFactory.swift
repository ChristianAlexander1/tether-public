import Foundation
import TermXCore

final class NodeRunningJob {
    let argv: [String]
    let cwd: String
    let env: [String: String]
    let stdinFD: Int32
    let stdoutFD: Int32
    let stderrFD: Int32
    let interactive: Bool
    private(set) var cancelled = false

    init(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) {
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.interactive = interactive
    }

    func cancel() { cancelled = true }
}

protocol NodeRuntime: AnyObject {
    func run(job: NodeRunningJob, shouldInterrupt: @escaping () -> Bool) -> Int32
    func interrupt()
}

enum NodeRuntimeFactory {
    static func make(spawnExecutor: SpawnExecuting) -> NodeRuntime {
        #if os(macOS) && !targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["TERMX_FORCE_HOST_NODE"] != "0" {
            return HostNodeRuntime(spawnExecutor: spawnExecutor)
        }
        #endif
        #if os(macOS)
        return HostNodeRuntime(spawnExecutor: spawnExecutor)
        #else
        return NodeMobileRuntime(spawnExecutor: spawnExecutor)
        #endif
    }
}

enum NodeMobilePaths {
    static var xcframeworkRoot: String {
        ProcessInfo.processInfo.environment["TERMX_NODE_MOBILE_XCFRAMEWORK"]
            ?? defaultXCFrameworkRoot
    }

    private static var defaultXCFrameworkRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/NodeMobile.xcframework")
            .resolvingSymlinksInPath()
            .path
    }

    static var xcframeworkBinary: String {
        #if targetEnvironment(simulator)
        return "\(xcframeworkRoot)/ios-arm64_x86_64-simulator/NodeMobile.framework/NodeMobile"
        #else
        return "\(xcframeworkRoot)/ios-arm64/NodeMobile.framework/NodeMobile"
        #endif
    }
}
