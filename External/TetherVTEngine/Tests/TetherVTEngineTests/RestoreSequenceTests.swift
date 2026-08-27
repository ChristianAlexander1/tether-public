import XCTest
@testable import TetherVTEngine
final class RestoreSequenceTests: XCTestCase {
 func testSpecifiedOrder(){let t=VTStreamTokenizer();let r=TUIStateTracker();for x in t.feed(Data("\u{1b}[?2026h\u{1b}[?1000h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?25l\u{1b}[?1049h".utf8)){r.observe(x)};let s=String(decoding:r.restoreSequence(),as:UTF8.self);XCTAssertTrue(s.hasPrefix("\u{1b}[?2026l\u{1b}[?1000l\u{1b}[?2004l"));XCTAssertTrue(s.contains("\u{1b}[?1049l"));XCTAssertTrue(s.hasSuffix("\u{1b}[?25h"))}
}
