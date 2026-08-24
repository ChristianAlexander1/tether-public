import Foundation
import TermXCore
import TermXBlinkBridge

// MARK: - Frozen Linux guest protocol (docs/06-linux-emulation.md)

public protocol LinuxGuestRuntime: AnyObject {
    func bootstrap() async throws
    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32
    func interrupt()
}

public enum LinuxGuestState: Equatable, Sendable { case unavailable, needsBootstrap, ready }

public enum LinuxGuestError: Error, Equatable {
    case emulatorBinaryMissing
    case rootfsMissing
    case invalidGuestPath
    case bootstrapFailed(String)
    case mountFailed(String)
}

// MARK: - Path mapping (/workspaces)

public struct LinuxPathMapper {
    public let workspacesHostRoot: URL
    public let homeHostRoot: URL

    public init(workspacesHostRoot: URL, homeHostRoot: URL) {
        self.workspacesHostRoot = workspacesHostRoot
        self.homeHostRoot = homeHostRoot
    }

    /// Validates a guest-visible path under `/workspaces`.
    public func validateGuestPath(_ path: String) throws -> String {
        guard path == guestWorkspacesPath || path.hasPrefix(guestWorkspacesPath + "/") else {
            throw LinuxGuestError.invalidGuestPath
        }

        // Normalise dot components and reject paths which escape the mount. A
        // prefix-only check accepts both `/workspaces-elsewhere` and
        // `/workspaces/../../etc`, which would expose unrelated host files.
        let normalised = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalised == guestWorkspacesPath || normalised.hasPrefix(guestWorkspacesPath + "/") else {
            throw LinuxGuestError.invalidGuestPath
        }
        return normalised
    }

    /// Maps `/workspaces/<name>/…` to a host filesystem path for native reads.
    public func hostPath(forGuestPath guestPath: String) throws -> String {
        let validated = try validateGuestPath(guestPath)
        let suffix = validated.dropFirst(guestWorkspacesPath.count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        let root = workspacesHostRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw LinuxGuestError.invalidGuestPath
        }

        // `resolvingSymlinksInPath()` does not reliably resolve a symlink when
        // the final leaf does not exist. Resolve the nearest existing ancestor
        // so `/workspaces/link-to-outside/new-file` is rejected too.
        var existingAncestor = candidate
        while !FileManager.default.fileExists(atPath: existingAncestor.path), existingAncestor.path != root.path {
            existingAncestor.deleteLastPathComponent()
        }
        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath()
        guard resolvedAncestor.path == root.path || resolvedAncestor.path.hasPrefix(root.path + "/") else {
            throw LinuxGuestError.invalidGuestPath
        }
        return candidate.path
    }

    public var guestWorkspacesPath: String { "/workspaces" }
    public var guestHomePath: String { "/root" }
}

// MARK: - Alpine bootstrap

public enum AlpineBootstrap {
    public static let defaultVersion = "3.20.3"
    public static let defaultArch = "x86_64"

    public static func cdnURL(version: String = defaultVersion, arch: String = defaultArch) -> URL {
        let majorMinor = version.split(separator: ".").prefix(2).joined(separator: ".")
        return URL(string: "https://dl-cdn.alpinelinux.org/alpine/v\(majorMinor)/releases/\(arch)/alpine-minirootfs-\(version)-\(arch).tar.gz")!
    }

    public static func downloadAndExtract(into rootfs: URL, version: String = defaultVersion) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let marker = rootfs.appendingPathComponent(".tether-bootstrapped")
        let legacyMarker = rootfs.appendingPathComponent(".termx-bootstrapped")
        if fm.fileExists(atPath: marker.path) || fm.fileExists(atPath: legacyMarker.path) { return }

        let url = cdnURL(version: version)
        let (archive, _) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: archive) }

        do {
            try TarGzExtractor.extract(archive: archive, into: rootfs)
        } catch {
            throw LinuxGuestError.bootstrapFailed("rootfs extract failed: \(error)")
        }

        let resolv = rootfs.appendingPathComponent("etc/resolv.conf")
        try fm.createDirectory(at: resolv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nameserver 8.8.8.8\nnameserver 1.1.1.1\n".write(to: resolv, atomically: true, encoding: .utf8)

        try Data("ok".utf8).write(to: marker)
    }
}

// MARK: - Fallback registration (09-integration-contracts.md §2.1)

public enum LinuxFallback {
    public static func register(into registry: CommandRegistry, service: BlinkLinuxService) {
        registry.registerFallback { request in
            service.runSync(
                request: request,
                write: { _ in }
            )
        }
    }

    /// Guest directories searched for a command, in PATH order.
    static let guestBinDirs = ["usr/local/bin", "usr/local/sbin", "usr/bin", "usr/sbin", "bin", "sbin"]

    /// Absolute *guest* path of an installed command (`git` → `/usr/bin/git`), or nil.
    /// Anything installed with `apk add` becomes runnable by bare name through this.
    public static func guestCommandPath(name: String, rootfs: URL) -> String? {
        guard !name.contains("/") else { return nil }
        for dir in guestBinDirs {
            let hostPath = rootfs.appendingPathComponent("\(dir)/\(name)").path
            if isGuestExecutable(hostPath, rootfs: rootfs) {
                return "/\(dir)/\(name)"
            }
        }
        return nil
    }

    /// Whether the entry is runnable *inside the guest*.
    ///
    /// Most of Alpine's userland is busybox applets: `/bin/uname` is a symlink to
    /// the guest-absolute `/bin/busybox`. FileManager resolves that against the
    /// **host** root, where it does not exist, so every applet looked missing.
    /// Re-root absolute link targets at the rootfs before testing them.
    static func isGuestExecutable(_ hostPath: String, rootfs: URL) -> Bool {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: hostPath) { return true }
        var current = hostPath
        for _ in 0..<16 {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: current) else { return false }
            if target.hasPrefix("/") {
                current = rootfs.appendingPathComponent(String(target.dropFirst())).path
            } else {
                current = URL(fileURLWithPath: current)
                    .deletingLastPathComponent()
                    .appendingPathComponent(target)
                    .standardizedFileURL.path
            }
            if fm.isExecutableFile(atPath: current) { return true }
        }
        return false
    }

    public static func canRunGuestCommand(name: String, rootfs: URL) -> Bool {
        guestCommandPath(name: name, rootfs: rootfs) != nil
    }
}

// MARK: - BlinkLinuxService

public final class BlinkLinuxService: LinuxGuestRuntime {
    public private(set) var state: LinuxGuestState = .needsBootstrap
    public let rootfs: URL
    public let pathMapper: LinuxPathMapper
    private let runtime: LinuxRuntime
    private var interrupted = false
    private let lock = NSLock()

    public init(
        rootfs: URL? = nil,
        workspacesHostRoot: URL? = nil,
        homeHostRoot: URL? = nil
    ) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resolvedRoot = rootfs ?? docs.appendingPathComponent("linux", isDirectory: true)
        self.rootfs = resolvedRoot
        let ws = workspacesHostRoot ?? docs.appendingPathComponent("workspaces", isDirectory: true)
        let home = homeHostRoot ?? docs
        self.pathMapper = LinuxPathMapper(workspacesHostRoot: ws, homeHostRoot: home)
        self.runtime = LinuxRuntimeFactory.make(rootfs: resolvedRoot, mapper: pathMapper)
    }

    public func bootstrap() async throws {
        try await AlpineBootstrap.downloadAndExtract(into: rootfs)
        try FileManager.default.createDirectory(at: pathMapper.workspacesHostRoot, withIntermediateDirectories: true)
        try runtime.prepare(rootfs: rootfs, mapper: pathMapper)
        state = .ready
    }

    public func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 {
        if state == .needsBootstrap {
            do {
                try await bootstrap()
            } catch {
                let message = "linux: bootstrap failed: \(error)\n"
                if stderrFD >= 0 {
                    message.utf8CString.withUnsafeBufferPointer { _ = write(stderrFD, $0.baseAddress!, $0.count - 1) }
                }
                return 127
            }
        }
        guard state == .ready, !argv.isEmpty else {
            if state != .ready {
                let message = "linux: embedded Blink runtime unavailable (build Blink.xcframework)\n"
                if stderrFD >= 0 {
                    message.utf8CString.withUnsafeBufferPointer { _ = write(stderrFD, $0.baseAddress!, $0.count - 1) }
                }
            }
            return 127
        }
        // The emulator needs an absolute guest path. `linux apk add git` arrives
        // here as ["apk", ...] and used to fail with no output at all; the
        // bare-name fallback in runSync(request:) already resolved these, so do
        // the same for the explicit `linux <cmd>` form. Resolution has to happen
        // after bootstrap, since it looks for the binary inside the rootfs.
        var argv = argv
        if !argv[0].contains("/") {
            guard let resolved = LinuxFallback.guestCommandPath(name: argv[0], rootfs: rootfs) else {
                let message = "linux: \(argv[0]): command not found in the Alpine guest\n"
                if stderrFD >= 0 {
                    message.utf8CString.withUnsafeBufferPointer { _ = write(stderrFD, $0.baseAddress!, $0.count - 1) }
                }
                return 127
            }
            argv[0] = resolved
        }

        lock.withLock { interrupted = false }
        return await runtime.run(
            argv: argv, cwd: cwd,
            stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
            interactive: interactive,
            shouldInterrupt: { [weak self] in
                self?.lock.lock()
                defer { self?.lock.unlock() }
                return self?.interrupted ?? false
            }
        )
    }

    public func interrupt() {
        lock.lock()
        interrupted = true
        lock.unlock()
        runtime.interrupt()
    }

    /// True while the login shell (or any guest program) owns Blink's global machine.
    /// A second `run()` during this window replaces the machine and kills the session.
    public var isGuestMachineActive: Bool {
        termx_blink_is_busy() != 0
    }

    public func runSync(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) -> Int32 {
        guard !argv.isEmpty else { return 127 }
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 127
        Task {
            code = await run(argv: argv, cwd: cwd, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: interactive)
            sem.signal()
        }
        sem.wait()
        return code
    }

    public func runSync(request: SpawnRequest, write: @escaping (String) -> Void) -> Int32 {
        let argv = ShellLexer.lex(request.cmdline)
        guard !argv.isEmpty else { return 0 }

        if argv.first == "linux" {
            let guestArgv = Array(argv.dropFirst())
            if guestArgv.isEmpty {
                return runSync(argv: ["/bin/sh"], cwd: request.cwd, stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD, interactive: request.interactive)
            }
            return runSync(argv: guestArgv, cwd: request.cwd, stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD, interactive: request.interactive)
        }

        // Bare-name fallthrough: `git status` runs the guest's /usr/bin/git.
        if let guestPath = LinuxFallback.guestCommandPath(name: argv[0], rootfs: rootfs) {
            var resolved = argv
            resolved[0] = guestPath
            return runSync(argv: resolved, cwd: request.cwd, stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD, interactive: request.interactive)
        }

        write("\(argv[0]): command not found\n")
        return 127
    }

    public func mapHostPath(_ path: String) throws -> String {
        try pathMapper.hostPath(forGuestPath: path)
    }

    public var registryEntries: [[String: String]] {
        [
            ["name": "linux", "kind": "linux", "entry": "BlinkLinuxService", "framework": "TermXLinux"],
        ]
    }

    public var registryEntry: [String: String] { registryEntries[0] }
}
