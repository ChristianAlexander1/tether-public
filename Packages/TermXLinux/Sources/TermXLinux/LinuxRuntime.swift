import Foundation
import TermXBlinkBridge

protocol LinuxRuntime: AnyObject {
    /// True when `mount` is a real VfsMount into the embedded Blink guest.
    var supportsBindMounts: Bool { get }
    func prepare(rootfs: URL, mapper: LinuxPathMapper) throws
    func mount(hostPath: String, guestPath: String) throws
    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool, shouldInterrupt: @escaping () -> Bool) async -> Int32
    /// Run a guest ELF without replacing the login-shell machine.
    func runNested(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) -> Int32
    func interrupt()
    func terminate()
}

enum LinuxRuntimeFactory {
    static func make(rootfs: URL, mapper: LinuxPathMapper) -> LinuxRuntime {
        // The real C bridge is preferred whenever it is actually linked.
        // TETHER_BLINK_EMBED=1 used to be required as well, which hid the
        // bind-mount path: macOS compiled TERMX_BLINK_STUB whenever the iOS
        // xcframework existed, so isAvailable stayed false and this factory
        // always fell through to the host CLI (no VfsMount).
        if BlinkEmbed.isAvailable {
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
            // build-blink.sh installs here; the legacy .build/blink/host path
            // is kept below for checkouts built by an older script.
            frameworksRoot + "/.build/host/blink",
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

    /// Host static library installed by `Frameworks/build-blink.sh`.
    static var hostArchive: String {
        frameworksRoot + "/.build/host/blink.a"
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

    var supportsBindMounts: Bool { BlinkEmbed.isAvailable }

    init(mapper: LinuxPathMapper) {
        self.mapper = mapper
    }

    func prepare(rootfs: URL, mapper: LinuxPathMapper) throws {
        switch LinuxRootfsLayout.detect(at: rootfs) {
        case .extracted:
            break
        case .fakefsStore:
            throw LinuxGuestError.bootstrapFailed(
                "\(rootfs.path) is a fakefs store; Blink hostfs cannot represent its device nodes. Production apk uses the extracted rootfs; overlay VFS is the remaining mount."
            )
        }
        rootfsPath = rootfs.path
        let rc = termx_blink_init(rootfsPath)
        guard rc == 0 else { throw LinuxGuestError.bootstrapFailed("termx_blink_init: \(rc)") }

        try FileManager.default.createDirectory(at: mapper.workspacesHostRoot, withIntermediateDirectories: true)
        try mount(hostPath: mapper.workspacesHostRoot.path, guestPath: mapper.guestWorkspacesPath)
        try mount(hostPath: mapper.homeHostRoot.path, guestPath: mapper.guestHomePath)
        prepared = true
    }

    func mount(hostPath: String, guestPath: String) throws {
        let rc = termx_blink_mount(hostPath, guestPath)
        guard rc == 0 else {
            throw LinuxGuestError.mountFailed("\(guestPath) (\(rc))")
        }
    }

    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool, shouldInterrupt: @escaping () -> Bool) async -> Int32 {
        guard prepared, let prog = argv.first else { return 127 }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let size = LinuxEnvironment.windowSize(fd: stdoutFD)
                    ?? LinuxEnvironment.windowSize(fd: stdinFD)
                var env = LinuxEnvironment.guestEnviron(
                    cwd: cwd, interactive: interactive,
                    cols: size?.cols, rows: size?.rows
                )
                let envp = LinuxEnvironment.cEnvp(&env)
                let argp = LinuxEnvironment.cArgv(argv)

                let code = termx_blink_run(prog, argp, envp, stdinFD, stdoutFD, stderrFD)
                LinuxEnvironment.freeCStrings(argp)
                LinuxEnvironment.freeCStrings(envp)
                continuation.resume(returning: code >= 0 ? code : 127)
            }
        }
    }

    func runNested(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) -> Int32 {
        guard prepared, let prog = argv.first else { return 127 }
        let size = LinuxEnvironment.windowSize(fd: stdoutFD)
            ?? LinuxEnvironment.windowSize(fd: stdinFD)
        var env = LinuxEnvironment.guestEnviron(
            cwd: cwd, interactive: interactive,
            cols: size?.cols, rows: size?.rows
        )
        let envp = LinuxEnvironment.cEnvp(&env)
        let argp = LinuxEnvironment.cArgv(argv)
        let code = termx_blink_run_nested(prog, argp, envp, stdinFD, stdoutFD, stderrFD)
        LinuxEnvironment.freeCStrings(argp)
        LinuxEnvironment.freeCStrings(envp)
        return code >= 0 ? code : 127
    }

    func interrupt() {
        termx_blink_interrupt()
    }

    func terminate() {
        termx_blink_terminate()
    }
}

#if os(macOS)
final class HostBlinkRuntime: LinuxRuntime, @unchecked Sendable {
    private let rootfs: URL
    private let mapper: LinuxPathMapper
    private var process: Process?
    private let processLock = NSLock()

    var supportsBindMounts: Bool { false }

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

    func mount(hostPath: String, guestPath: String) throws {
        _ = hostPath
        _ = guestPath
        throw LinuxGuestError.mountFailed("\(guestPath) (host blink CLI has no VfsMount)")
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

    func terminate() {
        processLock.lock()
        let runningProcess = process
        processLock.unlock()
        runningProcess?.terminate()
    }

    func runNested(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 127
        Task {
            code = await run(
                argv: argv, cwd: cwd,
                stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                interactive: interactive, shouldInterrupt: { false }
            )
            sem.signal()
        }
        sem.wait()
        return code
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
    static func guestEnviron(cwd: String, interactive: Bool, cols: Int? = nil, rows: Int? = nil) -> [String: String] {
        // Prefer /work when that is the Docker-style project mount.
        let pwd = (cwd == "/work" || cwd.hasPrefix("/work/")) ? cwd
            : (cwd.hasPrefix("/") ? cwd : "/work")
        var env: [String: String] = [
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LOGNAME": "root",
            "SHELL": "/bin/sh",
            "TMPDIR": "/tmp",
            "TERM": interactive ? "xterm-256color" : "dumb",
            // SwiftTerm renders 24-bit colour, so guest programs that probe
            // COLORTERM rather than terminfo get the truth. This is the same
            // value the TJIP handshake reports to host-run Node jobs.
            "COLORTERM": interactive ? "truecolor" : "",
            "LANG": "C.UTF-8",
            "PWD": pwd,
            // Generic desktop-integration contract used by any guest program.
            "DISPLAY": ":0",
            "WAYLAND_DISPLAY": "tether",
            "BROWSER": "open",
        ]
        if env["COLORTERM"]?.isEmpty == true { env.removeValue(forKey: "COLORTERM") }
        if let cols, cols > 0 { env["COLUMNS"] = String(cols) }
        if let rows, rows > 0 { env["LINES"] = String(rows) }
        return env
    }

    /// Read the PTY window size from a stdio fd (master or slave).
    static func windowSize(fd: Int32) -> (cols: Int, rows: Int)? {
        guard fd >= 0 else { return nil }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        let cols = Int(size.ws_col)
        let rows = Int(size.ws_row)
        guard cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    static func applyWindowSize(to env: inout [String: String], fd: Int32) {
        guard let size = windowSize(fd: fd) else { return }
        env["COLUMNS"] = String(size.cols)
        env["LINES"] = String(size.rows)
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
