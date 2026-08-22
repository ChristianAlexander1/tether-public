import XCTest
@testable import TermXCore

final class TermXCoreTests: XCTestCase {
    func testTokenizerHandlesQuotesAndEscapes() { XCTAssertEqual(ShellTokenizer.tokenize("echo 'hello world' a\\ b"), ["echo", "hello world", "a b"]) }
    func testDefaultEnvironment() { let env = TermXCommandEngine.defaultEnvironment(home: "/tmp/home"); XCTAssertEqual(env["HOME"], "/tmp/home"); XCTAssertTrue(env["PATH"]!.contains("/tmp/home/node/bin")) }
    func testBuiltinsPipelineAndRedirect() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("termx-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TermXCommandEngine(); let result = try await engine.execute("echo alpha beta | grep beta > result.txt", cwd: root.path)
        XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8), "alpha beta\n")
    }
    func testFilesystemCommands() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("termx-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TermXCommandEngine(); _ = try await engine.execute("touch a.txt", cwd: root.path); _ = try await engine.execute("echo hello > a.txt", cwd: root.path); let result = try await engine.execute("cat a.txt", cwd: root.path); XCTAssertEqual(result.output, "hello\n")
    }
}
