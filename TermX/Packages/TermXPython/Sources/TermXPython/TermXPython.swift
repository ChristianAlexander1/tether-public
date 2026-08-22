import Foundation
import TermXPythonBridge

// MARK: - Frozen PythonRuntime protocol (C4a)

public protocol PythonRuntime: AnyObject {
    func run(argv: [String], cwd: String, environment: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32
    func interrupt()
}

public enum PythonRuntimeError: Error, Equatable {
    case runtimeBinaryMissing
    case invalidArguments
    case initializationFailed
}

// MARK: - Environment defaults (09-integration-contracts.md §2.6)

public enum PythonEnvironment {
    public static let pythonVersion = "3.14"
    public static let sitePackagesRelative = "python/lib/python\(pythonVersion)/site-packages"
    public static let userBinRelative = "python/bin"

    public static func merge(base: [String: String], cwd: String, home: String? = nil) -> [String: String] {
        let resolvedHome = home ?? base["HOME"] ?? defaultHome()
        var env = base
        env["HOME"] = resolvedHome
        env["PYTHONUSERBASE"] = env["PYTHONUSERBASE"] ?? "\(resolvedHome)/python"
        env["PYTHONPATH"] = env["PYTHONPATH"] ?? "\(resolvedHome)/\(sitePackagesRelative)"
        env["PATH"] = env["PATH"] ?? "/bin:\(resolvedHome)/\(userBinRelative):\(resolvedHome)/node/bin"
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PWD"] = cwd
        return env
    }

    public static func defaultHome() -> String {
        #if os(iOS)
        return NSHomeDirectory() + "/Documents"
        #else
        return NSHomeDirectory()
        #endif
    }

    public static func ensureUserLayout(home: String) throws {
        let fm = FileManager.default
        let dirs = [
            "\(home)/python/lib/python\(pythonVersion)/site-packages",
            "\(home)/python/bin",
        ]
        for dir in dirs {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Support root discovery

public enum PythonSupportLocator {
    public static let overrideEnvironmentKey = "TERMX_PYTHON_ROOT"

    public static func locateXCFrameworkRoot() -> String? {
        if let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey], !override.isEmpty {
            return override
        }
        if let bundled = Bundle.main.resourcePath.map({ "\($0)/TermXPython.xcframework" }),
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        let candidates = [
            repoFrameworksPath(),
            "../Frameworks/TermXPython.xcframework",
            "../../Frameworks/TermXPython.xcframework",
            "../../../Frameworks/TermXPython.xcframework",
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return (candidate as NSString).standardizingPath
            }
        }
        return nil
    }

    private static func repoFrameworksPath() -> String? {
        let sourceFile = #filePath
        var url = URL(fileURLWithPath: sourceFile)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("Frameworks/TermXPython.xcframework").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Wheel index plan (binary wheels for iOS)

public enum PythonWheelIndex {
    /// Primary PyPI fallback for pure-Python wheels.
    public static let pypiURL = "https://pypi.org/simple"

    /// TermX-hosted index for prebuilt iOS binary wheels (PEP 730 tags).
    /// Populate via Mobile Forge / BeeWare wheel pipeline; not required for pure-Python packages.
    public static let termxBinaryWheelIndexURL = "https://wheels.termx.dev/ios/simple/"

    /// a-Shell community index (BSD-licensed hosting) as secondary binary source.
    public static let aShellWheelIndexURL = "https://github.com/hololeap/PyPi-index-aarch64-apple-ios/releases/download/v1.0/index.html"

    public static func pipInstallArgs(package: String, useTermXIndex: Bool = false) -> [String] {
        var args = ["python3", "-m", "pip", "install", "--no-input"]
        if useTermXIndex {
            args += ["--index-url", termxBinaryWheelIndexURL, "--extra-index-url", pypiURL]
        }
        args.append(package)
        return args
    }
}

public enum TermXPythonResources {
    public static var registryManifestURL: URL? {
        Bundle.module.url(forResource: "registry", withExtension: "json")
    }

    public static var wheelIndexPlanURL: URL? {
        Bundle.module.url(forResource: "wheel-index", withExtension: "json")
    }
}

// MARK: - Embedded service

public final class EmbeddedPythonService: PythonRuntime {
    private let queue = DispatchQueue(label: "com.termx.python.jobs", qos: .userInitiated)
    private var interrupted = false
    private let lock = NSLock()
    private var configuredRoot: String?
    /// Path of the CPython standard library this service resolved, or nil when no
    /// stdlib is present (an app build without the bundled `python-stdlib`).
    private var stdlibPath: String?

    private var isHostPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    public init(supportRoot: String? = nil) {
        let resolvedRoot = supportRoot ?? PythonSupportLocator.locateXCFrameworkRoot()
        #if os(macOS)
        // Host runs link the macOS Python.framework slice; its own stdlib carries the
        // darwin sysconfigdata and lib-dynload that the platform-neutral copy lacks.
        let hostStdlib = resolvedRoot.map {
            "\($0)/macos-arm64_x86_64/Python.framework/Versions/\(PythonEnvironment.pythonVersion)/lib/python\(PythonEnvironment.pythonVersion)"
        }
        #else
        let hostStdlib: String? = nil
        #endif
        if let hostStdlib, FileManager.default.fileExists(atPath: hostStdlib) {
            stdlibPath = hostStdlib
            termx_python_set_stdlib_path(hostStdlib)
            #if os(macOS)
            // Extension modules (_ssl, _sqlite3, …) reference libssl/libcrypto/etc. by
            // @rpath install name; preloading them by absolute path lets dyld satisfy
            // those references without an rpath on the host test executable.
            let depDir = "\(hostStdlib.replacingOccurrences(of: "/python\(PythonEnvironment.pythonVersion)", with: ""))"
            if let libs = try? FileManager.default.contentsOfDirectory(atPath: depDir) {
                for lib in libs where lib.hasSuffix(".dylib") {
                    _ = dlopen("\(depDir)/\(lib)", RTLD_GLOBAL | RTLD_NOW)
                }
            }
            #endif
        } else if let appStdlib = Self.appBundledStdlibPath(),
                  FileManager.default.fileExists(atPath: appStdlib) {
            // BeeWare `install_python` copies stdlib into `$APP/python/lib/python3.x`.
            stdlibPath = appStdlib
            termx_python_set_stdlib_path(appStdlib)
        } else if let bundledStdlib = Bundle.module.resourceURL?
            .appendingPathComponent("PythonLib", isDirectory: true).path,
           FileManager.default.fileExists(atPath: bundledStdlib) {
            stdlibPath = bundledStdlib
            termx_python_set_stdlib_path(bundledStdlib)
        } else if let root = resolvedRoot,
                  FileManager.default.fileExists(atPath: "\(root)/lib/python\(PythonEnvironment.pythonVersion)"),
                  supportRoot != nil || isHostPlatform {
            // Only a host/test run may reach outside the app bundle for the stdlib. The
            // Simulator can see the Mac's filesystem, and trusting it there would hide
            // the missing-bundle failure that a real device hits.
            let path = "\(root)/lib/python\(PythonEnvironment.pythonVersion)"
            stdlibPath = path
            termx_python_set_stdlib_path(path)
        }

        if let supportRoot, FileManager.default.fileExists(atPath: supportRoot) {
            configuredRoot = supportRoot
            termx_python_set_support_root(supportRoot)
        } else if let env = ProcessInfo.processInfo.environment[PythonSupportLocator.overrideEnvironmentKey],
                  FileManager.default.fileExists(atPath: env) {
            configuredRoot = env
            termx_python_set_support_root(env)
        } else {
            // Linked CPython slice is inside the app/test bundle; bridge discovers PYTHONHOME via dladdr().
            configuredRoot = PythonSupportLocator.locateXCFrameworkRoot() ?? "embedded"
        }
    }

    /// The interpreter can only start when its standard library is present.
    public var isRuntimeAvailable: Bool {
        stdlibPath != nil
    }

    public func run(argv: [String], cwd: String, environment: [String: String],
                    stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                    interactive: Bool) async -> Int32 {
        guard !argv.isEmpty else { return 2 }
        guard isRuntimeAvailable else {
            let name = argv.first ?? "python3"
            let message = "\(name): Python standard library not bundled in this build "
                + "(add python-stdlib to the app target's resources)\n"
            if stderrFD >= 0 {
                message.utf8CString.withUnsafeBufferPointer { _ = write(stderrFD, $0.baseAddress!, $0.count - 1) }
            }
            return 127
        }

        let merged = PythonEnvironment.merge(base: environment, cwd: cwd)
        if argv.first == "pip" || argv.first == "pip3" {
            try? await bootstrapPipIfNeeded(home: merged["HOME"] ?? PythonEnvironment.defaultHome())
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                self.lock.lock()
                self.interrupted = false
                self.lock.unlock()

                do {
                    try PythonEnvironment.ensureUserLayout(home: environment["HOME"] ?? PythonEnvironment.defaultHome())
                } catch {
                    continuation.resume(returning: 1)
                    return
                }

                let merged = PythonEnvironment.merge(base: environment, cwd: cwd)
                let exitCode = self.runLocked(
                    argv: argv,
                    cwd: cwd,
                    environment: merged,
                    stdinFD: stdinFD,
                    stdoutFD: stdoutFD,
                    stderrFD: stderrFD,
                    interactive: interactive
                )
                if exitCode == 127, stderrFD >= 0 {
                    let message = "python3: embedded interpreter failed to initialize "
                        + "(check bundled python/lib and extension frameworks)\n"
                    message.utf8CString.withUnsafeBufferPointer { _ = write(stderrFD, $0.baseAddress!, $0.count - 1) }
                }
                continuation.resume(returning: exitCode)
            }
        }
    }

    public func interrupt() {
        lock.lock()
        interrupted = true
        lock.unlock()
        termx_python_interrupt()
    }

    /// Installs pip into `$PYTHONUSERBASE` without subprocess/fork (required on iOS).
    public func bootstrapPipIfNeeded(home: String) async throws {
        var env = PythonEnvironment.merge(base: [:], cwd: home, home: home)
        let check = await run(argv: ["python3", "-m", "pip", "--version"], cwd: home, environment: env,
                              stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false)
        if check == 0 { return }

        guard let stdlibRoot = stdlibPath
            ?? configuredRoot.map({ "\($0)/lib/python\(PythonEnvironment.pythonVersion)" })
            ?? PythonSupportLocator.locateXCFrameworkRoot().map({ "\($0)/lib/python\(PythonEnvironment.pythonVersion)" }) else {
            throw PythonRuntimeError.runtimeBinaryMissing
        }

        let script = """
        import glob, os, zipfile
        site = os.path.join(os.environ['PYTHONUSERBASE'], 'lib/python\(PythonEnvironment.pythonVersion)/site-packages')
        os.makedirs(site, exist_ok=True)
        wheels = glob.glob('\(stdlibRoot)/ensurepip/_bundled/pip*.whl')
        if not wheels:
            raise SystemExit('pip wheel missing')
        zipfile.ZipFile(wheels[0]).extractall(site)
        """
        let code = await run(argv: ["python3", "-c", script], cwd: home, environment: env,
                             stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false)
        if code != 0 { throw PythonRuntimeError.initializationFailed }
    }

    public var registryEntries: [[String: String]] {
        [
            ["name": "python3", "kind": "native", "entry": "termx_python_run", "framework": "TermXPython"],
            ["name": "pip", "kind": "native", "entry": "termx_python_run", "framework": "TermXPython"],
        ]
    }

    public var registryEntry: [String: String] { registryEntries[0] }

    /// BeeWare `install_python` places stdlib at `$APP_BUNDLE/python/lib/python3.x`.
    private static func appBundledStdlibPath() -> String? {
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("python/lib/python\(PythonEnvironment.pythonVersion)", isDirectory: true).path,
            Bundle.main.resourceURL?
                .appendingPathComponent("python/lib/python\(PythonEnvironment.pythonVersion)", isDirectory: true).path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func runLocked(argv: [String], cwd: String, environment: [String: String],
                           stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                           interactive: Bool) -> Int32 {
        let normalized = normalizeArgv(argv)
        var cStrings = normalized.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argvPointers = cStrings.map { UnsafeMutablePointer(mutating: $0) }
        argvPointers.append(nil)

        let envPairs = environment.map { "\($0.key)=\($0.value)" }
        var envStorage = envPairs.map { strdup($0) }
        defer { envStorage.forEach { free($0) } }
        var envPointers: [UnsafePointer<CChar>?] = envStorage.map { UnsafePointer($0!) }
        envPointers.append(nil)

        return argvPointers.withUnsafeMutableBufferPointer { argvBuffer in
            envPointers.withUnsafeBufferPointer { envBuffer in
                termx_python_run(
                    Int32(normalized.count),
                    argvBuffer.baseAddress,
                    cwd,
                    envBuffer.baseAddress,
                    stdinFD,
                    stdoutFD,
                    stderrFD,
                    interactive ? 1 : 0
                )
            }
        }
    }

    private func normalizeArgv(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return argv }
        if first == "pip" {
            return ["python3", "-m", "pip"] + Array(argv.dropFirst())
        }
        if first == "python" {
            var copy = argv
            copy[0] = "python3"
            return copy
        }
        return argv
    }
}
