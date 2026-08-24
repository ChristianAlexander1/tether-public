import XCTest
import Foundation
@testable import TetherCommands

final class TetherCommandsTests: XCTestCase {
    private func io(_ argv: [String], stdin: String = "", cwd: String = FileManager.default.currentDirectoryPath, env: [String: String] = [:]) -> CommandIO {
        CommandIO(argv: argv, stdin: stdin, cwd: cwd, environment: env)
    }

    private func temporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("TetherCommandsTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func write(_ text: String, named name: String, in directory: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    // xargs
    func testXargsEchoesWords() { XCTAssertEqual(XargsCommand.run(io(["xargs"], stdin: "a b\n")).stdout, "a b\n") }
    func testXargsMaxArguments() { XCTAssertEqual(XargsCommand.run(io(["xargs", "-n", "1", "echo"], stdin: "a b")).stdout, "a\nb\n") }

    // tee
    func testTeeCopiesStandardInput() throws {
        let dir = try temporaryDirectory(), result = TeeCommand.run(io(["tee", "out"], stdin: "hello", cwd: dir))
        XCTAssertEqual(result.stdout, "hello"); XCTAssertEqual(try String(contentsOfFile: dir + "/out", encoding: .utf8), "hello")
    }
    func testTeeAppends() throws {
        let dir = try temporaryDirectory(); try write("a", named: "out", in: dir)
        _ = TeeCommand.run(io(["tee", "-a", "out"], stdin: "b", cwd: dir))
        XCTAssertEqual(try String(contentsOfFile: dir + "/out", encoding: .utf8), "ab")
    }

    // cut
    func testCutFieldT1() { XCTAssertEqual(CutCommand.run(io(["cut", "-d", ":", "-f", "1"], stdin: "a:b\n")).stdout, "a\n") }
    func testCutCharacters() { XCTAssertEqual(CutCommand.run(io(["cut", "-c", "2-4"], stdin: "abcde\n")).stdout, "bcd\n") }

    // tr
    func testTrRangesT2() { XCTAssertEqual(TrCommand.run(io(["tr", "a-z", "A-Z"], stdin: "hi")).stdout, "HI") }
    func testTrDeletes() { XCTAssertEqual(TrCommand.run(io(["tr", "-d", "0-9"], stdin: "a1b2")).stdout, "ab") }

    // uniq
    func testUniqAdjacentLines() { XCTAssertEqual(UniqCommand.run(io(["uniq"], stdin: "a\na\nb\n")).stdout, "a\nb\n") }
    func testUniqCounts() { XCTAssertEqual(UniqCommand.run(io(["uniq", "-c"], stdin: "a\na\n")).stdout, "      2 a\n") }

    // sort
    func testSortReverseT4() { XCTAssertEqual(SortCommand.run(io(["sort", "-r"], stdin: "a\nc\nb\n")).stdout, "c\nb\na\n") }
    func testSortNumeric() { XCTAssertEqual(SortCommand.run(io(["sort", "-n"], stdin: "10\n2\n")).stdout, "2\n10\n") }

    // which
    func testWhichFindsExecutable() throws {
        let dir = try temporaryDirectory(); try write("x", named: "tool", in: dir); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/tool")
        XCTAssertEqual(WhichCommand.run(io(["which", "tool"], cwd: dir, env: ["PATH": dir])).stdout, dir + "/tool\n")
    }
    func testWhichMissing() { XCTAssertEqual(WhichCommand.run(io(["which", "definitely-not-here"], env: ["PATH": "/none"])).exitCode, 1) }

    // type
    func testTypeKnowsBuiltin() { XCTAssertEqual(TypeCommand.run(io(["type", "echo"])).stdout, "echo is a Tether command\n") }
    func testTypeMissing() { XCTAssertEqual(TypeCommand.run(io(["type", "not-a-command"], env: ["PATH": "/none"])).exitCode, 1) }

    // test
    func testFileMissingT3() throws { XCTAssertEqual(TestCommand.run(io(["test", "-f", "missing"], cwd: try temporaryDirectory())).exitCode, 1) }
    func testIntegerComparison() { XCTAssertEqual(TestCommand.run(io(["test", "5", "-gt", "2"])).exitCode, 0) }

    // env
    func testEnvEmpty() { XCTAssertEqual(EnvCommand.run(io(["env", "-i"])).stdout, "") }
    func testEnvSetsForCommand() { XCTAssertEqual(EnvCommand.run(io(["env", "A=one", "printenv", "A"])).stdout, "one\n") }

    // printenv
    func testPrintenvValue() { XCTAssertEqual(PrintenvCommand.run(io(["printenv", "A"], env: ["A": "one"])).stdout, "one\n") }
    func testPrintenvMissing() { XCTAssertEqual(PrintenvCommand.run(io(["printenv", "B"], env: ["A": "one"])).exitCode, 1) }

    // id
    func testIdUserNumber() { XCTAssertEqual(IdCommand.run(io(["id", "-u"])).exitCode, 0); XCTAssertNotNil(Int(IdCommand.run(io(["id", "-u"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines))) }
    func testIdDefault() { XCTAssertTrue(IdCommand.run(io(["id"])).stdout.hasPrefix("uid=")) }

    // whoami
    func testWhoamiIgnoresSpoofedEnvironment() { XCTAssertEqual(WhoamiCommand.run(io(["whoami"], env: ["USER": "alice"])).stdout, WhoamiCommand.run(io(["whoami"])).stdout) }
    func testWhoamiSystemLookup() { XCTAssertEqual(WhoamiCommand.run(io(["whoami"])).exitCode, 0) }

    // uname
    func testUnameSystem() { XCTAssertFalse(UnameCommand.run(io(["uname"])).stdout.isEmpty) }
    func testUnameMachine() { XCTAssertTrue(["x86_64\n", "arm64\n", "unknown\n"].contains(UnameCommand.run(io(["uname", "-m"])).stdout)) }

    // date
    func testDateEpochYearUTC() { XCTAssertEqual(DateCommand.run(io(["date", "-u", "-r", "0", "+%Y"])).stdout, "1970\n") }
    func testDateCustomFormat() { XCTAssertEqual(DateCommand.run(io(["date", "-u", "-r", "0", "+%Y-%m-%d"])).stdout, "1970-01-01\n") }

    // split
    func testSplitLines() throws {
        let dir = try temporaryDirectory(); let result = SplitCommand.run(io(["split", "-l", "1", "-", "part"], stdin: "a\nb\n", cwd: dir))
        XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(try String(contentsOfFile: dir + "/partaa", encoding: .utf8), "a\n"); XCTAssertEqual(try String(contentsOfFile: dir + "/partab", encoding: .utf8), "b\n")
    }
    func testSplitBytes() throws {
        let dir = try temporaryDirectory(); _ = SplitCommand.run(io(["split", "-b", "2", "-", "p"], stdin: "abc", cwd: dir))
        XCTAssertEqual(try String(contentsOfFile: dir + "/paa", encoding: .utf8), "ab")
    }

    // paste
    func testPasteColumns() throws {
        let dir = try temporaryDirectory(); try write("a\nb\n", named: "one", in: dir); try write("1\n2\n", named: "two", in: dir)
        XCTAssertEqual(PasteCommand.run(io(["paste", "one", "two"], cwd: dir)).stdout, "a\t1\nb\t2\n")
    }
    func testPasteSerial() { XCTAssertEqual(PasteCommand.run(io(["paste", "-s", "-d", ",", "-"], stdin: "a\nb\n")).stdout, "a,b\n") }

    // join
    func testJoinDefaultField() throws {
        let dir = try temporaryDirectory(); try write("1 a\n2 b\n", named: "a", in: dir); try write("1 x\n3 y\n", named: "b", in: dir)
        XCTAssertEqual(JoinCommand.run(io(["join", "a", "b"], cwd: dir)).stdout, "1 a x\n")
    }
    func testJoinCustomSeparator() throws {
        let dir = try temporaryDirectory(); try write("1:a\n", named: "a", in: dir); try write("1:x\n", named: "b", in: dir)
        XCTAssertEqual(JoinCommand.run(io(["join", "-t", ":", "a", "b"], cwd: dir)).stdout, "1:a:x\n")
    }

    // od
    func testOdHex() { XCTAssertTrue(OdCommand.run(io(["od", "-An", "-x"], stdin: "A")).stdout.contains("41")) }
    func testOdOctal() { XCTAssertTrue(OdCommand.run(io(["od"], stdin: "A")).stdout.contains("101")) }

    // strings
    func testStringsExtractsPrintableRuns() { XCTAssertEqual(StringsCommand.run(io(["strings", "-n", "3"], stdin: "abc\0xy\0long")).stdout, "abc\nlong\n") }
    func testStringsMinimumLength() { XCTAssertEqual(StringsCommand.run(io(["strings", "-5"], stdin: "four\0five5")).stdout, "five5\n") }

    // file
    func testFileDirectory() throws { let dir = try temporaryDirectory(); XCTAssertTrue(FileCommand.run(io(["file", "-b", "."], cwd: dir)).stdout.contains("directory")) }
    func testFileUTF8Text() throws { let dir = try temporaryDirectory(); try write("hello\n", named: "text", in: dir); XCTAssertTrue(FileCommand.run(io(["file", "text"], cwd: dir)).stdout.contains("UTF-8 text")) }

    // stat
    func testStatSizeFormat() throws { let dir = try temporaryDirectory(); try write("hello", named: "f", in: dir); XCTAssertEqual(StatCommand.run(io(["stat", "-c", "%s", "f"], cwd: dir)).stdout, "5\n") }
    func testStatMissing() throws { XCTAssertEqual(StatCommand.run(io(["stat", "missing"], cwd: try temporaryDirectory())).exitCode, 1) }

    // readlink
    func testReadlinkTarget() throws { let dir = try temporaryDirectory(); try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "target"); XCTAssertEqual(ReadlinkCommand.run(io(["readlink", "link"], cwd: dir)).stdout, "target\n") }
    func testReadlinkNotLink() throws { let dir = try temporaryDirectory(); try write("x", named: "f", in: dir); XCTAssertEqual(ReadlinkCommand.run(io(["readlink", "f"], cwd: dir)).exitCode, 1) }

    // realpath
    func testRealpathExisting() throws { let dir = try temporaryDirectory(); XCTAssertEqual(RealpathCommand.run(io(["realpath", "."], cwd: dir)).stdout, dir + "\n") }
    func testRealpathMissingAllowed() throws { let dir = try temporaryDirectory(); XCTAssertEqual(RealpathCommand.run(io(["realpath", "-m", "a/../b"], cwd: dir)).stdout, dir + "/b\n") }

    // basename
    func testBasenameT5() { XCTAssertEqual(BasenameCommand.run(io(["basename", "/a/b/c"])).stdout, "c\n") }
    func testBasenameSuffix() { XCTAssertEqual(BasenameCommand.run(io(["basename", "file.txt", ".txt"])).stdout, "file\n") }

    // dirname
    func testDirnamePath() { XCTAssertEqual(DirnameCommand.run(io(["dirname", "/a/b/c"])).stdout, "/a/b\n") }
    func testDirnameBareName() { XCTAssertEqual(DirnameCommand.run(io(["dirname", "file"])).stdout, ".\n") }

    // mktemp
    func testMktempFile() throws { let dir = try temporaryDirectory(); let result = MktempCommand.run(io(["mktemp", "item.XXX"], cwd: dir)); XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(FileManager.default.fileExists(atPath: result.stdout.trimmingCharacters(in: .newlines))) }
    func testMktempDirectory() throws { let dir = try temporaryDirectory(); let result = MktempCommand.run(io(["mktemp", "-d", "dir.XXX"], cwd: dir)); var isDir: ObjCBool = false; XCTAssertTrue(FileManager.default.fileExists(atPath: result.stdout.trimmingCharacters(in: .newlines), isDirectory: &isDir)); XCTAssertTrue(isDir.boolValue) }

    // ln
    func testLnHardLink() throws { let dir = try temporaryDirectory(); try write("x", named: "source", in: dir); XCTAssertEqual(LnCommand.run(io(["ln", "source", "target"], cwd: dir)).exitCode, 0); XCTAssertEqual(try String(contentsOfFile: dir + "/target", encoding: .utf8), "x") }
    func testLnSymbolicLink() throws { let dir = try temporaryDirectory(); try write("x", named: "source", in: dir); XCTAssertEqual(LnCommand.run(io(["ln", "-s", "source", "target"], cwd: dir)).exitCode, 0); XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/target"), "source") }

    // du
    func testDuBytes() throws { let dir = try temporaryDirectory(); try write("hello", named: "f", in: dir); XCTAssertEqual(DuCommand.run(io(["du", "-b", "f"], cwd: dir)).stdout, "5\tf\n") }
    func testDuMissing() throws { XCTAssertEqual(DuCommand.run(io(["du", "missing"], cwd: try temporaryDirectory())).exitCode, 1) }

    // sleep
    func testSleepZero() { XCTAssertEqual(SleepCommand.run(io(["sleep", "0"])).exitCode, 0) }
    func testSleepInvalid() { XCTAssertEqual(SleepCommand.run(io(["sleep", "bad"])).exitCode, 2) }

    // timeout
    func testTimeoutTrue() { XCTAssertEqual(TimeoutCommand.run(io(["timeout", "1", "true"])).exitCode, 0) }
    func testTimeoutSleep() { XCTAssertEqual(TimeoutCommand.run(io(["timeout", "0", "sleep", "1"])).exitCode, 124) }

    // yes
    func testYesCount() { XCTAssertEqual(YesCommand.run(io(["yes", "-n", "2", "ok"])).stdout, "ok\nok\n") }
    func testYesDefaultWord() { XCTAssertEqual(YesCommand.run(io(["yes", "-n", "1"])).stdout, "y\n") }

    // seq
    func testSeqSimple() { XCTAssertEqual(SeqCommand.run(io(["seq", "3"])).stdout, "1\n2\n3\n") }
    func testSeqDescending() { XCTAssertEqual(SeqCommand.run(io(["seq", "3", "-1", "1"])).stdout, "3\n2\n1\n") }

    // expr
    func testExprAdds() { XCTAssertEqual(ExprCommand.run(io(["expr", "2", "+", "3"])).stdout, "5\n") }
    func testExprPrecedence() { XCTAssertEqual(ExprCommand.run(io(["expr", "2", "+", "3", "*", "4"])).stdout, "14\n") }

    // printf
    func testPrintfStringAndInteger() { XCTAssertEqual(PrintfCommand.run(io(["printf", "%s:%d\\n", "age", "7"])).stdout, "age:7\n") }
    func testPrintfRepeatsFormat() { XCTAssertEqual(PrintfCommand.run(io(["printf", "%s ", "a", "b"])).stdout, "a b ") }

    // echo
    func testEchoWords() { XCTAssertEqual(EchoCommand.run(io(["echo", "a", "b"])).stdout, "a b\n") }
    func testEchoNoNewline() { XCTAssertEqual(EchoCommand.run(io(["echo", "-n", "x"])).stdout, "x") }

    // true
    func testTrueSuccess() { XCTAssertEqual(TrueCommand.run(io(["true"])).exitCode, 0) }
    func testTrueIgnoresOperands() { XCTAssertEqual(TrueCommand.run(io(["true", "anything"])).exitCode, 0) }

    // false
    func testFalseFailure() { XCTAssertEqual(FalseCommand.run(io(["false"])).exitCode, 1) }
    func testFalseIgnoresOperands() { XCTAssertEqual(FalseCommand.run(io(["false", "anything"])).exitCode, 1) }

    // pwd
    func testPwdLogical() { XCTAssertEqual(PwdCommand.run(io(["pwd"], cwd: "/tmp/example")).stdout, "/tmp/example\n") }
    func testPwdInvalidOption() { XCTAssertEqual(PwdCommand.run(io(["pwd", "-z"])).exitCode, 2) }

    // cat
    func testCatStandardInput() { XCTAssertEqual(CatCommand.run(io(["cat"], stdin: "hello")).stdout, "hello") }
    func testCatFile() throws { let dir = try temporaryDirectory(); try write("hello", named: "f", in: dir); XCTAssertEqual(CatCommand.run(io(["cat", "f"], cwd: dir)).stdout, "hello") }

    // wc
    func testWcLines() { XCTAssertEqual(WcCommand.run(io(["wc", "-l"], stdin: "a\nb\n")).stdout, "2\n") }
    func testWcWords() { XCTAssertEqual(WcCommand.run(io(["wc", "-w"], stdin: "one two\nthree")).stdout, "3\n") }

    // integration
    func testIntegrationRegistryHasFortyPlusCommands() { XCTAssertGreaterThanOrEqual(TetherCommandRegistry.all.count, 40) }
    func testIntegrationCutThenTranslate() {
        let cut = CutCommand.run(io(["cut", "-d", ":", "-f", "1"], stdin: "alice:x\nbob:y\n"))
        let translated = TrCommand.run(io(["tr", "a-z", "A-Z"], stdin: cut.stdout))
        XCTAssertEqual(translated.stdout, "ALICE\nBOB\n")
    }
    func testIntegrationXargsInvokesPrintf() { XCTAssertEqual(XargsCommand.run(io(["xargs", "-n", "1", "printf", "<%s>\\n"], stdin: "a b")).stdout, "<a>\n<b>\n") }
    func testIntegrationEnvInvokesPrintenv() { XCTAssertEqual(EnvCommand.run(io(["env", "-i", "COLOR=blue", "printenv", "COLOR"], env: ["OLD": "x"])).stdout, "blue\n") }


    // Final-audit regressions
    func testAuditCutPreservesSelectedEmptyField() {
        XCTAssertEqual(CutCommand.run(io(["cut", "-d", ":", "-f", "1"], stdin: ":b\n")).stdout, "\n")
    }

    func testAuditTrSqueezesWithoutTranslation() {
        XCTAssertEqual(TrCommand.run(io(["tr", "-s", "a"], stdin: "baaaac")).stdout, "bac")
    }

    func testAuditBracketTestInvocation() {
        XCTAssertEqual(TestCommand.run(io(["[", "5", "-gt", "2", "]"])).exitCode, 0)
    }

    func testAuditXargsRejectsZeroGroupSize() {
        XCTAssertEqual(XargsCommand.run(io(["xargs", "-n", "0"], stdin: "a")).exitCode, 2)
    }

    func testAuditSeqAcceptsNegativeFirstOperand() {
        XCTAssertEqual(SeqCommand.run(io(["seq", "-2", "0"])).stdout, "-2\n-1\n0\n")
    }

    func testAuditSplitPreservesBinaryFileBytes() throws {
        let dir = try temporaryDirectory()
        try Data([0, 255, 1]).write(to: URL(fileURLWithPath: dir + "/input"))
        XCTAssertEqual(SplitCommand.run(io(["split", "-b", "2", "input", "part"], cwd: dir)).exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/partaa")), Data([0, 255]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/partab")), Data([1]))
    }

    func testAuditOdReadsBinaryFiles() throws {
        let dir = try temporaryDirectory()
        try Data([0, 255]).write(to: URL(fileURLWithPath: dir + "/binary"))
        XCTAssertTrue(OdCommand.run(io(["od", "-An", "-x", "binary"], cwd: dir)).stdout.contains("00 ff"))
    }

    func testAuditDuSummarizeSuppressesChildRows() throws {
        let dir = try temporaryDirectory()
        try FileManager.default.createDirectory(atPath: dir + "/child", withIntermediateDirectories: true)
        try write("x", named: "child/file", in: dir)
        let detailed = DuCommand.run(io(["du", "."], cwd: dir)).stdout.split(separator: "\n")
        let summary = DuCommand.run(io(["du", "-s", "."], cwd: dir)).stdout.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(detailed.count, 2)
        XCTAssertEqual(summary.count, 1)
    }

    func testAuditLnUsesBasenameInsideTargetDirectory() throws {
        let dir = try temporaryDirectory()
        try write("x", named: "source", in: dir)
        try FileManager.default.createDirectory(atPath: dir + "/links", withIntermediateDirectories: true)
        XCTAssertEqual(LnCommand.run(io(["ln", "source", "links"], cwd: dir)).exitCode, 0)
        XCTAssertEqual(try String(contentsOfFile: dir + "/links/source", encoding: .utf8), "x")
    }

    func testAuditWcReportsReadErrorsOnStderr() throws {
        let result = WcCommand.run(io(["wc", "missing"], cwd: try temporaryDirectory()))
        XCTAssertEqual(result.stdout, "")
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertEqual(result.exitCode, 1)
    }

    func testAuditDatePreservesLiteralText() {
        XCTAssertEqual(DateCommand.run(io(["date", "-u", "-r", "0", "+year=%Y"])).stdout, "year=1970\n")
    }

    func testAuditEnvAcceptsOptionsInSequence() {
        let result = EnvCommand.run(io(["env", "-u", "OLD", "-i", "A=one", "printenv", "A"], env: ["OLD": "x"]))
        XCTAssertEqual(result.stdout, "one\n")
    }

    func testAuditWhichRejectsDirectories() throws {
        let dir = try temporaryDirectory()
        try FileManager.default.createDirectory(atPath: dir + "/folder", withIntermediateDirectories: true)
        XCTAssertEqual(WhichCommand.run(io(["which", "folder"], cwd: dir, env: ["PATH": dir])).exitCode, 1)
    }

    func testAuditYesRejectsInvalidCount() {
        XCTAssertEqual(YesCommand.run(io(["yes", "-n", "bad"])).exitCode, 2)
    }
}
