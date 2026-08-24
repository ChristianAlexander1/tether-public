import XCTest
@testable import TermXNode

final class NpmBootstrapTests: XCTestCase {
    func testPinnedVersionIsConcrete() {
        XCTAssertFalse(NpmBootstrap.pinnedVersion.isEmpty)
        XCTAssertTrue(NpmBootstrap.pinnedVersion.contains("."))
    }

    func testPathsUnderHome() {
        let home = "/data/home"
        XCTAssertEqual(NpmBootstrap.npmRoot(home: home),
                       "/data/home/node/lib/node_modules/npm")
        XCTAssertEqual(NpmBootstrap.cliPath(home: home, tool: "npm"),
                       "/data/home/node/lib/node_modules/npm/bin/npm-cli.js")
        XCTAssertEqual(NpmBootstrap.cliPath(home: home, tool: "npx"),
                       "/data/home/node/lib/node_modules/npm/bin/npx-cli.js")
    }

    func testIsInstalledRequiresCli() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("npm-boot-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }

        XCTAssertFalse(NpmBootstrap.isInstalled(home: root))

        let cli = NpmBootstrap.cliPath(home: root, tool: "npm")
        try fm.createDirectory(atPath: (cli as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try "#!/usr/bin/env node\n".write(toFile: cli, atomically: true, encoding: .utf8)
        XCTAssertTrue(NpmBootstrap.isInstalled(home: root))
    }
}

final class NodeEnvironmentTests: XCTestCase {
    func testMergeSetsNpmPrefixAndQuietDefaults() {
        let env = NodeEnvironment.merge(base: [:], cwd: "/work", home: "/data/home")
        XCTAssertEqual(env["HOME"], "/data/home")
        XCTAssertEqual(env["npm_config_prefix"], "/data/home/node")
        XCTAssertEqual(env["NODE_PATH"], "/data/home/node/lib/node_modules")
        XCTAssertEqual(env["PWD"], "/work")
        XCTAssertEqual(env["npm_config_update_notifier"], "false")
        XCTAssertEqual(env["npm_config_fund"], "false")
        XCTAssertEqual(env["npm_config_audit"], "false")
        XCTAssertEqual(env["npm_config_progress"], "false")
        XCTAssertEqual(env["TERMX_INTERACTIVE"], "0")
        XCTAssertEqual(env["npm_config_fetch_retries"], "2")
        XCTAssertEqual(env["npm_config_maxsockets"], "8")
    }

    func testMergeEnablesLiveNpmOutputWhenInteractive() {
        let env = NodeEnvironment.merge(base: [:], cwd: "/work", home: "/data/home", interactive: true)
        XCTAssertEqual(env["TERMX_INTERACTIVE"], "1")
        XCTAssertEqual(env["npm_config_progress"], "false")
        XCTAssertEqual(env["npm_config_loglevel"], "info")
    }

    func testMergePreservesCallerOverrides() {
        let env = NodeEnvironment.merge(
            base: ["npm_config_fund": "true", "HOME": "/custom"],
            cwd: "/work"
        )
        XCTAssertEqual(env["HOME"], "/custom")
        XCTAssertEqual(env["npm_config_fund"], "true")
        XCTAssertEqual(env["npm_config_prefix"], "/custom/node")
    }
}
