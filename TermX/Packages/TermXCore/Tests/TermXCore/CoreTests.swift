import XCTest
@testable import TermXCore
import TermXShellLang

final class CoreTests: XCTestCase {

    // MARK: - Shell Lexer Tests

    func testLexerHandlesQuotesAndEscapes() {
        XCTAssertEqual(ShellLexer.lex("echo 'hello world' a\\ b"), ["echo", "hello world", "a b"])
        XCTAssertEqual(ShellLexer.lex(""), [])
        XCTAssertEqual(ShellLexer.lex("   "), [])
        XCTAssertEqual(ShellLexer.lex("cmd \"nested 'quotes'\""), ["cmd", "nested 'quotes'"])
        XCTAssertEqual(ShellLexer.lex("a\\\\b"), ["a\\b"])
        XCTAssertEqual(ShellLexer.lex("foo=\"bar baz\" qux"), ["foo=bar baz", "qux"])
    }

    // MARK: - Shell Parser Tests

    func testParserSimpleCommand() {
        let ast = ShellParser.parse("echo hello world")
        guard case .simple(let cmd) = ast else { return XCTFail("Expected simple command") }
        XCTAssertEqual(cmd.argv, ["echo", "hello", "world"])
        XCTAssertTrue(cmd.redirections.isEmpty)
    }

    func testParserPipeline() {
        let ast = ShellParser.parse("cat file.txt | grep error | wc -l")
        guard case .pipeline(let cmds) = ast else { return XCTFail("Expected pipeline") }
        XCTAssertEqual(cmds.count, 3)
        XCTAssertEqual(cmds[0].argv, ["cat", "file.txt"])
        XCTAssertEqual(cmds[1].argv, ["grep", "error"])
        XCTAssertEqual(cmds[2].argv, ["wc", "-l"])
    }

    func testParserLogicalOperators() {
        let ast = ShellParser.parse("mkdir test && cd test || echo failed")
        guard case .or(let left, let right) = ast else { return XCTFail("Expected or AST") }
        guard case .and(let first, let second) = left else { return XCTFail("Expected and AST") }
        guard case .simple(let cmd1) = first,
              case .simple(let cmd2) = second,
              case .simple(let cmd3) = right else { return XCTFail("Expected simple commands") }
        XCTAssertEqual(cmd1.argv, ["mkdir", "test"])
        XCTAssertEqual(cmd2.argv, ["cd", "test"])
        XCTAssertEqual(cmd3.argv, ["echo", "failed"])
    }

    func testParserRedirections() {
        let ast = ShellParser.parse("echo 'hi' > out.txt 2>&1 < in.txt >> append.txt")
        guard case .simple(let cmd) = ast else { return XCTFail("Expected simple command") }
        XCTAssertEqual(cmd.argv, ["echo", "hi"])
        XCTAssertEqual(cmd.redirections.count, 4)
        XCTAssertEqual(cmd.redirections[0].kind, .outputTo)
        XCTAssertEqual(cmd.redirections[0].target, "out.txt")
        XCTAssertEqual(cmd.redirections[1].kind, .stderrToStdout)
        XCTAssertEqual(cmd.redirections[2].kind, .inputFrom)
        XCTAssertEqual(cmd.redirections[2].target, "in.txt")
        XCTAssertEqual(cmd.redirections[3].kind, .outputAppend)
        XCTAssertEqual(cmd.redirections[3].target, "append.txt")
    }

    func testParserBackground() {
        let ast = ShellParser.parse("sleep 10 &")
        guard case .background(let inner) = ast else { return XCTFail("Expected background AST") }
        guard case .simple(let cmd) = inner else { return XCTFail("Expected simple command") }
        XCTAssertEqual(cmd.argv, ["sleep", "10"])
    }

    // MARK: - Variable Expansion Tests

    func testVariableExpansion() {
        let env = ["USER": "alice", "GREET": "hello", "EMPTY": ""]
        XCTAssertEqual(VariableExpander.expand("$USER", environ: env), "alice")
        XCTAssertEqual(VariableExpander.expand("hello $USER!", environ: env), "hello alice!")
        XCTAssertEqual(VariableExpander.expand("${GREET}, ${USER}", environ: env), "hello, alice")
        XCTAssertEqual(VariableExpander.expand("${MISSING:-fallback}", environ: env), "fallback")
        XCTAssertEqual(VariableExpander.expand("${USER:-fallback}", environ: env), "alice")
        XCTAssertEqual(VariableExpander.expand("$?", environ: env, lastExitCode: 42), "42")
        XCTAssertEqual(VariableExpander.expand("$$", environ: env, shellPID: 1234), "1234")
        XCTAssertEqual(VariableExpander.expand("$!", environ: env, lastBgPID: 5678), "5678")
    }

    // MARK: - Glob Matching Tests

    func testGlobMatching() {
        XCTAssertTrue(GlobExpander.matchesGlob("hello.txt", pattern: "*.txt"))
        XCTAssertTrue(GlobExpander.matchesGlob("hello.swift", pattern: "h*o.swift"))
        XCTAssertTrue(GlobExpander.matchesGlob("file1.c", pattern: "file?.c"))
        XCTAssertFalse(GlobExpander.matchesGlob("file12.c", pattern: "file?.c"))
        XCTAssertTrue(GlobExpander.matchesGlob("abc.txt", pattern: "[a-z]bc.txt"))
        XCTAssertFalse(GlobExpander.matchesGlob("1bc.txt", pattern: "[a-z]bc.txt"))
        XCTAssertTrue(GlobExpander.matchesGlob("1bc.txt", pattern: "[!a-z]bc.txt"))
        XCTAssertFalse(GlobExpander.matchesGlob("abc.txt", pattern: "[!a-z]bc.txt"))
    }

    // MARK: - Builtin Test / [ Tests

    func testBuiltinTest() {
        XCTAssertEqual(Builtins.builtinTest(["test", "a", "=", "a"]), 0)
        XCTAssertEqual(Builtins.builtinTest(["test", "a", "=", "b"]), 1)
        XCTAssertEqual(Builtins.builtinTest(["test", "a", "!=", "b"]), 0)
        XCTAssertEqual(Builtins.builtinTest(["test", "10", "-eq", "10"]), 0)
        XCTAssertEqual(Builtins.builtinTest(["test", "10", "-lt", "20"]), 0)
        XCTAssertEqual(Builtins.builtinTest(["test", "30", "-le", "20"]), 1)
        XCTAssertEqual(Builtins.builtinTest(["test", "-z", ""]), 0)
        XCTAssertEqual(Builtins.builtinTest(["test", "-z", "hello"]), 1)
        XCTAssertEqual(Builtins.builtinTest(["test", "-n", "hello"]), 0)
        XCTAssertEqual(Builtins.builtinTest(["[", "1", "-eq", "1", "]"]), 0)
        XCTAssertEqual(Builtins.builtinTest(["[", "1", "-eq", "2", "]"]), 1)
    }

    // MARK: - Builtin Printf Tests

    func testBuiltinPrintf() {
        XCTAssertEqual(Builtins.builtinPrintf(["printf", "hello\\n"]), 0)
        XCTAssertEqual(Builtins.builtinPrintf(["printf", "%s is %d", "count", "5"]), 0)
    }

    // MARK: - Core Unix Commands Tests

    func testCoreCommandsBasenameDirname() {
        let tempDir = NSTemporaryDirectory()
        let reg = CommandRegistry()
        CoreCommands.registerAll(into: reg)

        let reqBase = SpawnRequest(cmdline: "basename /path/to/file.txt", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqBase, write: { _ in }), 0)

        let reqDir = SpawnRequest(cmdline: "dirname /path/to/file.txt", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqDir, write: { _ in }), 0)
    }

    func testCoreCommandsSeq() {
        let tempDir = NSTemporaryDirectory()
        let reg = CommandRegistry()
        CoreCommands.registerAll(into: reg)
        let req = SpawnRequest(cmdline: "seq 1 5", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(req, write: { _ in }), 0)
    }

    func testCoreCommandsUnameDateWhoami() {
        let tempDir = NSTemporaryDirectory()
        let reg = CommandRegistry()
        CoreCommands.registerAll(into: reg)

        let reqUname = SpawnRequest(cmdline: "uname -a", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqUname, write: { _ in }), 0)

        let reqDate = SpawnRequest(cmdline: "date", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqDate, write: { _ in }), 0)

        let reqWho = SpawnRequest(cmdline: "whoami", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqWho, write: { _ in }), 0)
    }

    func testCoreCommandsFileOpsInTempDir() throws {
        let tempDir = NSTemporaryDirectory() + "termx_test_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let reg = CommandRegistry()
        CoreCommands.registerAll(into: reg)

        // mkdir
        let reqMkdir = SpawnRequest(cmdline: "mkdir -p sub/nested", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqMkdir, write: { _ in }), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/sub/nested"))

        // touch
        let reqTouch = SpawnRequest(cmdline: "touch sub/nested/file.txt", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqTouch, write: { _ in }), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/sub/nested/file.txt"))

        // ls
        let reqLs = SpawnRequest(cmdline: "ls -a sub/nested", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqLs, write: { _ in }), 0)

        // cp
        let reqCp = SpawnRequest(cmdline: "cp sub/nested/file.txt sub/copy.txt", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqCp, write: { _ in }), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/sub/copy.txt"))

        // mv
        let reqMv = SpawnRequest(cmdline: "mv sub/copy.txt sub/moved.txt", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqMv, write: { _ in }), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/sub/moved.txt"))

        // rm
        let reqRm = SpawnRequest(cmdline: "rm -r sub", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: tempDir, environment: [:], interactive: false)
        XCTAssertEqual(reg.run(reqRm, write: { _ in }), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/sub"))
    }

    // MARK: - VirtualProcess & ProcessTable Tests

    func testVirtualProcessSignal() {
        let proc = VirtualProcess(pid: 42, cwd: "/tmp", environ: [:], stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false)
        var signalHandled = false
        proc.onSignal(2) { // SIGINT
            signalHandled = true
        }

        let table = ProcessTable()
        table.register(proc)
        XCTAssertTrue(table.signal(42, 2))
        XCTAssertTrue(signalHandled)
        XCTAssertTrue(proc.interrupted)
        proc.clearSignal()
        XCTAssertFalse(proc.interrupted)
    }

    func testPIDAllocator() {
        let allocator = PIDAllocator()
        let p1 = allocator.allocate()
        let p2 = allocator.allocate()
        let p3 = allocator.allocate()
        XCTAssertEqual(p1, 1)
        XCTAssertEqual(p2, 2)
        XCTAssertEqual(p3, 3)
    }

    func testJobTableOperations() {
        let jobs = JobTable()
        let j1 = jobs.add(pid: 101, command: "sleep 10")
        let j2 = jobs.add(pid: 102, command: "curl https://example.com")
        XCTAssertEqual(jobs.all().count, 2)
        XCTAssertTrue(jobs.all()[0].running)
        jobs.finish(pid: 101)
        XCTAssertFalse(jobs.all().first(where: { $0.id == j1 })!.running)
        XCTAssertTrue(jobs.all().first(where: { $0.id == j2 })!.running)
    }

    // MARK: - ShellSession & REPL Tests

    func testShellSessionEvaluation() {
        var output = ""
        let session = ShellSession(cwd: "/tmp", environment: ["USER": "testuser"]) { str in
            output += str
        }

        XCTAssertEqual(session.eval("echo Hello $USER"), 0)
        XCTAssertTrue(output.contains("Hello testuser"))

        output = ""
        XCTAssertEqual(session.eval("pwd"), 0)
        XCTAssertTrue(output.contains("/tmp"))

        XCTAssertEqual(session.eval("true && echo ok"), 0)
        XCTAssertEqual(session.eval("false || echo fallback"), 0)
    }

    // MARK: - 100-Command Smoke Suite

    func test100CommandSmokeRun() {
        let engine = TermXCommandEngine()
        let env = ["HOME": "/tmp", "USER": "tester", "TERM": "xterm-256color"]

        var commands: [String] = []
        // Builtins & simple echoes
        for i in 1...20 { commands.append("echo test_\(i)") }
        // Arithmetic / logic
        for i in 1...20 { commands.append("true && echo pass_\(i)") }
        // false || echo
        for i in 1...20 { commands.append("false || echo recovered_\(i)") }
        // seq commands
        for i in 1...10 { commands.append("seq 1 \(i)") }
        // uname / date / whoami / pwd / hostname
        for _ in 1...10 { commands.append("uname -a") }
        for _ in 1...10 { commands.append("date") }
        for _ in 1...10 { commands.append("whoami") }

        XCTAssertEqual(commands.count, 100)

        for (idx, cmd) in commands.enumerated() {
            var output = ""
            let req = SpawnRequest(cmdline: cmd, stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: "/tmp", environment: env, interactive: false)
            let exitCode = engine.run(req) { output += $0 }
            XCTAssertEqual(exitCode, 0, "Command #\(idx + 1) '\(cmd)' failed with exit code \(exitCode)")
        }
    }

    // MARK: - C2 Acceptance Tests (docs/09-integration-contracts.md §3)

    private final class OutputCapture {
        var text = ""
    }

    private func makeSession(cwd: String, env: [String: String] = [:]) -> (ShellSession, OutputCapture) {
        let capture = OutputCapture()
        var mergedEnv = ["HOME": cwd, "USER": "tester", "TERM": "xterm-256color"]
        mergedEnv.merge(env) { _, new in new }
        let session = ShellSession(cwd: cwd, environment: mergedEnv) { capture.text += $0 }
        return (session, capture)
    }

    func testAcceptancePipelineRedirectAnd() throws {
        let tempDir = NSTemporaryDirectory() + "termx_pipe_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try "alpha\nbeta\nxray\n".write(toFile: tempDir + "/list.txt", atomically: true, encoding: .utf8)

        let (session, capture) = makeSession(cwd: tempDir)
        let code = session.eval("cat list.txt | grep x > f && cat f")
        XCTAssertEqual(code, 0)
        XCTAssertTrue(capture.text.contains("xray"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/f"))
    }

    func testAcceptanceForLoop() {
        let (session, capture) = makeSession(cwd: NSTemporaryDirectory())
        let code = session.eval("for i in 1 2 3; do echo $i; done")
        XCTAssertEqual(code, 0)
        let out = capture.text
        XCTAssertTrue(out.contains("1"))
        XCTAssertTrue(out.contains("2"))
        XCTAssertTrue(out.contains("3"))
    }

    func testAcceptanceCtrlCInterruptsSleep() {
        let proc = VirtualProcess(pid: 99, cwd: "/tmp", environ: [:], stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false)
        let table = ProcessTable()
        table.register(proc)

        var exitCode: Int32 = -1
        let thread = Thread {
            ProcessContext.current = proc
            proc.markRunning()
            exitCode = CoreCommands.sleepCmd(["sleep", "30"])
        }
        thread.start()

        usleep(100_000)
        _ = table.signal(99, 2)
        while thread.isExecuting { usleep(10_000) }

        XCTAssertEqual(exitCode, 130)
    }

    func testAcceptanceBackgroundJobsAndKill() {
        let (session, capture) = makeSession(cwd: NSTemporaryDirectory())
        _ = session.eval("sleep 60 &")
        let jobsOut = capture.text
        XCTAssertTrue(jobsOut.contains("[1]"))

        _ = session.eval("jobs")
        XCTAssertTrue(capture.text.contains("sleep 60"))

        _ = session.eval("kill -INT %1")
        usleep(200_000)
    }

    func testAcceptanceExitCodeAndCommandSubstitution() {
        let (session, capture) = makeSession(cwd: NSTemporaryDirectory())
        _ = session.eval("false")
        _ = session.eval("echo exit=$?")
        XCTAssertTrue(capture.text.contains("exit=1"))

        capture.text = ""
        _ = session.eval("echo $(echo substituted)")
        XCTAssertTrue(capture.text.contains("substituted"))
    }

    func testAcceptanceGlobbing() throws {
        let tempDir = NSTemporaryDirectory() + "termx_glob_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        FileManager.default.createFile(atPath: tempDir + "/a.txt", contents: nil)
        FileManager.default.createFile(atPath: tempDir + "/b.txt", contents: nil)
        FileManager.default.createFile(atPath: tempDir + "/c.log", contents: nil)

        let (session, capture) = makeSession(cwd: tempDir)
        _ = session.eval("echo *.txt")
        let out = capture.text
        XCTAssertTrue(out.contains("a.txt"))
        XCTAssertTrue(out.contains("b.txt"))
        XCTAssertFalse(out.contains("c.log"))
    }

    func testAcceptanceConcurrentSessions() {
        var out1 = ""
        var out2 = ""
        let session1 = ShellSession(cwd: "/tmp/a", environment: ["HOME": "/tmp/a", "USER": "u1"]) { out1 += $0 }
        let session2 = ShellSession(cwd: "/tmp/b", environment: ["HOME": "/tmp/b", "USER": "u2"]) { out2 += $0 }

        _ = session1.eval("echo session_one")
        _ = session2.eval("echo session_two")

        XCTAssertTrue(out1.contains("session_one"))
        XCTAssertFalse(out1.contains("session_two"))
        XCTAssertTrue(out2.contains("session_two"))
        XCTAssertFalse(out2.contains("session_one"))
    }

    func testAcceptanceRgJqFd() throws {
        let tempDir = NSTemporaryDirectory() + "termx_tools_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let subDir = tempDir + "/src"
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        try "function hello() { return 'world'; }\n".write(toFile: subDir + "/main.js", atomically: true, encoding: .utf8)
        try "{\"name\":\"termx\",\"version\":1}\n".write(toFile: tempDir + "/data.json", atomically: true, encoding: .utf8)

        let (session, capture) = makeSession(cwd: tempDir)

        _ = session.eval("rg hello src")
        XCTAssertTrue(capture.text.contains("main.js"))

        capture.text = ""
        _ = session.eval("jq .name data.json")
        XCTAssertTrue(capture.text.contains("termx"))

        capture.text = ""
        _ = session.eval("fd .js src")
        XCTAssertTrue(capture.text.contains("main.js"))
    }

    func testAcceptanceCAPIBridge() {
        var req = termx_spawn_req(
            cmdline: ("echo bridge_ok" as NSString).utf8String,
            stdin_fd: -1, stdout_fd: -1, stderr_fd: -1,
            cwd: (NSTemporaryDirectory() as NSString).utf8String,
            envp: nil, interactive: false
        )
        var exitCode: Int32 = -1
        let result = withUnsafePointer(to: &req) { termx_run(UnsafeRawPointer($0), &exitCode) }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(exitCode, 0)
    }

    // MARK: - T6 External Commands (TermXCommands integration)

    func testSedDirectRegistryEntry() throws {
        let tempDir = NSTemporaryDirectory() + "termx_sed_direct_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        try "apple\n".write(toFile: tempDir + "/f", atomically: true, encoding: .utf8)

        let registry = CommandRegistry()
        ExternalCommands.registerAll(into: registry)
        guard let sed = registry.entry(for: "sed") else {
            return XCTFail("sed not registered")
        }

        var capture = ""
        let proc = VirtualProcess(
            pid: 1, cwd: tempDir, environ: ["HOME": tempDir],
            stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false
        )
        proc.stdoutWriter = { capture += $0 }
        proc.stderrWriter = { capture += $0 }
        ProcessContext.current = proc
        let code = sed(["sed", "s/a/X/g", "f"])
        XCTAssertEqual(code, 0, capture)
        XCTAssertTrue(capture.contains("Xpple"), capture)
    }

    func testSedParserArgv() {
        let ast = ShellParser.parse("sed 's/a/X/g' f")
        guard case .simple(let cmd) = ast else { return XCTFail("expected simple") }
        XCTAssertEqual(cmd.argv, ["sed", "s/a/X/g", "f"], cmd.argv.description)
    }

    func testSessionEvalMatchesCommandLineForSed() throws {
        let tempDir = NSTemporaryDirectory() + "termx_sed_eval_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        try "apple\n".write(toFile: tempDir + "/f", atomically: true, encoding: .utf8)

        let (session, capture) = makeSession(cwd: tempDir)
        let direct = session.evalCommandLine("sed 's/a/X/g' f")
        capture.text = ""
        let viaEval = session.eval("sed 's/a/X/g' f")
        XCTAssertEqual(direct, viaEval, "capture: \(capture.text)")
        XCTAssertEqual(viaEval, 0, capture.text)
    }

    func testShellLangParserIgnoresPlainSed() throws {
        XCTAssertNil(try ScriptParser.parse("sed 's/a/X/g' f"))
    }

    func testSessionSedViaCommandLine() throws {
        let tempDir = NSTemporaryDirectory() + "termx_sed_session_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        try "apple\n".write(toFile: tempDir + "/f", atomically: true, encoding: .utf8)

        let (session, capture) = makeSession(cwd: tempDir)
        let code = session.evalCommandLine("sed 's/a/X/g' f")
        XCTAssertEqual(code, 0, capture.text)
        XCTAssertTrue(capture.text.contains("Xpple"), capture.text)
    }

    func testAwkSingleQuotedProgramPreserved() {
        let ast = ShellParser.parse("ls | awk '{print NR, $1}'")
        guard case .pipeline(let cmds) = ast else { return XCTFail("pipeline") }
        XCTAssertEqual(cmds[1].argv[1], "{print NR, $1}")
        XCTAssertTrue(cmds[1].literalArgv[1])
    }

    func testIfFileTestViaCommandLine() throws {
        let tempDir = NSTemporaryDirectory() + "termx_if_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        try "x\n".write(toFile: tempDir + "/a.txt", atomically: true, encoding: .utf8)
        let (session, capture) = makeSession(cwd: tempDir)
        XCTAssertEqual(session.evalCommandLine("[ -f a.txt ]"), 0, capture.text)
    }

    func testExternalCommandsSedAwkDiffChmod() throws {
        let tempDir = NSTemporaryDirectory() + "termx_extcmd_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try "apple\nbanana\napricot\n".write(toFile: tempDir + "/f", atomically: true, encoding: .utf8)
        try "apple\nbanana\napricot\n".write(toFile: tempDir + "/a", atomically: true, encoding: .utf8)
        try "apple\nbanana\napricot\n".write(toFile: tempDir + "/b", atomically: true, encoding: .utf8)

        let (session, capture) = makeSession(cwd: tempDir)
        XCTAssertNotNil(session.registry.entry(for: "sed"), "sed must be registered via ExternalCommands")

        capture.text = ""
        XCTAssertEqual(session.eval("sed 's/a/X/g' f"), 0, capture.text)
        XCTAssertTrue(capture.text.contains("Xpple"), "file sed output: \(capture.text)")

        capture.text = ""
        XCTAssertEqual(session.eval("cat f | sed 's/a/X/g'"), 0, capture.text)
        XCTAssertTrue(capture.text.contains("Xpple"), "pipeline sed output: \(capture.text)")

        capture.text = ""
        let awkCode = session.eval("ls | awk '{print NR, $1}'")
        XCTAssertEqual(awkCode, 0, "awk output: \(capture.text)")
        XCTAssertTrue(capture.text.contains("1 a"), "awk output: \(capture.text)")

        capture.text = ""
        try "delta\n".write(toFile: tempDir + "/b", atomically: true, encoding: .utf8)
        let diffCode = session.eval("diff -u a b")
        XCTAssertEqual(diffCode, 1)
        XCTAssertTrue(capture.text.contains("-apricot") || capture.text.contains("delta"))

        let scriptPath = tempDir + "/run.sh"
        try "#!/bin/sh\necho ok\n".write(toFile: scriptPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(session.eval("chmod +x run.sh"), 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertTrue(perms & 0o111 != 0, "expected executable bit set, got \(String(format: "%o", perms))")
    }

    // MARK: - T7 Shell Language (TermXShellLang integration)

    func testShellLangIfWhileCaseFunction() throws {
        let tempDir = NSTemporaryDirectory() + "termx_shelllang_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let (session, capture) = makeSession(cwd: tempDir)

        try "present\n".write(toFile: tempDir + "/a.txt", atomically: true, encoding: .utf8)
        capture.text = ""
        XCTAssertEqual(session.eval("if [ -f a.txt ]; then echo yes; else echo no; fi"), 0)
        XCTAssertTrue(capture.text.contains("yes"))

        capture.text = ""
        XCTAssertEqual(session.eval("while [ 1 -gt 0 ]; do echo loop; break; echo skip; done"), 0)
        XCTAssertTrue(capture.text.contains("loop"))
        XCTAssertFalse(capture.text.contains("skip"))

        capture.text = ""
        XCTAssertEqual(session.eval("case x in x) echo matched;; esac"), 0)
        XCTAssertTrue(capture.text.contains("matched"))

        capture.text = ""
        _ = session.eval("""
        greet() {
          echo hi $1 count=$#
        }
        greet world extra
        """)
        XCTAssertTrue(capture.text.contains("hi world"), "function output: \(capture.text)")
        XCTAssertTrue(capture.text.contains("count=2") || capture.text.contains("count=2\n"),
                        "function output: \(capture.text)")
    }

    func testShellLangParameterExpansionAndArithmetic() {
        let (session, capture) = makeSession(cwd: NSTemporaryDirectory())

        capture.text = ""
        XCTAssertEqual(session.eval("echo ${UNSET:-default}"), 0)
        XCTAssertTrue(capture.text.contains("default"))

        capture.text = ""
        XCTAssertEqual(session.eval("echo $((6*7))"), 0)
        XCTAssertTrue(capture.text.contains("42"))
    }

    func testShellLangHereDoc() {
        let tempDir = NSTemporaryDirectory() + "termx_heredoc_" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let (session, capture) = makeSession(cwd: tempDir)
        let script = """
        cat <<EOF
        line one
        line two
        EOF
        """
        capture.text = ""
        XCTAssertEqual(ShellLangIntegration.evalScript(script, session: session), 0)
        XCTAssertTrue(capture.text.contains("line one"))
        XCTAssertTrue(capture.text.contains("line two"))
    }
}
