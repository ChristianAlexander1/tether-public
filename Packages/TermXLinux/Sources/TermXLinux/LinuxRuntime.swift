import Foundation
import TermXBlinkBridge

protocol LinuxRuntime: AnyObject {
    func prepare(rootfs: URL, mapper: LinuxPathMapper) throws
    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool, shouldInterrupt: @escaping () -> Bool) async -> Int32
    func interrupt()
}

enum LinuxRuntimeFactory {
    static func make(rootfs: URL, mapper: LinuxPathMapper) -> LinuxRuntime {
        let environment = ProcessInfo.processInfo.environment
        if (environment["TETHER_BLINK_EMBED"] ?? environment["TERMX_BLINK_EMBED"]) == "1",
           BlinkEmbed.isAvailable {
            return EmbeddedBlinkRuntime(mapper: mapper)
        }
        #if os(macOS)
        if FileManager.default.isExecutableFile(atPath: BlinkPaths.hostBinary) {
            return HostBlinkRuntime(rootfs: rootfs, mapper: mapper)
        }
        #endif
        return EmbeddedBlinkRuntime(mapper: mapper)
    }
}

enum BlinkPaths {
    /// The repo's Frameworks directory, derived from this file's location so the
    /// checkout can live anywhere. (Hardcoded absolute paths here broke every
    /// macOS Linux-lane test when the repo moved from ~/Projects/terminal.)
    static var frameworksRoot: String {
        URL(fileURLWithPath: #filePath)   // …/Packages/TermXLinux/Sources/TermXLinux/LinuxRuntime.swift
            .deletingLastPathComponent()  // TermXLinux
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // TermXLinux (package)
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Frameworks").path
    }

    static var hostBinary: String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TETHER_BLINK_BINARY"] ?? environment["TERMX_BLINK_BINARY"] {
            return override
        }
        let candidates = [
            frameworksRoot + "/.build/blink/host/blink",
            frameworksRoot + "/.build/blink-src/o/rel/blink/blink",
            "/usr/local/bin/blink",
            "/opt/homebrew/bin/blink",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    static var xcframeworkRoot: String {
        ProcessInfo.processInfo.environment["TETHER_BLINK_XCFRAMEWORK"]
            ?? ProcessInfo.processInfo.environment["TERMX_BLINK_XCFRAMEWORK"]
            ?? frameworksRoot + "/Blink.xcframework"
    }
}

enum BlinkEmbed {
    static var isAvailable: Bool {
        termx_blink_is_available() != 0
    }
}

final class EmbeddedBlinkRuntime: LinuxRuntime {
    private let mapper: LinuxPathMapper
    private var rootfsPath: String = ""
    private var prepared = false

    init(mapper: LinuxPathMapper) {
        self.mapper = mapper
    }

    func prepare(rootfs: URL, mapper: LinuxPathMapper) throws {
        rootfsPath = rootfs.path
        let rc = termx_blink_init(rootfsPath)
        guard rc == 0 else { throw LinuxGuestError.bootstrapFailed("termx_blink_init: \(rc)") }

        try FileManager.default.createDirectory(at: mapper.workspacesHostRoot, withIntermediateDirectories: true)
        let mountWS = termx_blink_mount(mapper.workspacesHostRoot.path, mapper.guestWorkspacesPath)
        guard mountWS == 0 else {
            throw LinuxGuestError.mountFailed("/workspaces (\(mountWS))")
        }

        let mountHome = termx_blink_mount(mapper.homeHostRoot.path, mapper.guestHomePath)
        guard mountHome == 0 else {
            throw LinuxGuestError.mountFailed("/root (\(mountHome))")
        }
        prepared = true
    }

    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool, shouldInterrupt: @escaping () -> Bool) async -> Int32 {
        guard prepared, let prog = argv.first else { return 127 }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var env = LinuxEnvironment.guestEnviron(cwd: cwd, interactive: interactive)
                let envp = LinuxEnvironment.cEnvp(&env)
                let argp = LinuxEnvironment.cArgv(argv)

                let code = termx_blink_run(prog, argp, envp, stdinFD, stdoutFD, stderrFD)
                LinuxEnvironment.freeCStrings(argp)
                LinuxEnvironment.freeCStrings(envp)
                continuation.resume(returning: code >= 0 ? code : 127)
            }
        }
    }

    func interrupt() {
        termx_blink_interrupt()
    }
}

#if os(macOS)
final class HostBlinkRuntime: LinuxRuntime, @unchecked Sendable {
    private let rootfs: URL
    private let mapper: LinuxPathMapper
    private var process: Process?
    private let processLock = NSLock()

    init(rootfs: URL, mapper: LinuxPathMapper) {
        self.rootfs = rootfs
        self.mapper = mapper
    }

    func prepare(rootfs: URL, mapper: LinuxPathMapper) throws {
        guard FileManager.default.isExecutableFile(atPath: BlinkPaths.hostBinary) else {
            throw LinuxGuestError.emulatorBinaryMissing
        }
        _ = rootfs
        _ = mapper
    }

    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool, shouldInterrupt: @escaping () -> Bool) async -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: BlinkPaths.hostBinary) else { return 127 }
        guard let guestProg = argv.first else { return 127 }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: 127)
                    return
                }

                let blink = Process()
                blink.executableURL = URL(fileURLWithPath: BlinkPaths.hostBinary)
                blink.arguments = ["-jm", "-C", self.rootfs.path, guestProg] + Array(argv.dropFirst())
                blink.currentDirectoryURL = URL(fileURLWithPath: cwd)

                var env = ProcessInfo.processInfo.environment
                env["TERM"] = env["TERM"] ?? "xterm-256color"
                blink.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                blink.standardOutput = outPipe
                blink.standardError = errPipe

                self.processLock.lock()
                self.process = blink
                self.processLock.unlock()
                do {
                    try blink.run()

                    // Drain while Blink is running. Package installs and compilers can
                    // easily exceed a pipe's capacity; waiting until exit deadlocks the
                    // guest once stdout/stderr fills the kernel buffer.
                    let drainGroup = DispatchGroup()
                    drainGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { drainGroup.leave() }
                        Self.forward(outPipe.fileHandleForReading, to: stdoutFD)
                    }
                    drainGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { drainGroup.leave() }
                        Self.forward(errPipe.fileHandleForReading, to: stderrFD)
                    }

                    var cancellationStartedAt: Date?
                    var sentTerminate = false
                    var sentKill = false
                    while blink.isRunning {
                        if shouldInterrupt() {
                            if cancellationStartedAt == nil {
                                cancellationStartedAt = Date()
                                blink.interrupt()
                            } else if let started = cancellationStartedAt {
                                let elapsed = Date().timeIntervalSince(started)
                                if elapsed >= 2, !sentKill {
                                    sentKill = true
                                    _ = kill(blink.processIdentifier, SIGKILL)
                                } else if elapsed >= 1, !sentTerminate {
                                    sentTerminate = true
                                    blink.terminate()
                                }
                            }
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    blink.waitUntilExit()
                    drainGroup.wait()
                    continuation.resume(returning: Int32(blink.terminationStatus))
                } catch {
                    continuation.resume(returning: 127)
                }
                self.processLock.lock()
                self.process = nil
                self.processLock.unlock()
            }
        }
    }

    func interrupt() {
        processLock.lock()
        let runningProcess = process
        processLock.unlock()
        runningProcess?.interrupt()
    }

    private static func forward(_ source: FileHandle, to targetFD: Int32) {
        while true {
            let data = source.availableData
            if data.isEmpty { return }
            guard targetFD >= 0 else { continue }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = write(targetFD, base.advanced(by: written), raw.count - written)
                    if count > 0 {
                        written += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }
}
#endif

enum LinuxEnvironment {
    static func guestEnviron(cwd: String, interactive: Bool) -> [String: String] {
        // Prefer /work when that is the Docker-style project mount.
        let pwd = (cwd == "/work" || cwd.hasPrefix("/work/")) ? cwd
            : (cwd.hasPrefix("/") ? cwd : "/work")
        let env: [String: String] = [
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LOGNAME": "root",
            "SHELL": "/bin/sh",
            "TMPDIR": "/tmp",
            "TERM": interactive ? "xterm-256color" : "dumb",
            "LANG": "C.UTF-8",
            "PWD": pwd,
            // Generic desktop-integration contract used by any guest program.
            "DISPLAY": ":0",
            "WAYLAND_DISPLAY": "tether",
            "BROWSER": "open",
        ]
        return env
    }

    static func cArgv(_ argv: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        pointers.append(nil)
        return pointers
    }

    static func cEnvp(_ env: inout [String: String]) -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = env.map { key, value in
            strdup("\(key)=\(value)")
        }
        pointers.append(nil)
        return pointers
    }

    static func freeCStrings(_ list: [UnsafeMutablePointer<CChar>?]) {
        for ptr in list where ptr != nil {
            free(ptr)
        }
    }
}
