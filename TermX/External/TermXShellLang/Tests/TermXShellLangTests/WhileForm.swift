import XCTest
@testable import TermXShellLang

final class WhileForm: XCTestCase {
    func testForms() throws {
        for src in ["while [ $i -lt 3 ]; do echo x; i=$((i+1)); done",
                    "i=0; while [ $i -lt 3 ]; do echo x; done",
                    "while cond\ndo\n echo x\ndone"] {
            let node = try? ScriptParser.parse(src)
            print("SRC=[\(src.prefix(40))] -> \(node == nil ? "NIL" : "PARSED")")
        }
    }
}
