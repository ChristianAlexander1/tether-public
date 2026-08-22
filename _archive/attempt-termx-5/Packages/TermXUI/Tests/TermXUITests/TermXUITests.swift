import XCTest
@testable import TermXUI

final class TermXUITests: XCTestCase {
    func testTerminalViewCanBeConstructed() { _ = TerminalView(cwd: NSTemporaryDirectory()) }
}
