import XCTest
@testable import TermXNode

final class NodeTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRegistryMetadata() {
        let service = EmbeddedNodeService()
        XCTAssertEqual(service.registryEntry["name"], "node")
        XCTAssertEqual(service.registryEntries.count, 2)
        XCTAssertEqual(service.registryEntries[1]["name"], "npm")
    }

    func testShimExportsRequiredAPI() throws {
        let shimRoot = NodeShim.bundleDirectory ?? {
            XCTFail("shim bundle missing")
            return URL(fileURLWithPath: "/")
        }()
        let index = try String(contentsOf: shimRoot.appendingPathComponent("index.js"))
        XCTAssertTrue(index.contains("Module._load"), "shim must patch Module._load")
        let child = try String(contentsOf: shimRoot.appendingPathComponent("lib/child_process.js"))
        for api in NodeShim.requiredExports {
            XCTAssertTrue(child.contains(api), "shim must export \(api)")
        }
        XCTAssertTrue(child.contains("spawnSync"))
        XCTAssertTrue(child.contains("execSync"))
        XCTAssertTrue(child.contains("fork"))
        let ipc = try String(contentsOf: shimRoot.appendingPathComponent("lib/ipc.js"))
        XCTAssertTrue(ipc.contains("roundTrip"))

        let bootstrap = try String(contentsOf: shimRoot.appendingPathComponent("bootstrap.js"))
        XCTAssertFalse(bootstrap.contains("require('module').runMain()"),
                       "a persistent engine must not re-enter Node's one-shot runMain bootstrap")
        XCTAssertTrue(bootstrap.contains("path.resolve(process.cwd(), entry)"),
                      "file-based node jobs must resolve relative to the workspace")
        XCTAssertTrue(bootstrap.contains("delete require.cache[require.resolve(resolvedEntry)]"),
                      "a CLI entry point must execute again in the persistent engine")
    }

    func testRegistryJSONLoads() throws {
        guard let url = Bundle.module.url(forResource: "registry", withExtension: "json") else {
            XCTFail("registry.json missing")
            return
        }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let commands = json?["commands"] as? [[String: String]]
        XCTAssertEqual(commands?.count, 2)
    }

    func testNodeEvalPrintsTwo() async throws {
        guard HostNodeRuntime.resolveNodeBinaryForTests() != nil else {
            throw XCTSkip("node binary not available")
        }
        let outPipe = Pipe()
        let service = EmbeddedNodeService()
        let code = await service.run(
            argv: ["node", "-e", "console.log(1+1)"],
            cwd: tempDir.path,
            env: [:],
            stdinFD: -1,
            stdoutFD: outPipe.fileHandleForWriting.fileDescriptor,
            stderrFD: -1,
            interactive: false
        )
        outPipe.fileHandleForWriting.closeFile()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(code, 0, "stderr/out: \(output)")
        XCTAssertTrue(output.contains("2"), "expected '2' in output, got: \(output)")
    }

    func testShimRoutesPostinstallThroughSpawnRecorder() async throws {
        guard HostNodeRuntime.resolveNodeBinaryForTests() != nil else {
            throw XCTSkip("node binary not available")
        }
        let recorder = RecordingSpawnExecutor()
        let service = EmbeddedNodeService(spawnExecutor: recorder)
        let errPipe = Pipe()
        let code = await service.run(
            argv: ["node", "-e", "const { execSync } = require('child_process'); console.log(execSync('echo postinstall').trim());"],
            cwd: tempDir.path,
            env: ["TERMX_INTERACTIVE": "0"],
            stdinFD: -1, stdoutFD: -1,
            stderrFD: errPipe.fileHandleForWriting.fileDescriptor,
            interactive: false
        )
        errPipe.fileHandleForWriting.closeFile()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(code, 0, "stderr: \(err)")
        XCTAssertFalse(recorder.records.isEmpty, "shim must route spawns through termx_spawn recorder; stderr: \(err)")
        XCTAssertTrue(recorder.records.contains { $0.file.hasSuffix("sh") || $0.file.hasSuffix("echo") || $0.args.joined().contains("postinstall") })
    }

    func testJobQueueIsSerialized() async {
        let recorder = RecordingSpawnExecutor()
        let service = EmbeddedNodeService(spawnExecutor: recorder)
        async let first = service.run(argv: ["node", "-e", "console.log(1)"], cwd: tempDir.path, env: [:], stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false)
        async let second = service.run(argv: ["node", "-e", "console.log(2)"], cwd: tempDir.path, env: [:], stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false)
        let codes = await [first, second]
        if HostNodeRuntime.resolveNodeBinaryForTests() == nil {
            XCTAssertEqual(codes, [127, 127])
        } else {
            XCTAssertEqual(codes, [0, 0])
        }
    }

    func testInterruptReturnsNonZero() async throws {
        guard HostNodeRuntime.resolveNodeBinaryForTests() != nil else {
            throw XCTSkip("node binary not available")
        }
        let service = EmbeddedNodeService()
        let task = Task {
            await service.run(
                argv: ["node", "-e", "while(true){}"],
                cwd: tempDir.path,
                env: [:],
                stdinFD: -1, stdoutFD: -1, stderrFD: -1,
                interactive: true
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        service.interrupt()
        let code = await task.value
        XCTAssertNotEqual(code, 0)
    }

    func testOsPlatformDarwinViaShim() throws {
        guard let node = HostNodeRuntime.resolveNodeBinaryForTests(),
              let preload = NodeShim.preloadPath else {
            throw XCTSkip("node/shim unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", "console.log(require('os').platform())"]
        process.environment = ["NODE_OPTIONS": "--require \(preload)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "darwin")
    }

    func testTtyIsattyWhenInteractive() throws {
        guard let node = HostNodeRuntime.resolveNodeBinaryForTests(),
              let preload = NodeShim.preloadPath else {
            throw XCTSkip("node/shim unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", "console.log(require('tty').isatty(1)?'yes':'no')"]
        var nodeOptionsParts: [String] = []
        if let ensureIpc = NodeShim.ensureIpcPath {
            nodeOptionsParts.append("--import \(ensureIpc)")
        }
        if let preload = NodeShim.preloadPath {
            nodeOptionsParts.append("--require \(preload)")
        }
        process.environment = [
            "NODE_OPTIONS": nodeOptionsParts.joined(separator: " "),
            "TERMX_INTERACTIVE": "1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "yes")
    }
}

extension HostNodeRuntime {
    static func resolveNodeBinaryForTests() -> String? {
        if let override = ProcessInfo.processInfo.environment["NODE_BINARY"] { return override }
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
