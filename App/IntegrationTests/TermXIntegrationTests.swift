import XCTest
@testable import TermXIntegration
import TermXCore
import TermXFiles
import TermXLinux

final class TermXIntegrationTests: XCTestCase {
    func testCompositionCreatesAllRuntimeServices() {
        let integration = TermXIntegration()
        XCTAssertEqual(integration.python.registryEntry["name"], "python3")
        XCTAssertEqual(integration.node.registryEntry["name"], "node")
        XCTAssertEqual(integration.linux.registryEntry["name"], "linux")
    }

    func testCoreEchoDispatchesThroughWriter() {
        let engine = TermXCommandEngine()
        let request = SpawnRequest(cmdline: "echo hello TermX", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: "/workspaces/demo", environment: [:], interactive: false)
        var output = ""
        XCTAssertEqual(engine.run(request) { output += $0 }, 0)
        XCTAssertEqual(output, "hello TermX\n")
    }

    func testLinuxPathMappingRejectsOutsideWorkspace() {
        let service = BlinkLinuxService()
        XCTAssertNoThrow(try service.mapHostPath("/workspaces/demo/file.txt"))
        XCTAssertThrowsError(try service.mapHostPath("/private/file.txt"))
    }

    func testWasmLaneRunsArbitraryWorkspaceModule() async throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // IntegrationTests
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // repo
        let workspace = repo.appendingPathComponent("External/TetherWasm/sample", isDirectory: true)
        let output = Pipe()
        let errors = Pipe()
        let service = TetherWasmService()

        let code = await service.run(
            argv: ["wasm", "hello.wasm"],
            hostCwd: workspace.path,
            environment: ["LANG": "C.UTF-8"],
            stdinFD: -1,
            stdoutFD: output.fileHandleForWriting.fileDescriptor,
            stderrFD: errors.fileHandleForWriting.fileDescriptor
        )
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(code, 0, stderr)
        XCTAssertTrue(stdout.contains("hello"), stdout)
    }

    func testWasmLaneCanCancelUntrustedModule() async throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = repo.appendingPathComponent("External/TetherWasm/sample", isDirectory: true)
        let service = TetherWasmService()
        let run = Task {
            await service.run(
                argv: ["wasm", "spin.wasm"],
                hostCwd: workspace.path,
                environment: [:],
                stdinFD: -1,
                stdoutFD: -1,
                stderrFD: -1
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        service.interrupt()
        let code = await run.value
        XCTAssertEqual(code, 130)
    }
}
