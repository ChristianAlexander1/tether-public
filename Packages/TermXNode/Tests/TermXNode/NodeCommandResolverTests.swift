import XCTest
@testable import TermXNode

/// Regression: `npm --version` ran runMain("--version"), bare `npm`/`node`
/// crashed with "paths[0] must be of type string", and `claude` was never
/// resolved to its installed cli.js.
final class NodeCommandResolverTests: XCTestCase {
    private let home = "/data/home"

    func testNodePassesThrough() {
        let r = NodeCommandResolver.resolve(argv: ["node", "app.js", "x"], home: home) { _ in false }
        XCTAssertEqual(r, .run(["node", "app.js", "x"]))
    }

    func testNpmRewritesToCli() {
        let cli = "/data/home/node/lib/node_modules/npm/bin/npm-cli.js"
        let r = NodeCommandResolver.resolve(argv: ["npm", "--version"], home: home) { $0 == cli }
        XCTAssertEqual(r, .run(["node", cli, "--version"]))
    }

    func testNpxRewritesToItsOwnCli() {
        let cli = "/data/home/node/lib/node_modules/npm/bin/npx-cli.js"
        let r = NodeCommandResolver.resolve(argv: ["npx", "cowsay", "hi"], home: home) { $0 == cli }
        XCTAssertEqual(r, .run(["node", cli, "cowsay", "hi"]))
    }

    func testNpmWithoutInstallAsksForBootstrap() {
        let r = NodeCommandResolver.resolve(argv: ["npm", "install", "x"], home: home) { _ in false }
        XCTAssertEqual(r, .needsNpm(tool: "npm"))
    }

    func testInstalledBinResolves() throws {
        // Real symlink: $HOME/node/bin/claude -> ../lib/node_modules/pkg/cli.js
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "resolver-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let pkg = root + "/node/lib/node_modules/pkg"
        try fm.createDirectory(atPath: pkg, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/node/bin", withIntermediateDirectories: true)
        try "#!/usr/bin/env node\n".write(toFile: pkg + "/cli.js", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root + "/node/bin/claude",
                                  withDestinationPath: "../lib/node_modules/pkg/cli.js")

        let r = NodeCommandResolver.resolve(argv: ["claude", "login"], home: root)
        guard case .run(let argv) = r else { return XCTFail("expected .run, got \(r)") }
        XCTAssertEqual(argv.first, "node")
        XCTAssertTrue(argv[1].hasSuffix("/node/lib/node_modules/pkg/cli.js"))
        XCTAssertEqual(argv[2], "login")
    }

    func testUnknownBinIsNotFound() {
        let r = NodeCommandResolver.resolve(argv: ["claude"], home: home) { _ in false }
        XCTAssertEqual(r, .notFound("claude"))
    }
}
