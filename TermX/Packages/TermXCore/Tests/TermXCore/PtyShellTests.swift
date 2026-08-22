import XCTest
@testable import TermXCore

/// Drives the interactive engine exactly as the terminal UI does: through a real pty,
/// one command per line, verifying the shell survives to run every command.
final class PtyShellTests: XCTestCase {
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var workDir: String = ""

    override func setUpWithError() throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw XCTSkip("openpty unavailable")
        }
        masterFD = master
        slaveFD = slave
        workDir = NSTemporaryDirectory() + "termx_pty_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if masterFD >= 0 { close(masterFD) }
        if slaveFD >= 0 { close(slaveFD) }
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private func send(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBufferPointer { _ = write(masterFD, $0.baseAddress!, bytes.count) }
    }

    func testShellRunsMultipleCommandsOverPty() throws {
        let engine = TermXShellEngine()
        let exited = expectation(description: "shell exited")
        exited.isInverted = true

        let env = ["HOME": workDir, "PATH": "/bin", "TERM": "xterm-256color"]
        _ = try engine.startShell(cwd: workDir, env: env, ptySlave: slaveFD) { _ in
            exited.fulfill()
        }

        send("echo first > one.txt")
        usleep(300_000)

        // A window resize (SIGWINCH) and a Ctrl-C must never end the interactive shell.
        engine.signal(pid: 1, SIGWINCH)
        engine.signal(pid: 1, SIGINT)
        usleep(100_000)

        send("echo second > two.txt")
        usleep(300_000)
        send("mkdir made-dir")
        usleep(300_000)
        send("echo piped | grep pip > three.txt")
        usleep(400_000)
        // Command substitution containing a pipeline, then a following command: proves
        // the substitution does not wedge the shell.
        send("echo count=$(ls | wc -l) > four.txt")
        usleep(600_000)
        send("echo alive > five.txt")
        usleep(400_000)

        // The shell must still be alive: an early exit means an fd was closed underneath it.
        wait(for: [exited], timeout: 0.5)

        let fm = FileManager.default
        XCTAssertEqual(try? String(contentsOfFile: workDir + "/one.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "first")
        XCTAssertEqual(try? String(contentsOfFile: workDir + "/two.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "second")
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: workDir + "/made-dir", isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try? String(contentsOfFile: workDir + "/three.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "piped")
        let four = (try? String(contentsOfFile: workDir + "/four.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(four, "command substitution with a pipeline produced no output")
        XCTAssertTrue(four?.hasPrefix("count=") == true, "got \(four ?? "nil")")
        XCTAssertEqual(try? String(contentsOfFile: workDir + "/five.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "alive",
                       "shell stopped accepting commands after a command substitution")
    }
}
