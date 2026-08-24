import Foundation
import TermXCore

#if canImport(TermXBlinkBridge)
import TermXBlinkBridge
#endif

/// Docker-like login: the interactive terminal *is* Alpine `/bin/sh` under Blink.
/// The picked workspace is bind-mounted at `/work`. Manifest-listed stubs in
/// `/usr/local/bin` look like guest commands but proxy to the host worker.
public final class LinuxShellEngine: TerminalEngine {
    public let linux: BlinkLinuxService
    public var hostExec: ((String, [String], [String: String], Int32, Int32, Int32) -> Int32)?

    private let pidAllocator = PIDAllocator()
    private var interruptedPIDs = Set<TermXPID>()
    private let lock = NSLock()
    private var hostWorkspaceCwd: String = "/"
    private let dispatchManifest = GuestDispatchManifest.loadDefault()

    public init(linux: BlinkLinuxService = BlinkLinuxService()) {
        self.linux = linux
    }

    public func startShell(cwd: String, env: [String: String],
                           ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 {
        hostWorkspaceCwd = cwd
        var env = env
        env["TETHER_HOST_CWD"] = cwd
        // Compatibility for older host-runtime packages during the rename.
        env["TERMX_HOST_CWD"] = cwd
        let pid = pidAllocator.allocate()

        installHostExecBridge()

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let code = self.runLoginShell(cwd: cwd, env: env, pty: ptySlave)
            DispatchQueue.main.async { onExit(code) }
        }
        return pid
    }

    public func signal(pid: Int32, _ sig: Int32) {
        if sig == SIGINT || sig == SIGTERM {
            lock.lock()
            interruptedPIDs.insert(pid)
            lock.unlock()
            linux.interrupt()
        }
    }

    // MARK: - Login

    private func runLoginShell(cwd: String, env: [String: String], pty: Int32) -> Int32 {
        let write: (String) -> Void = { text in
            guard pty >= 0 else { return }
            text.withCString { ptr in _ = Darwin.write(pty, ptr, strlen(ptr)) }
        }

        write("Tether Linux (Alpine / Blink) — your workspace is /work\n")
        write("Like a container shell: apk add git … then use them here.\n")
        write("Bootstrapping if needed…\n")

        let sem = DispatchSemaphore(value: 0)
        var bootstrapError: String?
        Task {
            do {
                if self.linux.state != .ready {
                    try await self.linux.bootstrap()
                }
                try self.mountWorkspace(cwd)
                try self.ensureGuestIdentity()
                try self.ensureHostBackedStubs()
            } catch {
                bootstrapError = String(describing: error)
            }
            sem.signal()
        }
        sem.wait()
        if let bootstrapError {
            write("linux: bootstrap failed: \(bootstrapError)\n")
            return 127
        }

        write("Ready. Install and run Alpine packages normally with apk.\n\n")

        let argv = ["/bin/sh", "-c", "cd /work 2>/dev/null || cd /; exec /bin/sh -l"]
        return linux.runSync(
            argv: argv, cwd: "/work",
            stdinFD: pty, stdoutFD: pty, stderrFD: pty,
            interactive: true
        )
    }

    private func mountWorkspace(_ hostCwd: String) throws {
#if canImport(TermXBlinkBridge)
        let fm = FileManager.default
        try fm.createDirectory(atPath: hostCwd, withIntermediateDirectories: true)
        _ = termx_blink_mount(hostCwd, "/work")
#endif
    }

    /// Guest should look like a container, not the developer's MacBook hostname.
    private func ensureGuestIdentity() throws {
        let fm = FileManager.default
        let root = linux.rootfs
        try removeLegacyGuestOverrides(from: root)
        try "tether\n".write(
            to: root.appendingPathComponent("etc/hostname"),
            atomically: true, encoding: .utf8
        )
        let hosts = """
        127.0.0.1\tlocalhost tether
        ::1\t\tlocalhost tether
        """
        try hosts.write(
            to: root.appendingPathComponent("etc/hosts"),
            atomically: true, encoding: .utf8
        )
        let profileD = root.appendingPathComponent("etc/profile.d", isDirectory: true)
        try fm.createDirectory(at: profileD, withIntermediateDirectories: true)
        let envScript = """
        # Tether guest Linux environment (URL openers, any CLI)
        export DISPLAY="${DISPLAY:-:0}"
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-tether}"
        export BROWSER="${BROWSER:-open}"
        """
        try envScript.write(
            to: profileD.appendingPathComponent("tether-env.sh"),
            atomically: true, encoding: .utf8
        )
        // Keep only product-neutral shell integration here. Core utilities such
        // as uname, hostname, git, and editors remain the real Alpine programs.
        let profileDir = root.appendingPathComponent("etc/profile.d", isDirectory: true)
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let profile = """
        export HOSTNAME=tether
        export PS1='tether:\\w\\$ '
        """
        try profile.write(
            to: profileDir.appendingPathComponent("tether-guest.sh"),
            atomically: true, encoding: .utf8
        )
    }

    /// Earlier development builds installed command-specific scripts and Git
    /// configuration into persistent rootfs directories. Remove only exact
    /// files created by those builds; never touch user-modified configuration.
    private func removeLegacyGuestOverrides(from root: URL) throws {
        let fm = FileManager.default
        let candidates: [(String, (String) -> Bool)] = [
            ("usr/local/bin/uname", { $0.contains("# TermX guest identity") }),
            ("usr/local/bin/hostname", {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "#!/bin/sh\nprintf 'tether\\n'"
            }),
            ("etc/profile.d/termx-guest.sh", {
                $0.contains("GIT_AUTHOR_NAME=tether") && $0.contains("pkill -f 'http.server'")
            }),
            ("root/.gitconfig", {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "[user]\n\temail = user@tether.local\n\tname = tether"
            }),
        ]
        for (relative, wasGeneratedByTether) in candidates {
            let url = root.appendingPathComponent(relative)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  wasGeneratedByTether(content) else { continue }
            try fm.removeItem(at: url)
        }
    }

    private func ensureHostBackedStubs() throws {
        let fm = FileManager.default
        let busybox = linux.rootfs.appendingPathComponent("bin/busybox").path
        guard fm.fileExists(atPath: busybox) else { return }
        let destDir = linux.rootfs.appendingPathComponent("usr/local/bin", isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        // Manifest-listed stubs proxy to host (see tether_dispatch_manifest.json).
        for name in dispatchManifest.stubBasenames {
            let dest = destDir.appendingPathComponent(name).path
            // May already exist as our uname/hostname scripts directory.
            if fm.fileExists(atPath: dest) {
                // Replace non-stub leftovers only when still a busybox copy is desired —
                // Skip an existing guest or previously-installed proxy command.
                continue
            }
            try fm.copyItem(atPath: busybox, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        }
    }

    private func installHostExecBridge() {
#if canImport(TermXBlinkBridge)
        dispatchManifest.installIntoBlinkBridge()
        let box = Unmanaged.passUnretained(self)
        termx_blink_set_host_exec({ prog, argv, envp, stdinFD, stdoutFD, stderrFD, exitOut, ctx in
            guard let ctx else { return -1 }
            let engine = Unmanaged<LinuxShellEngine>.fromOpaque(ctx).takeUnretainedValue()
            return engine.handleHostExec(
                prog: prog, argv: argv, envp: envp,
                stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                exitOut: exitOut
            )
        }, box.toOpaque())
#endif
    }

#if canImport(TermXBlinkBridge)
    private func handleHostExec(
        prog: UnsafePointer<CChar>?,
        argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
        envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32,
        exitOut: UnsafeMutablePointer<Int32>?
    ) -> Int32 {
        guard let prog, let argv, let exitOut, let hostExec else { return -1 }
        var args: [String] = []
        var i = 0
        while let p = argv[i] {
            args.append(String(cString: p))
            i += 1
        }
        var env: [String: String] = [:]
        if let envp {
            var j = 0
            while let e = envp[j] {
                let s = String(cString: e)
                if let eq = s.firstIndex(of: "=") {
                    env[String(s[..<eq])] = String(s[s.index(after: eq)...])
                }
                j += 1
            }
        }
        env["TETHER_HOST_CWD"] = hostWorkspaceCwd
        env["TERMX_HOST_CWD"] = hostWorkspaceCwd
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        env["HOME"] = docs
        let name = URL(fileURLWithPath: String(cString: prog)).lastPathComponent
        if !args.isEmpty { args[0] = name }
        let code = hostExec(name, args, env, stdinFD, stdoutFD, stderrFD)
        exitOut.pointee = code
        return 0
    }
#endif
}
