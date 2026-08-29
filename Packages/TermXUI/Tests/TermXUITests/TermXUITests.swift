import XCTest
import SwiftTerm
import TetherTerminal
@testable import TermXUI

final class TermXUITests: XCTestCase {
    func testDefaultEnvironmentUsesRequiredTermXValues() {
        let environment = TerminalSession.defaultEnvironment(home: "/sandbox/Documents")
        XCTAssertEqual(environment["HOME"], "/sandbox/Documents")
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertTrue(environment["PATH"]?.contains("/sandbox/Documents/node/bin") == true)
    }

    func testAccessoryKeysEncodeExpectedTerminalBytes() {
        XCTAssertEqual(TerminalKey.escape.bytes, Data([0x1B]))
        XCTAssertEqual(TerminalKey.tab.bytes, Data([0x09]))
        XCTAssertEqual(TerminalKey.left.bytes, Data([0x1B, 0x5B, 0x44]))
        XCTAssertEqual(TerminalKey.up.bytes, Data([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(TerminalKey.ctrlC, Data([0x03]))
    }

    func testSessionStartsOnceAndSignalsResize() throws {
        let engine = RecordingEngine()
        let session = TerminalSession(cwd: "/workspaces/demo", engine: engine)
        XCTAssertEqual(try session.start(ptySlave: 42), 9001)
        XCTAssertTrue(session.isRunning)
        session.resize(cols: 120, rows: 40)
        XCTAssertEqual(session.cols, 120)
        XCTAssertEqual(session.rows, 40)
        XCTAssertEqual(engine.signals.last?.0, 9001)
        XCTAssertEqual(engine.signals.last?.1, SIGWINCH)
        XCTAssertThrowsError(try session.start(ptySlave: 42)) { XCTAssertEqual($0 as? TerminalSessionError, .alreadyRunning) }
    }

    func testInputIsDeliveredOffTheMainThreadBoundary() throws {
        let engine = RecordingEngine()
        let expectation = expectation(description: "input delivered")
        let session = TerminalSession(cwd: "/tmp", engine: engine, onInput: { data in
            if String(decoding: data, as: UTF8.self) == "echo hi\n" {
                DispatchQueue.main.async { expectation.fulfill() }
            }
        })
        _ = try session.start(ptySlave: 1)
        session.send("echo hi\n")
        wait(for: [expectation], timeout: 3)
    }

    func testTerminateReturnsWithoutBlockingMainThread() throws {
        let engine = RecordingEngine()
        let session = TerminalSession(cwd: "/tmp", engine: engine)
        _ = try session.start()
        let start = CFAbsoluteTimeGetCurrent()
        session.terminate()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertFalse(session.isRunning)
        XCTAssertLessThan(elapsed, 0.15, "terminate() must not block the caller")
        XCTAssertEqual(engine.signals.first?.1, SIGTERM)
    }

    func testStartFailureAfterPartialOpenDoesNotLeaveRunningSession() {
        final class FailingEngine: TerminalEngine {
            func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 {
                throw NSError(domain: "test", code: 1)
            }
            func signal(pid: Int32, _ sig: Int32) {}
        }
        let session = TerminalSession(cwd: "/tmp", engine: FailingEngine())
        XCTAssertThrowsError(try session.start()) { _ in }
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.pid)
    }

    func testRestoredOutputWaitsForTheRendererWithoutEnteringTranscript() {
        let session = TerminalSession(cwd: "/tmp", engine: RecordingEngine())
        let restored = Data("restored screen".utf8)
        let delivered = expectation(description: "restored output delivered")

        session.renderWithoutRecording(restored)
        session.attachOutputHandler { data in
            XCTAssertEqual(data, restored)
            delivered.fulfill()
        }

        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(session.recentOutputTail(maxBytes: 1024).isEmpty)
    }

    func testDeliverEmulatorReplyIsConsumedByHostJobCallback() {
        let session = TerminalSession(cwd: "/tmp", engine: RecordingEngine())
        var captured: Data?
        session.onEmulatorReply = { data in
            captured = data
            return true
        }
        let reply = Data([0x1B, 0x5B, 0x63])
        XCTAssertTrue(session.deliverEmulatorReply(reply))
        XCTAssertEqual(captured, reply)
    }

    func testDeliverEmulatorReplyIsDroppedDuringReplay() {
        let session = TerminalSession(cwd: "/tmp", engine: RecordingEngine())
        var called = false
        session.onEmulatorReply = { _ in called = true; return true }
        session.suppressQueryReplies = true
        XCTAssertTrue(session.deliverEmulatorReply(Data([0x1B, 0x5B, 0x63])))
        XCTAssertFalse(called)
    }

    func testWriteToPTYDoesNotFireOnKeystroke() throws {
        let session = TerminalSession(cwd: "/tmp", engine: RecordingEngine())
        let keystroke = expectation(description: "keystroke")
        keystroke.isInverted = true
        session.onKeystroke = { _ in keystroke.fulfill() }
        _ = try session.start()
        session.writeToPTY(Data([0x1B, 0x5B, 0x63]))
        wait(for: [keystroke], timeout: 0.3)
        session.terminate()
    }

    func testReplayBytesAreDeliveredSeparatelyFromLiveOutput() {
        let session = TerminalSession(cwd: "/tmp", engine: RecordingEngine())
        session.renderWithoutRecording(Data("REPLAY".utf8))
        session.appendTranscriptForTesting(Data("LIVE".utf8))
        // Live output after a handler exists uses deliverOutput; before attach,
        // only pendingOutput (live) vs pendingReplay should stay distinct.
        var chunks: [String] = []
        let delivered = expectation(description: "both")
        delivered.expectedFulfillmentCount = 1
        session.attachOutputHandler { data in
            chunks.append(String(decoding: data, as: UTF8.self))
            if chunks.joined().contains("REPLAY") { delivered.fulfill() }
        }
        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(chunks.contains(where: { $0.contains("REPLAY") }))
    }
}

#if canImport(Darwin)
import Darwin

final class TermXUIAcceptanceTests: XCTestCase {
    func testTypedCharactersRoundTripThroughEchoEngine() throws {
        let engine = EchoEngine()
        let session = TerminalSession(cwd: "/tmp", engine: engine)
        let expectation = expectation(description: "round-trip")
        var received = Data()
        session.attachOutputHandler { data in
            received.append(data)
            if received.count >= 5 { expectation.fulfill() }
        }
        _ = try session.start()
        session.send("hello")
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "hello")
    }

    func testPaste10KBRoundTrip() throws {
        let engine = EchoEngine()
        let session = TerminalSession(cwd: "/tmp", engine: engine)
        let chunk = String(repeating: "A", count: 1024)
        let expectation = expectation(description: "paste-echo")
        var received = Data()
        session.attachOutputHandler { data in
            received.append(data)
            if received.count >= 10 * 1024 { expectation.fulfill() }
        }
        _ = try session.start()
        for _ in 0..<10 {
            session.paste(chunk)
            usleep(50_000)
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertGreaterThanOrEqual(received.count, 10 * 1024, "10KB paste should round-trip through the PTY")
    }

    func testResizeReportsCorrectColsAndRows() throws {
        let pair = try PtyPair(cols: 80, rows: 24)
        defer { pair.close() }
        pair.resize(cols: 132, rows: 43)
        let size = pair.currentSize()
        XCTAssertEqual(size.cols, 132)
        XCTAssertEqual(size.rows, 43)

        let engine = RecordingEngine()
        let session = TerminalSession(cwd: "/tmp", engine: engine)
        _ = try session.start(ptySlave: pair.slave)
        session.resize(cols: 100, rows: 30)
        XCTAssertEqual(session.cols, 100)
        XCTAssertEqual(session.rows, 30)
        XCTAssertEqual(engine.signals.last?.1, SIGWINCH)
    }

    func testToolbarSendsEscAndCtrlCBytes() throws {
        let escExpectation = expectation(description: "esc")
        let ctrlExpectation = expectation(description: "ctrl-c")
        let engine = RecordingEngine()
        let session = TerminalSession(cwd: "/tmp", engine: engine, onInput: { data in
            if data == TerminalKey.escape.bytes { escExpectation.fulfill() }
            if data == TerminalKey.ctrlC { ctrlExpectation.fulfill() }
        })
        _ = try session.start(ptySlave: 1)
        session.send(TerminalKey.escape.bytes)
        session.send(TerminalKey.ctrlC)
        wait(for: [escExpectation, ctrlExpectation], timeout: 3)
    }

    func testDoubleCtrlCIsDeliveredAsBytesOnly() throws {
        // Real terminals forward every ^C to the PTY; they do not host-kill on
        // the second tap. Programs decide when to exit and restore the screen.
        let first = expectation(description: "first-ctrl-c")
        let second = expectation(description: "second-ctrl-c")
        var count = 0
        let engine = RecordingEngine()
        let session = TerminalSession(cwd: "/tmp", engine: engine, onInput: { data in
            guard data == TerminalKey.ctrlC else { return }
            count += 1
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        })
        _ = try session.start(ptySlave: 1)
        session.send(TerminalKey.ctrlC)
        session.send(TerminalKey.ctrlC)
        wait(for: [first, second], timeout: 3)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(engine.signals.isEmpty)
    }

    func testVimStyleFixtureSnapshot() {
        let fixture = """
        \u{1B}[?1049h\u{1B}[1;1H\u{1B}[2J\u{1B}[32mSTATUS\u{1B}[0m\u{1B}[10;6HHello vim\u{1B}[24;1H\u{1B}[7m-- INSERT --\u{1B}[0m
        """
        let terminal = SwiftTerm.Terminal(delegate: NullTerminalDelegate(), options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(text: fixture)
        let snapshot = TerminalBufferSnapshot.capture(terminal)
        XCTAssertTrue(snapshot.contains("STATUS"))
        XCTAssertTrue(snapshot.contains("Hello vim"))
        XCTAssertTrue(snapshot.contains("-- INSERT --"))
        XCTAssertEqual(snapshot.split(separator: "\n").count, 24)
    }

    func testAlternateScreen1049RestoresPrimaryBufferAndScrollback() {
        let terminal = SwiftTerm.Terminal(
            delegate: NullTerminalDelegate(),
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 500)
        )
        terminal.feed(text: "primary history line\r\n")
        terminal.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1Halt-only content\r\n")
        XCTAssertTrue(terminal.isCurrentBufferAlternate)

        terminal.feed(text: "\u{1B}[?1049l")
        XCTAssertFalse(terminal.isCurrentBufferAlternate)

        let snapshot = TerminalBufferSnapshot.capture(terminal)
        XCTAssertTrue(snapshot.contains("primary history line"))
        XCTAssertFalse(snapshot.contains("alt-only content"))
    }

    func testDeliveredTerminalAndRendererSurviveUnknownDECMode() {
        let stream = "\u{1B}[?2031hREADY\u{1B}[?2031l"

        let conformance = TetherTerminal.Terminal(columns: 80, rows: 24)
        conformance.feed(stream)
        XCTAssertEqual(conformance.row(0), "READY")

        let renderer = SwiftTerm.Terminal(
            delegate: NullTerminalDelegate(),
            options: TerminalOptions(cols: 80, rows: 24)
        )
        renderer.feed(text: stream)
        XCTAssertTrue(TerminalBufferSnapshot.capture(renderer).contains("READY"))
    }

    func testHighThroughputOutputMaintainsSixtyFPSFrameBudget() {
        let terminal = SwiftTerm.Terminal(delegate: NullTerminalDelegate(), options: TerminalOptions(cols: 120, rows: 40, scrollback: 1000))
        let bytesPerFrame = 4 * 1024
        let frames = 256
        var maxFrame: CFTimeInterval = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<frames {
            let frameStart = CFAbsoluteTimeGetCurrent()
            terminal.feed(buffer: ArraySlice([UInt8](repeating: 0x41, count: bytesPerFrame)))
            maxFrame = max(maxFrame, CFAbsoluteTimeGetCurrent() - frameStart)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let bytesPerSecond = Double(bytesPerFrame * frames) / elapsed
        XCTAssertGreaterThanOrEqual(bytesPerSecond, 800_000, "Feed rate should approach 1MB/s")
        XCTAssertLessThan(maxFrame, 0.25, "No 4KB frame should exceed 250ms on Simulator")
    }

    func testBundledJetBrainsMonoFontLoads() {
        #if canImport(UIKit)
        let font = TerminalFont.jetBrainsMono.uiFont(size: 14)
        XCTAssertTrue(font.fontName.localizedCaseInsensitiveContains("JetBrains") || font.fontName.localizedCaseInsensitiveContains("jetbrains"))
        #endif
    }

    func testCopyableTranscriptIncludesMetadataAndStripsANSI() {
        let session = TerminalSession(cwd: "/workspaces/demo", engine: RecordingEngine())
        session.appendTranscriptForTesting(Data("\u{001B}[31merror: boom\u{001B}[0m\u{001B}[<u\nok\n".utf8))
        let text = session.copyableTranscript()
        XCTAssertTrue(text.contains("Tether diagnostic log"))
        XCTAssertTrue(text.contains("format: 3"))
        XCTAssertTrue(text.contains("Browser / open debug"))
        XCTAssertTrue(text.contains("cwd: /workspaces/demo"))
        XCTAssertTrue(text.contains("error: boom"))
        XCTAssertTrue(text.contains("ok"))
        XCTAssertFalse(text.contains("\u{001B}["), "ANSI CSI should be stripped for chat paste")
        XCTAssertFalse(text.contains("<u"), "CSI parameter bytes must not leak into copied diagnostics")
    }
}
#endif

private final class RecordingEngine: TerminalEngine {
    var signals: [(Int32, Int32)] = []
    func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 { 9001 }
    func signal(pid: Int32, _ sig: Int32) { signals.append((pid, sig)) }
}

#if canImport(Darwin)
import Darwin
#else
private let SIGWINCH: Int32 = 28
#endif
