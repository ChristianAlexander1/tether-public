import Foundation
import XCTest
@testable import TermXUI

final class TerminalProtocolAdapterTests: XCTestCase {
    func testColorSchemeQueryIsConsumedAndAnswered() {
        var replies: [Data] = []
        let adapter = TerminalProtocolAdapter(isDark: true) { replies.append($0) }
        let output = adapter.process(Data("before\u{1B}[?996nafter".utf8))
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "beforeafter")
        XCTAssertEqual(replies.map { String(decoding: $0, as: UTF8.self) }, ["\u{1B}[?997;1n"])
    }

    func testMode2031TracksChangesWithoutLeakingToRenderer() {
        var replies: [Data] = []
        let adapter = TerminalProtocolAdapter(isDark: true) { replies.append($0) }
        XCTAssertTrue(adapter.process(Data("\u{1B}[?2031h".utf8)).isEmpty)
        adapter.updateColorScheme(isDark: false)
        XCTAssertEqual(replies.map { String(decoding: $0, as: UTF8.self) }, ["\u{1B}[?997;2n"])
        XCTAssertTrue(adapter.process(Data("\u{1B}[?2031l".utf8)).isEmpty)
        adapter.updateColorScheme(isDark: true)
        XCTAssertEqual(replies.count, 1)
    }

    func testFragmentedAndUnknownSequencesArePreservedCorrectly() {
        let adapter = TerminalProtocolAdapter(isDark: false)
        XCTAssertEqual(String(decoding: adapter.process(Data("x\u{1B}[?20".utf8)), as: UTF8.self), "x")
        XCTAssertTrue(adapter.process(Data("31h".utf8)).isEmpty)
        let unknown = Data("\u{1B}[?2004h".utf8)
        XCTAssertEqual(adapter.process(unknown), unknown)
    }

    func testModeQueryReportsSetAndReset() {
        var replies: [String] = []
        let adapter = TerminalProtocolAdapter(isDark: true) {
            replies.append(String(decoding: $0, as: UTF8.self))
        }
        _ = adapter.process(Data("\u{1B}[?2031$p".utf8))
        _ = adapter.process(Data("\u{1B}[?2031h\u{1B}[?2031$p".utf8))
        XCTAssertEqual(replies, ["\u{1B}[?2031;2$y", "\u{1B}[?2031;1$y"])
    }
}
