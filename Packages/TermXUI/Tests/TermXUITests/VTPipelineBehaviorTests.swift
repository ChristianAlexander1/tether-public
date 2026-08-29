import Foundation
import TetherVTEngine
import XCTest
@testable import TermXUI

/// The behaviour `TerminalProtocolAdapter` used to guarantee, now asserted
/// against `VTOutputPipeline`. These cases are the byte-level oracle for the
/// colour-scheme protocol (DECSET/DECRST 2031, CSI ?996n, CSI ?2031$p): the
/// pipeline must consume exactly the same queries and answer with exactly the
/// same bytes as the adapter it replaced.
final class VTPipelineBehaviorTests: XCTestCase {
    private func makePipeline(isDark: Bool) -> VTOutputPipeline {
        var identity = TerminalIdentity.xterm256Color
        identity.colorSchemeIsDark = isDark
        return VTOutputPipeline(identity: identity, policy: .conservativeDefault)
    }

    func testColorSchemeQueryIsConsumedAndAnswered() {
        let pipeline = makePipeline(isDark: true)
        let result = pipeline.feed(Data("before\u{1B}[?996nafter".utf8))
        XCTAssertEqual(String(decoding: result.forward, as: UTF8.self), "beforeafter")
        XCTAssertEqual(String(decoding: result.replies, as: UTF8.self), "\u{1B}[?997;1n")
    }

    func testMode2031TracksChangesWithoutLeakingToRenderer() {
        var replies: [String] = []
        let pipeline = makePipeline(isDark: true)
        pipeline.onUnsolicitedReply = { replies.append(String(decoding: $0, as: UTF8.self)) }

        XCTAssertTrue(pipeline.feed(Data("\u{1B}[?2031h".utf8)).forward.isEmpty)
        pipeline.identity.colorSchemeIsDark = false
        XCTAssertEqual(replies, ["\u{1B}[?997;2n"])

        XCTAssertTrue(pipeline.feed(Data("\u{1B}[?2031l".utf8)).forward.isEmpty)
        pipeline.identity.colorSchemeIsDark = true
        XCTAssertEqual(replies.count, 1, "no report once the program stopped subscribing")
    }

    func testFragmentedAndUnknownSequencesArePreservedCorrectly() {
        let pipeline = makePipeline(isDark: false)
        XCTAssertEqual(String(decoding: pipeline.feed(Data("x\u{1B}[?20".utf8)).forward, as: UTF8.self), "x")
        XCTAssertTrue(pipeline.feed(Data("31h".utf8)).forward.isEmpty)
        let unknown = Data("\u{1B}[?2004h".utf8)
        XCTAssertEqual(pipeline.feed(unknown).forward, unknown)
    }

    func testModeQueryReportsSetAndReset() {
        let pipeline = makePipeline(isDark: true)
        let first = pipeline.feed(Data("\u{1B}[?2031$p".utf8)).replies
        let second = pipeline.feed(Data("\u{1B}[?2031h\u{1B}[?2031$p".utf8)).replies
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "\u{1B}[?2031;2$y")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "\u{1B}[?2031;1$y")
    }

    // MARK: - The capability the adapter never had

    func testAlternateScreenAndCursorAreRestoredAfterAnAbnormalExit() {
        let pipeline = makePipeline(isDark: true)
        // A vim-like program: alternate screen, hidden cursor, mouse tracking,
        // bracketed paste — then it dies without emitting any of the resets.
        _ = pipeline.feed(Data("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1000h\u{1B}[?2004h".utf8))
        XCTAssertFalse(pipeline.trackerState.isClean)

        let restore = String(decoding: pipeline.restoreSequence(), as: UTF8.self)
        XCTAssertTrue(restore.contains("\u{1B}[?1049l"), "must leave the alternate screen")
        XCTAssertTrue(restore.contains("\u{1B}[?25h"), "must show the cursor again")
        XCTAssertTrue(restore.contains("\u{1B}[?2004l"), "must end bracketed paste")
        XCTAssertTrue(
            restore.contains("\u{1B}[?1000l"),
            "mouse reporting is a DEC private mode; CSI 1000 l would not disable it"
        )

        pipeline.resetTracker()
        XCTAssertTrue(pipeline.trackerState.isClean)
        XCTAssertTrue(pipeline.restoreSequence().isEmpty)
    }

    func testCleanExitProducesNoRestoreBytes() {
        let pipeline = makePipeline(isDark: true)
        _ = pipeline.feed(Data("\u{1B}[?1049h\u{1B}[?25lwork\u{1B}[?25h\u{1B}[?1049l".utf8))
        XCTAssertTrue(pipeline.trackerState.isClean)
        XCTAssertTrue(pipeline.restoreSequence().isEmpty)
    }

    /// Claude Code (Ink): alt screen + hidden cursor + mouse + bracketed paste.
    /// A normal quit emits the matching DECRST itself — the host must not
    /// synthesize a second restore.
    func testClaudeLikeNormalQuitProducesNoRestore() {
        let pipeline = makePipeline(isDark: true)
        _ = pipeline.feed(Data(
            "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?2004h".utf8
        ))
        XCTAssertFalse(pipeline.trackerState.isClean)
        _ = pipeline.feed(Data(
            "\u{1B}[?2004l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?25h\u{1B}[?1049l".utf8
        ))
        XCTAssertTrue(pipeline.trackerState.isClean)
        XCTAssertTrue(pipeline.restoreSequence().isEmpty)
    }

    /// Double-Ctrl-C and a mid-TUI force-kill both leave the same unclean
    /// modes. hostJobFinished asks for this sequence.
    func testClaudeLikeAbnormalExitRestoresAltScreenCursorAndMouse() {
        let pipeline = makePipeline(isDark: true)
        _ = pipeline.feed(Data(
            "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1000h\u{1B}[?2004hClaude TUI".utf8
        ))
        let restore = String(decoding: pipeline.restoreSequence(), as: UTF8.self)
        XCTAssertTrue(restore.contains("\u{1B}[?1049l"))
        XCTAssertTrue(restore.contains("\u{1B}[?25h"))
        XCTAssertTrue(restore.contains("\u{1B}[?1000l"))
        XCTAssertTrue(restore.contains("\u{1B}[?2004l"))
        XCTAssertFalse(restore.isEmpty)
    }
}
