import XCTest
@testable import TetherVTEngine
final class PipelineTests: XCTestCase {
 func testComposition(){let p=VTOutputPipeline(identity:.xterm256Color,policy:.conservativeDefault);let x=p.feed(Data("\u{1b}[?1049hhello".utf8));XCTAssertEqual(x.forward,Data("\u{1b}[?1049hhello".utf8));XCTAssertTrue(p.trackerState.alternateScreen);XCTAssertFalse(p.restoreSequence().isEmpty)}
}
