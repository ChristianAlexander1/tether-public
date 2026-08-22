import Foundation
import TermXCore

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
        guard path.hasPrefix("/workspaces") else { throw LinuxGuestError.invalidGuestPath }
        return path
    }

    /// Maps `/workspaces/<name>/…` to a host filesystem path for native reads.
    public func hostPath(forGuestPath guestPath: String) throws -> String {
        _ = try validateGuestPath(guestPath)
        let suffix = guestPath.dropFirst("/workspaces".count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        return workspacesHostRoot.appendingPathComponent(trimmed).path
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

        let marker = rootfs.appendingPathComponent(".termx-bootstrapped")
        if fm.fileExists(atPath: marker.path) { return }

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

    public static func canRunGuestCommand(name: String, rootfs: URL) -> Bool {
        let candidate = rootfs.appendingPathComponent("usr/bin/\(name)").path
        if FileManager.default.isExecutableFile(atPath: candidate) { return true }
        let sbin = rootfs.appendingPathComponent("sbin/\(name)").path
        return FileManager.default.isExecutableFile(atPath: sbin)
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

        if LinuxFallback.canRunGuestCommand(name: argv[0], rootfs: rootfs) {
            return runSync(argv: argv, cwd: request.cwd, stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD, interactive: request.interactive)
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
