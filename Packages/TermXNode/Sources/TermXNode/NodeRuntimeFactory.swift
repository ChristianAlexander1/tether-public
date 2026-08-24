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
    /// Cooperative cancel for interactive jobs (avoids pthread_kill on NodeMobile).
    func requestCancel()
}

enum NodeRuntimeFactory {
    static func make(spawnExecutor: SpawnExecuting) -> NodeRuntime {
        #if os(macOS) && !targetEnvironment(simulator)
        let forceHost = ProcessInfo.processInfo.environment["TETHER_FORCE_HOST_NODE"]
            ?? ProcessInfo.processInfo.environment["TERMX_FORCE_HOST_NODE"]
        if forceHost != "0" {
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
        ProcessInfo.processInfo.environment["TETHER_NODE_MOBILE_XCFRAMEWORK"]
            ?? ProcessInfo.processInfo.environment["TERMX_NODE_MOBILE_XCFRAMEWORK"]
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
        // digidem 24.x ships arm64-simulator only (no x86_64 slice).
        let arm64Sim = "\(xcframeworkRoot)/ios-arm64-simulator/NodeMobile.framework/NodeMobile"
        let universalSim = "\(xcframeworkRoot)/ios-arm64_x86_64-simulator/NodeMobile.framework/NodeMobile"
        return FileManager.default.fileExists(atPath: arm64Sim) ? arm64Sim : universalSim
        #else
        return "\(xcframeworkRoot)/ios-arm64/NodeMobile.framework/NodeMobile"
        #endif
    }
}
