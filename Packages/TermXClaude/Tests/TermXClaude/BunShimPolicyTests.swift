import Foundation
import XCTest
@testable import TermXClaude

/// The Bun shim used to carry its own hardcoded list of opener names and
/// answered `Bun.which` for them with a fabricated `/usr/bin/<name>` path —
/// a third copy of a list that also lived in `SystemOpen` and the dispatch
/// manifest. These tests keep it from coming back.
final class BunShimPolicyTests: XCTestCase {
    private func shimSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TermXClaude (tests)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TermXClaude
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let shim = repoRoot.appendingPathComponent(
            "Packages/TermXClaude/Sources/TermXClaude/Resources/bun-shim.js")
        return try String(contentsOf: shim, encoding: .utf8)
    }

    /// Every name in the manifest's opener list, plus the browser names the old
    /// shim invented. None may appear as a literal in the shim.
    private static let forbiddenCommandLiterals = [
        "xdg-open", "gnome-open", "kde-open", "sensible-browser", "wslview",
        "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
        "/usr/bin/open",
    ]

    func testShimContainsNoOpenerCommandLiterals() throws {
        let source = try shimSource()
        for literal in Self.forbiddenCommandLiterals {
            XCTAssertFalse(
                source.contains(literal),
                "bun-shim.js reintroduced the command-name literal '\(literal)'; "
                    + "opener names belong only in tether_dispatch_manifest.json"
            )
        }
    }

    func testShimResolvesTheOpenerFromTheEnvironmentTheHostSets() throws {
        let source = try shimSource()
        XCTAssertTrue(
            source.contains("TETHER_OPENER"),
            "the opener must be named by the host, not chosen by the shim"
        )
    }

    func testShimDelegatesTheBunSurfaceToTheCompatLibrary() throws {
        let source = try shimSource()
        XCTAssertTrue(source.contains("installBunGlobal"))
        XCTAssertTrue(source.contains("bun-compat/lib/index.js"))
    }

    /// `which` must actually scan; a hand-rolled answer is what made it lie.
    func testShimDoesNotDefineItsOwnWhich() throws {
        let source = try shimSource()
        XCTAssertFalse(
            source.contains("which(cmd)"),
            "Bun.which must come from tether-bun-compat's real PATH scan"
        )
    }

    /// The compat library must ship beside the shim or its require fails at
    /// runtime, which no unit test of the Swift side would otherwise catch.
    func testCompatLibraryIsPresentInTheResourceBundle() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let index = repoRoot.appendingPathComponent(
            "Packages/TermXClaude/Sources/TermXClaude/Resources/bun-compat/lib/index.js")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: index.path),
            "bun-compat must be bundled with the launcher assets"
        )
    }

    func testLaunchEnvironmentTakesTheOpenerNameFromTheHost() {
        ClaudeCodeService.platformOpenerName = "open"
        let env = ClaudeCodeService.launchEnvironment(base: [:])
        XCTAssertEqual(env["TETHER_OPENER"], "open")

        ClaudeCodeService.platformOpenerName = "xdg-open"
        let other = ClaudeCodeService.launchEnvironment(base: [:])
        XCTAssertEqual(other["TETHER_OPENER"], "xdg-open",
                       "the name must follow the manifest, not a constant")
    }
}
