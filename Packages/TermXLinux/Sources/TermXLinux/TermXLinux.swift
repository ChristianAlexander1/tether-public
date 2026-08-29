import Foundation
import TetherStorageCore
import TermXCore
import TermXBlinkBridge

// MARK: - Linux guest service protocol

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

// MARK: - Path mapping (/work, /workspaces)

/// Guest `/work` is the selected iOS workspace; host Node sees the Darwin path
/// via `TETHER_HOST_CWD`. Rewrite either direction without string-prefix traps
/// (`/workish` is not `/work`).
public enum GuestWorkPath {
    public static let guestRoot = "/work"

    public static func isGuest(_ path: String) -> Bool {
        path == guestRoot || path.hasPrefix(guestRoot + "/")
    }

    public static func hostPath(_ path: String, workspace: String) -> String {
        let ws = URL(fileURLWithPath: workspace).standardizedFileURL.path
        guard isGuest(path) else { return path }
        if path == guestRoot { return ws }
        return ws + String(path.dropFirst(guestRoot.count))
    }

    public static func guestPath(_ path: String, workspace: String) -> String {
        if isGuest(path) { return path }
        let ws = URL(fileURLWithPath: workspace).standardizedFileURL.path
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if p == ws { return guestRoot }
        if p.hasPrefix(ws + "/") { return guestRoot + String(p.dropFirst(ws.count)) }
        return path
    }
}

/// `StorageFileSystem` over a real host directory, used only to answer the
/// symlink and existence questions `ConfinedPathResolver` asks while walking a
/// path. It never writes: `removeTree` is unreachable from the resolver and is
/// implemented as a no-op rather than given the power to delete.
final class HostDirectoryFileSystem: StorageFileSystem {
    let root: URL

    init(root: URL) { self.root = root }

    private func url(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        var candidate = root
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { return nil }
            candidate.appendPathComponent(String(component))
        }
        return candidate
    }

    func exists(_ relativePath: String) -> Bool {
        guard let url = url(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(_ relativePath: String) -> Bool {
        guard let url = url(relativePath) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    func sizeOfTree(_ relativePath: String) throws -> Int64 { 0 }

    func removeTree(_ relativePath: String) throws {}

    func list(_ relativePath: String) throws -> [String] {
        guard let url = url(relativePath) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    func destinationOfSymlink(_ relativePath: String) throws -> String? {
        guard let url = url(relativePath) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return nil
        }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}

public struct LinuxPathMapper {
    public let workspacesHostRoot: URL
    public let homeHostRoot: URL
    /// Selected iOS folder, bind-mounted at `/work`. Nil until login mounts it.
    public var workHostRoot: URL?

    public init(workspacesHostRoot: URL, homeHostRoot: URL, workHostRoot: URL? = nil) {
        self.workspacesHostRoot = workspacesHostRoot
        self.homeHostRoot = homeHostRoot
        self.workHostRoot = workHostRoot
    }

    /// Validates a guest-visible path under `/workspaces` or `/work`.
    public func validateGuestPath(_ path: String) throws -> String {
        if GuestWorkPath.isGuest(path) {
            let normalised = URL(fileURLWithPath: path).standardizedFileURL.path
            guard GuestWorkPath.isGuest(normalised) else {
                throw LinuxGuestError.invalidGuestPath
            }
            return normalised
        }
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

    /// Maps `/work/…` or `/workspaces/<name>/…` to a host filesystem path.
    ///
    /// Confinement is delegated to `ConfinedPathResolver`, which checks **every
    /// traversed component** for a symlink rather than only the leaf, bounds
    /// symlink hops so a cycle terminates, and compares path components instead
    /// of string prefixes (so `/workspaces-elsewhere` cannot pass a
    /// `/workspaces` prefix test). The public API here is unchanged.
    public func hostPath(forGuestPath guestPath: String) throws -> String {
        let validated = try validateGuestPath(guestPath)
        if GuestWorkPath.isGuest(validated) {
            guard let work = workHostRoot else { throw LinuxGuestError.invalidGuestPath }
            return try confinedHostPath(
                guestPath: validated, guestPrefix: GuestWorkPath.guestRoot, hostRoot: work
            )
        }
        return try confinedHostPath(
            guestPath: validated, guestPrefix: guestWorkspacesPath, hostRoot: workspacesHostRoot
        )
    }

    private func confinedHostPath(guestPath: String, guestPrefix: String, hostRoot: URL) throws -> String {
        let suffix = guestPath.dropFirst(guestPrefix.count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)

        let root = hostRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard !trimmed.isEmpty else { return root.path }

        // The resolver addresses the file system by the same component list it
        // builds from `confinementRoot`, so the adapter must be rooted at `/`
        // — not at the workspace directory — or every lookup would be resolved
        // twice against the root and find nothing.
        let resolver = ConfinedPathResolver(
            confinementRoot: root.path,
            fileSystem: HostDirectoryFileSystem(root: URL(fileURLWithPath: "/"))
        )
        switch resolver.resolve(trimmed) {
        case .success:
            return root.appendingPathComponent(trimmed).standardizedFileURL.path
        case .failure:
            throw LinuxGuestError.invalidGuestPath
        }
    }

    public var guestWorkspacesPath: String { "/workspaces" }
    public var guestHomePath: String { "/root" }
}

/// On-disk shape of the Alpine root Blink will boot.
///
/// Production `apk` uses an extracted host tree (`extracted`). A fakefs store
/// (`tetherfs.idx` + `data/`) is the iOS-container form; Blink must not treat
/// that directory as hostfs — device nodes live in the index, not on disk.
public enum LinuxRootfsLayout: Equatable {
    case extracted
    case fakefsStore

    public static func detect(at root: URL) -> LinuxRootfsLayout {
        let idx = root.appendingPathComponent("tetherfs.idx")
        return FileManager.default.fileExists(atPath: idx.path) ? .fakefsStore : .extracted
    }
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
        let busybox = rootfs.appendingPathComponent("bin/busybox")
        // Storage may delete the rootfs while an in-memory service still thinks it
        // is ready; only skip download when the real Alpine userland is present.
        if fm.fileExists(atPath: busybox.path),
           fm.fileExists(atPath: marker.path) || fm.fileExists(atPath: legacyMarker.path) {
            return
        }
        if fm.fileExists(atPath: marker.path) { try? fm.removeItem(at: marker) }
        if fm.fileExists(atPath: legacyMarker.path) { try? fm.removeItem(at: legacyMarker) }

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

// MARK: - Fallback registration

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
    public private(set) var pathMapper: LinuxPathMapper
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
        await provisionTerminfoIfMissing()
    }

    /// The Alpine minirootfs ships no terminfo database, so `TERM=xterm-256color`
    /// resolves to nothing until some package pulls ncurses in. Install the base
    /// terminfo entries once, right after bootstrap, so curses programs work
    /// even when they do not depend on ncurses themselves.
    ///
    /// Best-effort by design: offline devices, a missing emulator, or an apk
    /// failure must not stop a shell from opening. Component A answers
    /// XTGETTCAP directly, so capability probes still succeed without the
    /// database — this only widens what works, it is never load-bearing.
    private func provisionTerminfoIfMissing() async {
        guard !hasTerminfoDatabase else { return }
        guard let apk = LinuxFallback.guestCommandPath(name: "apk", rootfs: rootfs) else { return }
        let devNull = open("/dev/null", O_RDWR)
        defer { if devNull >= 0 { close(devNull) } }
        _ = await runtime.run(
            argv: [apk, "add", "--no-cache", "ncurses-terminfo-base"],
            cwd: "/",
            stdinFD: devNull, stdoutFD: devNull, stderrFD: devNull,
            interactive: false,
            shouldInterrupt: { false }
        )
    }

    /// Whether the guest has a terminfo entry tree on disk.
    public var hasTerminfoDatabase: Bool {
        let fm = FileManager.default
        for base in ["usr/share/terminfo", "etc/terminfo", "lib/terminfo"] {
            var isDir: ObjCBool = false
            let path = rootfs.appendingPathComponent(base).path
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return true }
        }
        return false
    }

    /// True when the on-disk Alpine rootfs still has a usable busybox userland.
    public var hasRootfs: Bool {
        FileManager.default.fileExists(atPath: rootfs.appendingPathComponent("bin/busybox").path)
    }

    /// Storage may delete Documents/linux while this service is still alive.
    /// Drop back to needsBootstrap so the next shell session re-downloads Alpine.
    public func invalidateIfRootfsMissing() {
        guard state == .ready else { return }
        if !hasRootfs {
            state = .needsBootstrap
        }
    }

    /// Explicit invalidation after Storage removes the linux directory.
    public func markNeedsBootstrap() {
        state = .needsBootstrap
    }

    public func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 {
        invalidateIfRootfsMissing()
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

    /// Deliver a line-discipline signal to the foreground guest job without
    /// cancelling the long-lived login-shell run.
    public func terminalSignal(_ signal: Int32) {
        termx_blink_terminal_signal(signal)
    }

    /// Whether guest `/work` and `/workspaces` are real VfsMounts into Blink.
    /// False on the host CLI lane, which has no bind-mount support.
    public var bindMountsAvailable: Bool { runtime.supportsBindMounts }

    /// Bind the selected iOS folder at `/work`. Updates the host-path mapper
    /// always; VfsMounts when the embedded bridge is linked.
    public func bindWorkRoot(_ hostPath: String) throws {
        let url = URL(fileURLWithPath: hostPath).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        pathMapper.workHostRoot = url
        guard runtime.supportsBindMounts else { return }
        try runtime.mount(hostPath: url.path, guestPath: GuestWorkPath.guestRoot)
    }

    /// Execute a guest ELF without replacing the login-shell machine.
    /// Used when host-proxied Node (or any host job) spawnSyncs `git` /
    /// `/bin/sh -c` while the Alpine shell is waiting on that job.
    public func runNested(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) -> Int32 {
        guard !argv.isEmpty else { return 127 }
        var argv = argv
        if !argv[0].contains("/") {
            guard let resolved = LinuxFallback.guestCommandPath(name: argv[0], rootfs: rootfs) else {
                return 127
            }
            argv[0] = resolved
        }
        return runtime.runNested(
            argv: argv, cwd: cwd,
            stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
            interactive: interactive
        )
    }

    public func terminate() {
        lock.lock()
        interrupted = true
        lock.unlock()
        runtime.terminate()
    }

    /// Kill and reap guest processes that are still alive after the login
    /// shell has gone. Background and stopped jobs survive their shell, and a
    /// sandboxed iOS app cannot enumerate its own descendants to find them —
    /// the engine tracks them as they fork so teardown can clean up here.
    public func reapGuestProcesses() {
        runtime.reapGuestProcesses()
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
                return dispatchGuest(
                    ["/bin/sh"], cwd: request.cwd,
                    stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD,
                    interactive: request.interactive, write: write
                )
            }
            return dispatchGuest(
                guestArgv, cwd: request.cwd,
                stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD,
                interactive: request.interactive, write: write
            )
        }

        return dispatchGuest(
            argv, cwd: request.cwd,
            stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD,
            interactive: request.interactive, write: write
        )
    }

    /// Resolve a command to a guest ELF and run it. While the login shell owns
    /// Blink's machine, this uses the nested channel so `/bin/sh -c` from a
    /// host job cannot hang the session.
    private func dispatchGuest(
        _ argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
        interactive: Bool, write: (String) -> Void
    ) -> Int32 {
        guard let resolved = resolveGuestArgv(argv) else {
            write("\(argv.first ?? ""): command not found\n")
            return 127
        }
        let guestCwd = guestCwd(from: cwd)
        if isGuestMachineActive {
            return runNested(
                argv: resolved, cwd: guestCwd,
                stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                interactive: interactive
            )
        }
        return runSync(
            argv: resolved, cwd: guestCwd,
            stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
            interactive: interactive
        )
    }

    private func guestCwd(from cwd: String) -> String {
        if GuestWorkPath.isGuest(cwd) { return cwd }
        if let work = pathMapper.workHostRoot {
            return GuestWorkPath.guestPath(cwd, workspace: work.path)
        }
        return cwd.hasPrefix("/") ? cwd : GuestWorkPath.guestRoot
    }

    /// Absolute guest paths (`/bin/sh`) and bare names (`git`) both resolve
    /// against the rootfs. Relative paths are treated as guest-absolute.
    func resolveGuestArgv(_ argv: [String]) -> [String]? {
        guard !argv.isEmpty else { return nil }
        var resolved = argv
        if resolved[0].contains("/") {
            let guest = resolved[0].hasPrefix("/") ? resolved[0] : "/\(resolved[0])"
            let hostPath = rootfs.appendingPathComponent(String(guest.dropFirst())).path
            guard LinuxFallback.isGuestExecutable(hostPath, rootfs: rootfs) else { return nil }
            resolved[0] = guest
            return resolved
        }
        if let guestPath = LinuxFallback.guestCommandPath(name: resolved[0], rootfs: rootfs) {
            resolved[0] = guestPath
            return resolved
        }
        return nil
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
