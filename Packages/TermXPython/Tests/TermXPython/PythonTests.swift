import Foundation
import XCTest
@testable import TermXPython

// MARK: - Workspace test double (C3 frozen API subset for C4a acceptance)

public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let mountPath: String

    public init(id: UUID = UUID(), name: String, mountPath: String) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
    }
}

public final class WorkspaceDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [UUID: URL] = [:]
    private var names: [UUID: String] = [:]

    public init() {}

    public func register(_ workspace: Workspace, rootURL: URL) {
        lock.lock()
        roots[workspace.id] = rootURL
        names[workspace.id] = workspace.name
        lock.unlock()
    }

    public func resolve(virtualPath: String) -> String? {
        guard virtualPath.hasPrefix("/workspaces/") else { return nil }
        let remainder = String(virtualPath.dropFirst("/workspaces/".count))
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        let name = String(remainder[..<slash])
        let relative = String(remainder[remainder.index(after: slash)...])
        lock.lock()
        defer { lock.unlock() }
        guard let id = names.first(where: { $0.value == name })?.key,
              let root = roots[id] else { return nil }
        return root.appendingPathComponent(relative).path
    }

    public func beginAccess(_ workspace: Workspace) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let root = roots[workspace.id] else { throw WorkspaceAccessError.missing }
        return root.path
    }

    public enum WorkspaceAccessError: Error { case missing }
}

// MARK: - Process helpers

enum PythonTestSupport {
    static func xcframeworkRoot() -> String {
        if let env = ProcessInfo.processInfo.environment[PythonSupportLocator.overrideEnvironmentKey], !env.isEmpty {
            return env
        }
        let source = URL(fileURLWithPath: #filePath)
        var url = source.deletingLastPathComponent()
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("Frameworks/TermXPython.xcframework")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        XCTFail("TermXPython.xcframework not found; run Scripts/build-termx-python-xcframework.sh")
        return ""
    }

    static func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("termx-python-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pipePair() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        return (fds[0], fds[1])
    }

    static func readAll(fd: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func baseEnv(home: URL) -> [String: String] {
        PythonEnvironment.merge(base: [:], cwd: home.path, home: home.path)
    }
}

final class PythonTests: XCTestCase {
    private var python: EmbeddedPythonService!
    private var home: URL!

    override func setUpWithError() throws {
        home = try PythonTestSupport.makeTempHome()
        let root = PythonTestSupport.xcframeworkRoot()
        setenv(PythonSupportLocator.overrideEnvironmentKey, root, 1)
        python = EmbeddedPythonService(supportRoot: root)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: root), "Run Scripts/build-termx-python-xcframework.sh first")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func runCapture(_ argv: [String], cwd: String? = nil, env: [String: String]? = nil) async throws -> (code: Int32, stdout: String, stderr: String) {
        let pipesOut = try PythonTestSupport.pipePair()
        let pipesErr = try PythonTestSupport.pipePair()
        defer {
            close(pipesOut.read); close(pipesOut.write)
            close(pipesErr.read); close(pipesErr.write)
        }
        let merged = env ?? PythonTestSupport.baseEnv(home: home)
        let code = await python.run(
            argv: argv,
            cwd: cwd ?? home.path,
            environment: merged,
            stdinFD: -1,
            stdoutFD: pipesOut.write,
            stderrFD: pipesErr.write,
            interactive: false
        )
        close(pipesOut.write)
        close(pipesErr.write)
        return (code, PythonTestSupport.readAll(fd: pipesOut.read), PythonTestSupport.readAll(fd: pipesErr.read))
    }

    func testRegistryMetadata() throws {
        let manifestURL = TermXPythonResources.registryManifestURL
        XCTAssertNotNil(manifestURL)
        let data = try Data(contentsOf: manifestURL!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let commands = json?["commands"] as? [[String: String]]
        XCTAssertEqual(commands?.first?["name"], "python3")
        XCTAssertEqual(commands?.last?["name"], "pip")
    }

    private func bootstrapPipIfNeeded() async throws {
        let check = try await runCapture(["python3", "-m", "pip", "--version"])
        if check.code == 0 { return }

        let stdlib = "\(PythonTestSupport.xcframeworkRoot())/lib/python\(PythonEnvironment.pythonVersion)"
        let script = """
        import glob, os, zipfile
        site = os.path.join(os.environ['PYTHONUSERBASE'], 'lib/python\(PythonEnvironment.pythonVersion)/site-packages')
        os.makedirs(site, exist_ok=True)
        wheels = glob.glob('\(stdlib)/ensurepip/_bundled/pip*.whl')
        if not wheels:
            raise SystemExit('pip wheel missing')
        zipfile.ZipFile(wheels[0]).extractall(site)
        print('pip ready')
        """
        let ensure = try await runCapture(["python3", "-c", script])
        let combined = ensure.stdout + ensure.stderr
        XCTAssertEqual(ensure.code, 0, combined)
    }

    func testPrintOnePlusOne() async throws {
        let result = try await runCapture(["python3", "-c", "print(1+1)"])
        let combined = result.stdout + result.stderr
        XCTAssertEqual(result.code, 0, combined)
        XCTAssertTrue(combined.contains("2"), combined)
    }

    func testFirstPipRunBootstrapsWithoutLeakingImportFailure() async throws {
        let result = try await runCapture(["pip", "--version"])
        XCTAssertEqual(result.code, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("pip "), result.stdout)
        XCTAssertFalse(result.stderr.contains("No module named pip"), result.stderr)
    }

    func testPipBootstrapsTheEnvironmentSelectedUserBase() async throws {
        // Seed HOME's default user base first. The old implementation would see
        // this pip, skip bootstrap, then fail when the real command selected a
        // different PYTHONUSERBASE/PYTHONPATH.
        let defaultResult = try await runCapture(["pip", "--version"])
        XCTAssertEqual(defaultResult.code, 0, defaultResult.stdout + defaultResult.stderr)

        let customBase = home.appendingPathComponent("custom-python", isDirectory: true)
        var customEnv = PythonTestSupport.baseEnv(home: home)
        customEnv["PYTHONUSERBASE"] = customBase.path
        customEnv["PYTHONPATH"] = customBase
            .appendingPathComponent("lib/python\(PythonEnvironment.pythonVersion)/site-packages", isDirectory: true).path
        let customResult = try await runCapture(["pip", "--version"], env: customEnv)
        XCTAssertEqual(customResult.code, 0, customResult.stdout + customResult.stderr)
        XCTAssertTrue(customResult.stdout.contains(customBase.path), customResult.stdout)
        XCTAssertFalse(customResult.stderr.contains("No module named pip"), customResult.stderr)
    }

    func testStdlibImportSweep() async throws {
        let result = try await runCapture(["python3", "-c", "import ssl, sqlite3, ctypes; print('ok')"])
        let combined = result.stdout + result.stderr
        XCTAssertEqual(result.code, 0, combined)
        XCTAssertTrue(combined.contains("ok"), combined)
    }

    func testPipInstallRequestsAndRich() async throws {
        try await bootstrapPipIfNeeded()
        let installRequests = try await runCapture(["pip", "install", "requests"])
        XCTAssertEqual(installRequests.code, 0, installRequests.stderr)

        let installRich = try await runCapture(["pip", "install", "rich"])
        XCTAssertEqual(installRich.code, 0, installRich.stderr)

        let useBoth = try await runCapture([
            "python3", "-c",
            "import requests, rich; from rich.console import Console; Console().print(requests.__version__)",
        ])
        let useCombined = useBoth.stdout + useBoth.stderr
        XCTAssertEqual(useBoth.code, 0, useCombined)
        XCTAssertFalse(useCombined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, useCombined)
    }

    func testPipInstallFromLocalWheelIndex() async throws {
        try await bootstrapPipIfNeeded()
        guard let resourceRoot = Bundle.module.resourceURL else {
            XCTFail("missing test resources")
            return
        }
        let indexDir = resourceRoot.appendingPathComponent("wheel-index", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexDir.path))
        let install = try await runCapture([
            "pip", "install", "--no-index", "--find-links", "\(indexDir.path)/termx-demo", "--no-deps", "termx-demo",
        ])
        let installCombined = install.stdout + install.stderr
        XCTAssertEqual(install.code, 0, installCombined)

        let verify = try await runCapture(["python3", "-c", "import termx_demo; print(termx_demo.hello())"])
        let verifyCombined = verify.stdout + verify.stderr
        XCTAssertEqual(verify.code, 0, verifyCombined)
        XCTAssertTrue(verifyCombined.contains("termx"), verifyCombined)
    }

    func testWorkspaceFileReadWrite() async throws {
        let workspace = Workspace(name: "demo", mountPath: "/workspaces/demo")
        let root = home.appendingPathComponent("workspace-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let double = WorkspaceDouble()
        double.register(workspace, rootURL: root)

        let virtual = "/workspaces/demo/out.txt"
        guard let real = double.resolve(virtualPath: virtual) else {
            XCTFail("resolve failed")
            return
        }
        let rootPath = try double.beginAccess(workspace)

        let write = try await runCapture(["python3", "-c", "open('\(real)', 'w').write('termx')"], cwd: rootPath)
        XCTAssertEqual(write.code, 0, write.stderr)
        XCTAssertEqual(try String(contentsOfFile: real, encoding: .utf8), "termx")

        let read = try await runCapture(["python3", "-c", "print(open('\(real)').read())"], cwd: rootPath)
        let readCombined = read.stdout + read.stderr
        XCTAssertEqual(read.code, 0, readCombined)
        XCTAssertTrue(readCombined.contains("termx"), readCombined)
    }
}
