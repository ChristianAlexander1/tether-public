import XCTest
@testable import TermXLinux

final class LinuxTests: XCTestCase {
    func testInitialStateAndPathMapping() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = BlinkLinuxService(
            rootfs: tmp.appendingPathComponent("rootfs"),
            workspacesHostRoot: tmp.appendingPathComponent("workspaces")
        )
        XCTAssertEqual(service.state, .needsBootstrap)
        XCTAssertNoThrow(try service.mapHostPath("/workspaces/demo"))
        XCTAssertThrowsError(try service.mapHostPath("/etc/passwd"))
    }

    func testRegistryManifest() {
        XCTAssertEqual(BlinkLinuxService().registryEntry["name"], "linux")
        XCTAssertEqual(BlinkLinuxService().registryEntry["kind"], "linux")
    }

    func testAlpineCDNURL() {
        let url = AlpineBootstrap.cdnURL()
        XCTAssertTrue(url.absoluteString.contains("alpine-minirootfs"))
        XCTAssertTrue(url.absoluteString.contains("dl-cdn.alpinelinux.org"))
    }
}
