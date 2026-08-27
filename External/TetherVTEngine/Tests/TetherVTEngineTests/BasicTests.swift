import XCTest
@testable import TetherVTEngine
final class BasicTests: XCTestCase {
 func testSplitAndRestore(){ let t=VTStreamTokenizer(); let e=Data([27,91,63,49,48,52,57,104]); var a=[VTToken](); for b in e { a += t.feed(Data([b])) }; XCTAssertEqual(a.count,1); let tr=TUIStateTracker(); a.forEach(tr.observe); XCTAssertTrue(tr.state.alternateScreen); XCTAssertEqual(tr.restoreSequence(),Data("\u{1b}[?1049l\u{1b}[0m".utf8)) }
 func testUTF8(){let t=VTStreamTokenizer(); let x=Array("😀".utf8); XCTAssertEqual(t.feed(Data(x.prefix(2))).count,0); let z=t.feed(Data(x.suffix(2)))+t.flush(); XCTAssertEqual(z.reduce(Data()){var x=$0;x.append(VTToken.serialize($1));return x},Data(x))}
 func testModes(){let tr=TUIStateTracker(); let t=VTStreamTokenizer(); for x in t.feed(Data("\u{1b}[?1049;2004h\u{1b}[?25l\u{1b}[>1u\u{1b}[>1u\u{1b}[<u".utf8)){tr.observe(x)}; XCTAssertTrue(tr.state.alternateScreen); XCTAssertTrue(tr.state.bracketedPaste); XCTAssertTrue(tr.state.cursorHidden); XCTAssertEqual(tr.state.kittyKeyboardDepth,1)}
 func testResponder(){let r=VTQueryResponder(identity:.xterm256Color,policy:.conservativeDefault); let x=r.process(Data("\u{1b}[?996n".utf8)); XCTAssertTrue(x.forward.isEmpty); XCTAssertEqual(x.replies,Data("\u{1b}[?997;1n".utf8))}
}
