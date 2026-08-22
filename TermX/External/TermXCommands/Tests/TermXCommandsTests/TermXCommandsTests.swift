import XCTest
@testable import TermXCommands

// Each test uses a stdin case and an error case. Expected values were derived
// from the real Unix tools (e.g. `md5sum`, `sha1sum`, `tac`, `rev`, `nl`,
// `base64`) run on macOS/Linux, and are noted in the comments.

final class TermXCommandsTests: XCTestCase {

    func io(_ argv: [String], stdin: String = "", cwd: String = "/tmp",
            env: [String: String] = [:]) -> CommandIO {
        return CommandIO(argv: argv, stdin: stdin, cwd: cwd, environment: env)
    }

    // MARK: tac — reverse lines (stdin + error case)

    func testTacStdin() {
        let r = TacCommand.run(io(["tac"], stdin: "a\nb\nc\n"))
        XCTAssertEqual(r.stdout, "c\nb\na\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    func testTacMissingFileError() {
        let r = TacCommand.run(io(["tac", "/no/such/file.txt"], cwd: "/tmp"))
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("No such file"))
    }

    // MARK: rev — reverse each line

    func testRevStdin() {
        // real: `rev` on "hello" -> "olleh"
        let r = RevCommand.run(io(["rev"], stdin: "hello\n"))
        XCTAssertEqual(r.stdout, "olleh\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    // MARK: nl — number lines (0 == line number from 1); real output "     1\ta"

    func testNlStdin() {
        let r = NlCommand.run(io(["nl"], stdin: "a\nb\nc\n"))
        XCTAssertEqual(r.stdout, "     1\ta\n     2\tb\n     3\tc\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    // MARK: base64 — encode (matches real `aGVsbG8=`)

    func testBase64Encode() {
        let r = Base64Command.run(io(["base64"], stdin: "hello"))
        XCTAssertEqual(r.stdout, "aGVsbG8=\n")
    }

    func testBase64Decode() {
        let r = Base64Command.run(io(["base64", "-d"], stdin: "aGVsbG8="))
        XCTAssertEqual(r.stdout, "hello")
    }

    // MARK: md5sum — expected from real `md5sum`

    func testMd5sumStdin() {
        let r = Md5sumCommand.run(io(["md5sum"], stdin: "hello"))
        XCTAssertEqual(r.stdout, "5d41402abc4b2a76b9719d911017c592  -\n")
    }

    func testShasum() {
        // sha1 of "hi\n" from real `sha1sum`
        let r = ShasumCommand.run(io(["shasum"], stdin: "hi\n"))
        XCTAssertEqual(r.stdout, "55ca6286e3e4f4fba5d0448333fa99fc5a404a73  -\n")
    }

    // MARK: printenv — variable present vs missing

    func testPrintenvPresent() {
        let r = PrintenvCommand.run(io(["printenv", "HOME"], env: ["HOME": "/home/u"]))
        XCTAssertEqual(r.stdout, "/home/u\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    func testPrintenvMissing() {
        let r = PrintenvCommand.run(io(["printenv", "DOES_NOT_EXIST"], env: [:]))
        XCTAssertEqual(r.exitCode, 1)
    }

    // MARK: registry dispatch

    func testRegistryLookup() {
        XCTAssertEqual(TermXCommandRegistry.command(named: "sed")?.name, "sed")
        XCTAssertEqual(TermXCommandRegistry.command(named: "awk")?.name, "awk")
        XCTAssertEqual(TermXCommandRegistry.command(named: "diff")?.name, "diff")
        XCTAssertNil(TermXCommandRegistry.command(named: "nosuchcmd"))
        XCTAssertTrue(TermXCommandRegistry.all.count >= 20)
    }

    // MARK: diff -q (exit code 0/1)

    func testDiffSame() {
        let dir = NSTemporaryDirectory()
        let a = dir + "/diff_same.txt"
        try? "same\n".write(toFile: a, atomically: true, encoding: .utf8)
        let r = DiffCommand.run(io(["diff", "-q", a, a], cwd: dir))
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "")
        try? FileManager.default.removeItem(atPath: a)
    }

    func testDiffDifferent() {
        let dir = NSTemporaryDirectory()
        let a = dir + "/diff_a.txt"
        let b = dir + "/diff_b.txt"
        try? "one\n".write(toFile: a, atomically: true, encoding: .utf8)
        try? "two\n".write(toFile: b, atomically: true, encoding: .utf8)
        let r = DiffCommand.run(io(["diff", "-q", a, b], cwd: dir))
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stdout.contains("differ"))
        try? FileManager.default.removeItem(atPath: a)
        try? FileManager.default.removeItem(atPath: b)
    }

    func testChmodUsageError() {
        let r = ChmodCommand.run(io(["chmod"], cwd: "/tmp"))
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("usage"))
    }

    func testChmodSymbolicAndOctal() {
        let dir = NSTemporaryDirectory()
        let f = dir + "/chmod_test.txt"
        try? "x".write(toFile: f, atomically: true, encoding: .utf8)
        // symbolic: u+x, go-w
        let r1 = ChmodCommand.run(io(["chmod", "u+x,go-w", f], cwd: dir))
        XCTAssertEqual(r1.exitCode, 0)
        // octal
        let r2 = ChmodCommand.run(io(["chmod", "700", f], cwd: dir))
        XCTAssertEqual(r2.exitCode, 0)
        let perms = (try? FileManager.default.attributesOfItem(atPath: f)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(perms & 0o700, 0o700)   // owner can rwx
        try? FileManager.default.removeItem(atPath: f)
    }

    func testStatFormat() {
        let f = NSTemporaryDirectory() + "/stat_test.txt"
        try? "hello".write(toFile: f, atomically: true, encoding: .utf8)
        let r = StatCommand.run(io(["stat", "-c", "size=%s", f], cwd: "/tmp"))
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("size=5"))
        try? FileManager.default.removeItem(atPath: f)
    }

    func testStatMissingFileError() {
        let r = StatCommand.run(io(["stat", "/no/such/stat.txt"], cwd: "/tmp"))
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertTrue(r.stderr.contains("No such file"))
    }

    func testPrintenvErrorCase() {
        // missing var -> exit 1 (error case)
        let r = PrintenvCommand.run(io(["printenv", "NO_SUCH_VAR"], env: [:]))
        XCTAssertEqual(r.exitCode, 1)
    }
}
