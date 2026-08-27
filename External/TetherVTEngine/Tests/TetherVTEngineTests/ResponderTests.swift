import XCTest
@testable import TetherVTEngine
final class ResponderTests: XCTestCase {
 func testColorLifecycle(){let r=VTQueryResponder(identity:.xterm256Color,policy:.conservativeDefault);XCTAssertEqual(r.process(Data("\u{1b}[?2031$p".utf8)).replies,Data("\u{1b}[?2031;2$y".utf8));_ = r.process(Data("\u{1b}[?2031h".utf8));XCTAssertEqual(r.process(Data("\u{1b}[?2031$p".utf8)).replies,Data("\u{1b}[?2031;1$y".utf8))}
 func testUnknownDECRQMForwarded(){let r=VTQueryResponder(identity:.xterm256Color,policy:.conservativeDefault);let x=r.process(Data("\u{1b}[?999$p".utf8));XCTAssertEqual(x.forward,Data("\u{1b}[?999$p".utf8));XCTAssertTrue(x.replies.isEmpty)}
}
