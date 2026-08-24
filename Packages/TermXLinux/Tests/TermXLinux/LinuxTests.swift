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
        XCTAssertThrowsError(try service.mapHostPath("/workspaces-other/demo"))
        XCTAssertThrowsError(try service.mapHostPath("/workspaces/../../etc/passwd"))
    }

    func testPathMappingRejectsSymlinkEscape() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaces = tmp.appendingPathComponent("workspaces")
        let outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspaces.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mapper = LinuxPathMapper(workspacesHostRoot: workspaces, homeHostRoot: tmp)
        XCTAssertThrowsError(try mapper.hostPath(forGuestPath: "/workspaces/escape/private"))
    }

    func testGuestEnvironmentIsGenericAndDoesNotForgeToolConfiguration() {
        let env = LinuxEnvironment.guestEnviron(cwd: "/work", interactive: true)
        XCTAssertEqual(env["USER"], "root")
        XCTAssertEqual(env["SHELL"], "/bin/sh")
        XCTAssertEqual(env["BROWSER"], "open")
        XCTAssertNil(env["HOSTNAME"])
        XCTAssertNil(env["GIT_AUTHOR_NAME"])
        XCTAssertNil(env["GIT_EDITOR"])
        XCTAssertNil(env["EMAIL"])
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

    func testDispatchManifestDefaults() {
        let manifest = GuestDispatchManifest.loadDefault()
        XCTAssertEqual(manifest.default, "guest_elf")
        XCTAssertTrue(manifest.isBrowserOpener("xdg-open"))
        XCTAssertEqual(manifest.hostHandler(for: "node"), "node-mobile")
        XCTAssertNil(manifest.hostHandler(for: "git"))
        XCTAssertTrue(manifest.launcherBasenames.contains("claude"))
        XCTAssertEqual(manifest.hostHandler(for: "wasm"), "wasm3")
        XCTAssertFalse(manifest.launcherBasenames.contains("git"))
    }

    func testRuntimeLaunchersMigrateOnlyGeneratedBusyBoxCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-launchers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        let busybox = root.appendingPathComponent("bin/busybox")
        try Data("real-busybox-fixture".utf8).write(to: busybox)
        let bin = root.appendingPathComponent("usr/local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: busybox, to: bin.appendingPathComponent("node"))
        try Data("user-owned-command".utf8).write(to: bin.appendingPathComponent("custom"))

        try GuestRuntimeLauncherInstaller.install(names: ["node", "custom", "wasm"], rootfs: root)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("node").path),
            "../../../bin/busybox"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("wasm").path),
            "../../../bin/busybox"
        )
        XCTAssertEqual(
            try String(contentsOf: bin.appendingPathComponent("custom"), encoding: .utf8),
            "user-owned-command"
        )
    }
}
