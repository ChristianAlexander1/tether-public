import Foundation
import XCTest
@testable import TermXNode

/// The v2 shim ships twice: as the standalone package under
/// `External/tether-shim-v2` (where its own `node --test` suite runs) and as a
/// copy inside the app bundle resources. A drift between them means the tests
/// pass against code the device never runs, so it is checked here.
final class ShimV2InstallationTests: XCTestCase {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TermXNode (tests)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // TermXNode
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    private static var sourceLib: URL {
        repoRoot.appendingPathComponent("External/tether-shim-v2/lib")
    }

    private static var bundledLib: URL {
        repoRoot.appendingPathComponent(
            "Packages/TermXNode/Sources/TermXNode/Resources/shim/v2/lib")
    }

    private func files(under root: URL) throws -> [String: Data] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let url as URL in walker where url.pathExtension == "js" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    func testBundledShimMatchesItsSourcePackageByteForByte() throws {
        let source = try files(under: Self.sourceLib)
        let bundled = try files(under: Self.bundledLib)
        XCTAssertFalse(source.isEmpty, "tether-shim-v2 source not found")
        XCTAssertEqual(
            Set(source.keys), Set(bundled.keys),
            "bundled shim file set differs from the source package"
        )
        for (name, bytes) in source {
            XCTAssertEqual(bundled[name], bytes, "\(name) differs between source and bundle")
        }
    }

    /// The defect this whole component exists to remove: v1 answered `isatty`
    /// for every fd from an environment flag. Nothing in v2 may consult it.
    func testShimV2NeverConsultsTheInteractiveEnvironmentFlag() throws {
        for (name, bytes) in try files(under: Self.bundledLib) {
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(
                text.contains("TETHER_INTERACTIVE") || text.contains("TERMX_INTERACTIVE"),
                "\(name) reintroduces environment-flag TTY faking"
            )
        }
    }

    func testV2PreloadEntryExistsAndDoesNotLoadTheV1TTYShim() throws {
        let entry = Self.repoRoot.appendingPathComponent(
            "Packages/TermXNode/Sources/TermXNode/Resources/shim/index.v2.js")
        let text = try String(contentsOf: entry, encoding: .utf8)
        XCTAssertTrue(text.contains("./v2/lib/index.js"), "v2 entry must install the v2 shim")
        XCTAssertFalse(
            text.contains("'tty'") || text.contains("'child_process'"),
            "the v2 entry must not map tty/child_process itself — v2 owns those"
        )
    }

    /// The engine process is persistent and the Swift side opens a fresh
    /// server socket per job, so the preload's one-shot auto-install can never
    /// cover a job on the engine lane. bootstrap.js is the component that
    /// opens the session per job and closes it in its reply path; if either
    /// call disappears, every job silently loses its TTY truth (the exact
    /// failure that made TUIs unexitable).
    func testBootstrapOpensAndClosesTheV2SessionPerJob() throws {
        let bootstrap = Self.repoRoot.appendingPathComponent(
            "Packages/TermXNode/Sources/TermXNode/Resources/shim/bootstrap.js")
        let text = try String(contentsOf: bootstrap, encoding: .utf8)
        XCTAssertTrue(
            text.contains("beginSession("),
            "bootstrap.js must open a v2 session per job — the preload cannot"
        )
        XCTAssertTrue(
            text.contains("endSession()"),
            "bootstrap.js must close the v2 session before replying"
        )
    }

    /// v1's newline-JSON client must never be pointed at a v2 framed server:
    /// the ensure-ipc import self-gates on the lane flag.
    func testEnsureIpcIsGatedToTheV1Lane() throws {
        let ensureIpc = Self.repoRoot.appendingPathComponent(
            "Packages/TermXNode/Sources/TermXNode/Resources/shim/ensure-ipc.mjs")
        let text = try String(contentsOf: ensureIpc, encoding: .utf8)
        XCTAssertTrue(
            text.contains("TETHER_IPC_V2"),
            "ensure-ipc.mjs must skip the v1 connect on the v2 lane"
        )
    }

    func testIPCVersionSelectionDrivesThePreloadPath() {
        // Guards the pairing that keeps Swift and bootstrap.js on one lane.
        let path = NodeShim.preloadPath ?? ""
        if NodeShim.useIPCv2 {
            XCTAssertTrue(path.hasSuffix("index.v2.js"))
        } else {
            XCTAssertTrue(path.hasSuffix("index.js"))
        }
    }
}
