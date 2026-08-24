import XCTest
@testable import TetherShellLang

final class ArithmeticTests: XCTestCase {

    private var vars: [String: Int] = [:]

    private func eval(_ expr: String) throws -> Int {
        try Arithmetic.evaluate(expr,
            get: { self.vars[$0] ?? 0 },
            set: { self.vars[$0] = $1 })
    }

    func testPrecedence() throws {
        XCTAssertEqual(try eval("2 + 3 * 4"), 14)
        XCTAssertEqual(try eval("(2 + 3) * 4"), 20)
        XCTAssertEqual(try eval("10 / 3"), 3)
        XCTAssertEqual(try eval("10 % 3"), 1)
        XCTAssertEqual(try eval("-3 * 2"), -6)
        XCTAssertEqual(try eval("1 << 4"), 16)
        XCTAssertEqual(try eval("32 >> 3"), 4)
    }

    func testNumberBases() throws {
        XCTAssertEqual(try eval("0x10"), 16)
        XCTAssertEqual(try eval("010"), 8)
        XCTAssertEqual(try eval("16#ff"), 255)
        XCTAssertEqual(try eval("2#1010"), 10)
    }

    func testComparisonsAndLogic() throws {
        XCTAssertEqual(try eval("5 > 3"), 1)
        XCTAssertEqual(try eval("5 < 3"), 0)
        XCTAssertEqual(try eval("5 == 5"), 1)
        XCTAssertEqual(try eval("5 != 5"), 0)
        XCTAssertEqual(try eval("1 && 2"), 1)
        XCTAssertEqual(try eval("0 && 2"), 0)
        XCTAssertEqual(try eval("0 || 2"), 1)
        XCTAssertEqual(try eval("!7"), 0)
        XCTAssertEqual(try eval("!0"), 1)
        XCTAssertEqual(try eval("~0"), -1)
    }

    func testTernary() throws {
        XCTAssertEqual(try eval("1 ? 10 : 20"), 10)
        XCTAssertEqual(try eval("0 ? 10 : 20"), 20)
        vars["a"] = 3
        vars["b"] = 7
        XCTAssertEqual(try eval("a > b ? a : b"), 7)
    }

    func testAssignmentAndIncrement() throws {
        XCTAssertEqual(try eval("x = 5"), 5)
        XCTAssertEqual(vars["x"], 5)
        XCTAssertEqual(try eval("x += 3"), 8)
        XCTAssertEqual(try eval("x++"), 8)
        XCTAssertEqual(vars["x"], 9)
        XCTAssertEqual(try eval("++x"), 10)
        XCTAssertEqual(try eval("x *= 2"), 20)
        XCTAssertEqual(try eval("x %= 7"), 6)
    }

    func testVariablesDefaultToZero() throws {
        XCTAssertEqual(try eval("missing + unmising"), 0)
    }

    func testDivisionByZeroThrows() {
        XCTAssertThrowsError(try eval("1 / 0"))
        XCTAssertThrowsError(try eval("1 % 0"))
    }

    func testExponentiation() throws {
        XCTAssertEqual(try eval("2 ** 3"), 8)
        XCTAssertEqual(try eval("2 ** 3 ** 2"), 512)   // right associative
        XCTAssertEqual(try eval("3 ** 0"), 1)
        XCTAssertEqual(try eval("y = 2"), 2)
        XCTAssertEqual(try eval("y **= 4"), 16)
    }

    func testShortCircuitSkipsSideEffects() throws {
        vars["x"] = 0
        _ = try eval("0 && (x = 1)")
        XCTAssertEqual(vars["x"], 0)
        _ = try eval("1 || (x = 1)")
        XCTAssertEqual(vars["x"], 0)
    }
}
