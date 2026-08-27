import XCTest
@testable import TetherVTEngine
final class TrackerTests: XCTestCase {
 func testDECSetMultiple(){let t=VTStreamTokenizer();let r=TUIStateTracker();for x in t.feed(Data("\u{1b}[?1000;1006;2004h".utf8)){r.observe(x)};XCTAssertEqual(r.state.mouseModes,[1000,1006]);XCTAssertTrue(r.state.bracketedPaste)}
 func testRISAndDECSTR(){let t=VTStreamTokenizer();let r=TUIStateTracker();for x in t.feed(Data("\u{1b}[?1049h\u{1b}[!p".utf8)){r.observe(x)};XCTAssertTrue(r.state.isClean);XCTAssertTrue(r.restoreSequence().isEmpty)}
 func testKittyDepth(){let t=VTStreamTokenizer();let r=TUIStateTracker();for x in t.feed(Data("\u{1b}[>1u\u{1b}[>1u\u{1b}[<u".utf8)){r.observe(x)};XCTAssertEqual(r.state.kittyKeyboardDepth,1)}
}
