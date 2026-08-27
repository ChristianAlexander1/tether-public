import XCTest
@testable import TetherVTEngine
final class FixtureTests: XCTestCase {
 private func tracker(_ name:String)->TUIStateTracker {let url=Bundle.module.url(forResource:name,withExtension:"bin",subdirectory:"Fixtures")!;let bytes=try! Data(contentsOf:url);let t=VTStreamTokenizer();let r=TUIStateTracker();for x in t.feed(bytes)+t.flush(){r.observe(x)};return r}
 func testVimLikeRestoresClean(){let r=tracker("vim-like");XCTAssertTrue(r.state.isClean)}
 func testInkInterruptedNeedsRestore(){let r=tracker("interrupted-session");XCTAssertTrue(r.state.alternateScreen);XCTAssertTrue(r.state.cursorHidden);XCTAssertFalse(r.restoreSequence().isEmpty)}
 func testInkLikeModes(){let r=tracker("ink-like");XCTAssertTrue(r.state.bracketedPaste);XCTAssertTrue(r.state.cursorHidden)}
}
