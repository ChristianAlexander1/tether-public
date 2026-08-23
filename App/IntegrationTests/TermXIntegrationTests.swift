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
}
