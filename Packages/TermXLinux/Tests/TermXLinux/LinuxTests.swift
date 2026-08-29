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

    func testGuestWorkPathRewrite() {
        XCTAssertEqual(GuestWorkPath.hostPath("/work", workspace: "/Users/me/proj"), "/Users/me/proj")
        XCTAssertEqual(GuestWorkPath.hostPath("/work/src", workspace: "/Users/me/proj"), "/Users/me/proj/src")
        XCTAssertEqual(GuestWorkPath.hostPath("/tmp/x", workspace: "/Users/me/proj"), "/tmp/x")
        XCTAssertFalse(GuestWorkPath.isGuest("/workish"))
        XCTAssertEqual(GuestWorkPath.guestPath("/Users/me/proj/src", workspace: "/Users/me/proj"), "/work/src")
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

    func testGuestEnvironmentIncludesWindowSizeWhenProvided() {
        let env = LinuxEnvironment.guestEnviron(cwd: "/work", interactive: true, cols: 48, rows: 34)
        XCTAssertEqual(env["COLUMNS"], "48")
        XCTAssertEqual(env["LINES"], "34")
    }

    func testInvalidateRootfsWhenBusyboxMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rootfs = tmp.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)
        let service = BlinkLinuxService(
            rootfs: rootfs,
            workspacesHostRoot: tmp.appendingPathComponent("workspaces")
        )
        // Simulate a previously ready service whose Storage entry was deleted.
        try Data("ok".utf8).write(to: rootfs.appendingPathComponent(".tether-bootstrapped"))
        service.markNeedsBootstrap()
        XCTAssertEqual(service.state, .needsBootstrap)
        XCTAssertFalse(service.hasRootfs)
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
        XCTAssertEqual(manifest.hostHandler(for: "python3"), "python-embedded")
        XCTAssertEqual(manifest.hostHandler(for: "python"), "python-embedded")
        XCTAssertEqual(manifest.hostHandler(for: "pip3"), "python-embedded")
        XCTAssertEqual(manifest.hostHandler(for: "pip"), "python-embedded")
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

    func testAlpineBootstrapSkipsOnlyWhenBusyboxPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: root.appendingPathComponent(".tether-bootstrapped"))
        // Marker alone must not count as bootstrapped — Storage can leave a marker-less empty dir,
        // or delete busybox while leaving the marker.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("bin/busybox").path)
        )
    }

    func testRootfsLayoutDetectsFakefsIndexAndExtractedTrees() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let extracted = tmp.appendingPathComponent("extracted", isDirectory: true)
        let store = tmp.appendingPathComponent("fakefs", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        XCTAssertEqual(LinuxRootfsLayout.detect(at: extracted), .extracted)
        try Data("TFAKEFS1".utf8).write(to: store.appendingPathComponent("tetherfs.idx"))
        XCTAssertEqual(LinuxRootfsLayout.detect(at: store), .fakefsStore)
    }

    /// Catches the TETHER_LINK_BLINK=1 + xcframework stub: if the env asks
    /// for the real bridge, `termx_blink_is_available` must not be the stub.
    func testLinkBlinkCompilesTheRealBridgeNotTheStub() throws {
        let env = ProcessInfo.processInfo.environment
        let requested = env["TETHER_LINK_BLINK"] == "1" || env["TERMX_LINK_BLINK"] == "1"
        guard requested else { return }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: BlinkPaths.hostArchive),
            "TETHER_LINK_BLINK=1 requires \(BlinkPaths.hostArchive) (Frameworks/build-blink.sh)"
        )
        XCTAssertTrue(
            BlinkEmbed.isAvailable,
            "TETHER_LINK_BLINK=1 compiled TERMX_BLINK_STUB; macOS must link blink.a independently of Blink.xcframework"
        )
    }

    /// `Package.swift` names the host archive as a string literal and
    /// `build-blink.sh` installs it somewhere else entirely; nothing linked the
    /// two, so the manifest pointed at a path the script never created and the
    /// TETHER_LINK_BLINK lane silently linked nothing. Assert they agree.
    func testManifestAndBuildScriptAgreeOnTheHostArchivePath() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TermXLinux (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TermXLinux (package)
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root

        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/TermXLinux/Package.swift"),
            encoding: .utf8
        )
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("Frameworks/build-blink.sh"),
            encoding: .utf8
        )

        // The directory the manifest expects the archive in, relative to Frameworks/.
        XCTAssertTrue(
            manifest.contains(#".build/host/blink.a"#),
            "Package.swift must point blinkLib at .build/host/blink.a — the directory build-blink.sh installs into"
        )
        // The directory the script actually installs into.
        XCTAssertTrue(
            script.contains(#"cp o/rel/blink/blink.a "$BUILD/host/""#),
            "build-blink.sh must install blink.a into $BUILD/host/; if this moved, update Package.swift and BlinkPaths together"
        )
        XCTAssertTrue(
            BlinkPaths.hostArchive.hasSuffix("/.build/host/blink.a"),
            "BlinkPaths.hostArchive drifted from the manifest and the build script"
        )
    }
}
