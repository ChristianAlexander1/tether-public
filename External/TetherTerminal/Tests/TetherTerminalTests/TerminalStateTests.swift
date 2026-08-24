//
//  TerminalStateTests.swift
//  TetherTerminalTests
//
//  Integration tests that drive a TerminalState / Terminal with escape sequences
//  and assert on the resulting screen, cursor, and modes.
//

import XCTest
@testable import TetherTerminal

final class TerminalStateTests: XCTestCase {

    // MARK: - The headline cases from the spec

    func testDECSET2031DoesNotThrowAndLeavesNoTrace() {
        let t = Terminal(columns: 80, rows: 24)
        t.feed("\u{1B}[?2031h")
        // Mode is recorded (we know about it) but it has no effect on the screen.
        XCTAssertTrue(t.state.decModes.contains(2031))
        XCTAssertEqual(t.row(0), "")
        // Cursor still at home.
        XCTAssertEqual(t.cursorPosition.row, 0)
        XCTAssertEqual(t.cursorPosition.column, 0)
    }

    func testDECRST2031DoesNotThrow() {
        let t = Terminal()
        t.feed("\u{1B}[?2031h\u{1B}[?2031l")
        XCTAssertFalse(t.state.decModes.contains(2031))
    }

    func testClearScreenAndHome() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("some text")
        t.feed("\u{1B}[2J\u{1B}[H")
        XCTAssertEqual(t.row(0), "")
        XCTAssertEqual(t.cursorPosition, CursorPosition(row: 0, column: 0))
    }

    func testRedThenResetSGR() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("\u{1B}[31mred\u{1B}[0m")
        // "red" written at row 0.
        XCTAssertEqual(t.row(0), "red")
        // The 'r' has red foreground; the cell after reset (none) should not.
        let rCell = t.state.cellAt(row: 0, column: 0)
        XCTAssertEqual(rCell?.attributes.foreground, .red)
        // After ESC[0m the current attributes are cleared.
        t.feed("x")
        let xCell = t.state.cellAt(row: 0, column: 3)
        XCTAssertNil(xCell?.attributes.foreground)
    }

    func testSplitSequenceAcrossTwoWritesStillValid() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("hello\u{1B}[3")
        t.feed("2mgreen")
        XCTAssertEqual(t.row(0), "hellogreen")
        let gCell = t.state.cellAt(row: 0, column: 5) // 'g'
        XCTAssertEqual(gCell?.attributes.foreground, .green)
    }

    // MARK: - Cursor movement

    func testCursorUpDownForwardBackward() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("\u{1B}[3B") // down 3
        XCTAssertEqual(t.cursorPosition.row, 3)
        t.feed("\u{1B}[2A") // up 2
        XCTAssertEqual(t.cursorPosition.row, 1)
        t.feed("\u{1B}[5C") // right 5 (clamped to width)
        XCTAssertEqual(t.cursorPosition.column, 5)
        t.feed("\u{1B}[2D") // left 2
        XCTAssertEqual(t.cursorPosition.column, 3)
    }

    func testCursorPositionCommand() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("\u{1B}[4;10H")
        XCTAssertEqual(t.cursorPosition, CursorPosition(row: 3, column: 9)) // 1-based -> 0-based
    }

    func testCursorToColumnAndRow() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("\u{1B}[2;5H")
        t.feed("\u{1B}[8G") // column 8
        XCTAssertEqual(t.cursorPosition.column, 7)
        t.feed("\u{1B}[3d") // row 3
        XCTAssertEqual(t.cursorPosition.row, 2)
    }

    func testSaveRestoreCursorEsc7Esc8() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("\u{1B}[3;4H\u{1B}7\u{1B}[10;20H\u{1B}8")
        XCTAssertEqual(t.cursorPosition, CursorPosition(row: 2, column: 3))
    }

    func testCursorMovementClampsToGrid() {
        let t = Terminal(columns: 10, rows: 3)
        t.feed("\u{1B}[999;999H")
        XCTAssertEqual(t.cursorPosition, CursorPosition(row: 2, column: 9))
        t.feed("\u{1B}[999A")
        XCTAssertEqual(t.cursorPosition.row, 0)
    }

    // MARK: - Text / line editing

    func testLineFeedAndCarriageReturn() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("line1\r\nline2")
        XCTAssertEqual(t.row(0), "line1")
        XCTAssertEqual(t.row(1), "line2")
    }

    func testWrappingAtRightMargin() {
        let t = Terminal(columns: 5, rows: 3)
        t.feed("abcdefghij")
        XCTAssertEqual(t.row(0), "abcde")
        XCTAssertEqual(t.row(1), "fghij")
    }

    func testEraseLineFromCursorToEnd() {
        let t = Terminal(columns: 20, rows: 2)
        t.feed("hello world")
        t.feed("\r\u{1B}[5C") // CR then right 5 -> column 5
        t.feed("\u{1B}[0K")  // erase from cursor to end of line
        XCTAssertEqual(t.row(0), "hello")
    }

    func testEraseLineFromStartToCursor() {
        let t = Terminal(columns: 10, rows: 2)
        t.feed("hello")
        t.feed("\u{1B}[1K")
        // Cursor at column 5; cells 0..5 erased.
        let cell0 = t.state.cellAt(row: 0, column: 0)
        XCTAssertEqual(cell0?.character, " ")
    }

    func testEraseInDisplayFromCursorDown() {
        let t = Terminal(columns: 10, rows: 3)
        t.feed("row0\r\nrow1\r\nrow2")
        t.feed("\u{1B}[1;1H")
        t.feed("\u{1B}[J")
        XCTAssertEqual(t.row(0), "")
        XCTAssertEqual(t.row(1), "")
        XCTAssertEqual(t.row(2), "")
    }

    func testInsertDeleteCharacters() {
        let t = Terminal(columns: 12, rows: 2)
        t.feed("0123456789")
        t.feed("\r\u{1B}[3C")  // cursor at col 3 (at '3')
        t.feed("\u{1B}[2@")    // insert 2 blanks
        XCTAssertEqual(t.row(0), "012  3456789")
        t.feed("\u{1B}[2P")    // delete the 2 blanks -> restores
        XCTAssertEqual(t.row(0), "0123456789")
    }

    func testInsertDeleteLines() {
        let t = Terminal(columns: 10, rows: 4)
        t.feed("AAA\r\nBBB\r\nCCC\r\nDDD")
        t.feed("\u{1B}[2;1H") // row 2 (index 1)
        t.feed("\u{1B}[L")    // insert line; DDD scrolls off the bottom
        XCTAssertEqual(t.row(0), "AAA")
        XCTAssertEqual(t.row(1), "")
        XCTAssertEqual(t.row(2), "BBB")
        XCTAssertEqual(t.row(3), "CCC")
        t.feed("\u{1B}[M")    // delete the blank line
        XCTAssertEqual(t.row(1), "BBB")
        XCTAssertEqual(t.row(2), "CCC")
        XCTAssertEqual(t.row(3), "") // blank drawn at bottom
    }

    func testScrollingAtBottomMargin() {
        let t = Terminal(columns: 10, rows: 3)
        // Use CR+LF (the network newline) so each line starts at column 0, just
        // like a real CLI stream.
        t.feed("AAA\r\nBBB\r\nCCC\r\nDDD")
        // After three newlines the screen scrolls up one line.
        XCTAssertEqual(t.row(0), "BBB")
        XCTAssertEqual(t.row(1), "CCC")
        XCTAssertEqual(t.row(2), "DDD")
    }

    func testBackspaceMovesCursorBack() {
        let t = Terminal(columns: 10, rows: 2)
        t.feed("abc")
        t.feed([0x08, 0x08]) // two backspaces
        t.feed("X")
        // "aXc" — X overwrites 'b'.
        XCTAssertEqual(t.row(0), "aXc")
    }

    // MARK: - Colors / SGR

    func test256ColorForeground() {
        let t = Terminal(columns: 10, rows: 1)
        t.feed("\u{1B}[38;5;200mX")
        let cell = t.state.cellAt(row: 0, column: 0)
        XCTAssertEqual(cell?.attributes.foreground, .indexed(200))
    }

    func test24BitRGBBackground() {
        let t = Terminal(columns: 10, rows: 1)
        t.feed("\u{1B}[48;2;10;20;30mY")
        let cell = t.state.cellAt(row: 0, column: 0)
        XCTAssertEqual(cell?.attributes.background, .rgb(red: 10, green: 20, blue: 30))
    }

    func testBrightAndBoldSGR() {
        let t = Terminal(columns: 10, rows: 1)
        t.feed("\u{1B}[1;96mZ")
        let cell = t.state.cellAt(row: 0, column: 0)
        XCTAssertTrue(cell?.attributes.bold ?? false)
        XCTAssertEqual(cell?.attributes.foreground, .palette(14)) // bright cyan
    }

    func testDefaultColorCodes39And49() {
        let t = Terminal(columns: 10, rows: 1)
        t.feed("\u{1B}[31;41m\u{1B}[39;49mZ")
        let cell = t.state.cellAt(row: 0, column: 0)
        XCTAssertNil(cell?.attributes.foreground)
        XCTAssertNil(cell?.attributes.background)
    }

    // MARK: - Alternate screen 1049

    func testAlternateScreenSwitchSavesAndRestores() {
        let t = Terminal(columns: 20, rows: 5)
        t.feed("primary content")
        t.feed("\u{1B}[?1049h")
        XCTAssertTrue(t.alternateScreenActive)
        XCTAssertEqual(t.row(0), "") // blank alt screen
        XCTAssertEqual(t.cursorPosition, CursorPosition(row: 0, column: 0))
        t.feed("alt stuff")
        XCTAssertEqual(t.row(0), "alt stuff")
        t.feed("\u{1B}[?1049l")
        XCTAssertFalse(t.alternateScreenActive)
        XCTAssertEqual(t.row(0), "primary content")
    }

    // MARK: - Bracketed paste 2004

    func testBracketedPasteModeToggle() {
        let t = Terminal()
        XCTAssertFalse(t.bracketedPaste)
        t.feed("\u{1B}[?2004h")
        XCTAssertTrue(t.bracketedPaste)
        t.feed("\u{1B}[?2004l")
        XCTAssertFalse(t.bracketedPaste)
    }

    // MARK: - Window title OSC

    func testWindowTitleSetByOSC2() {
        let t = Terminal()
        t.feed("\u{1B}]2;Hello World\u{07}")
        XCTAssertEqual(t.title, "Hello World")
    }

    func testWindowTitleSetByOSC0ST() {
        let t = Terminal()
        t.feed("\u{1B}]0;Title!\u{1B}\\")
        XCTAssertEqual(t.title, "Title!")
    }

    // MARK: - Resize

    func testResizeDefault80Columns() {
        let t = Terminal()
        XCTAssertEqual(t.columns, 80)
        XCTAssertEqual(t.rows, 24)
    }

    func testResizeViaCSI8t() {
        let t = Terminal(columns: 80, rows: 24)
        t.feed("\u{1B}[8;30;100t")
        XCTAssertEqual(t.rows, 30)
        XCTAssertEqual(t.columns, 100)
    }

    func testResizeMethodPreservesContent() {
        let t = Terminal(columns: 10, rows: 3)
        t.feed("abc")
        t.resize(columns: 20, rows: 5)
        XCTAssertEqual(t.columns, 20)
        XCTAssertEqual(t.rows, 5)
        XCTAssertEqual(t.row(0), "abc")
    }

    // MARK: - Scroll region

    func testScrollRegionAndIndex() {
        let t = Terminal(columns: 10, rows: 5)
        t.feed("\u{1B}[2;4r") // scroll region rows 2..4
        t.feed("\u{1B}[4;1H") // go row 4
        t.feed("\n")          // index within region -> scrolls
        XCTAssertEqual(t.state.scrollTop, 1)
        XCTAssertEqual(t.state.scrollBottom, 3)
    }

    // MARK: - Hard reset

    func testHardResetEscC() {
        let t = Terminal(columns: 10, rows: 3)
        t.feed("data\u{1B}[31m\u{1B}[?2004h")
        t.feed("\u{1B}c")
        XCTAssertEqual(t.row(0), "")
        XCTAssertFalse(t.bracketedPaste)
        XCTAssertNil(t.state.cellAt(row: 0, column: 0)?.attributes.foreground)
        XCTAssertEqual(t.cursorPosition, CursorPosition(row: 0, column: 0))
    }

    // MARK: - Unknown / malformed robustness at Terminal level

    func testUnknownModesAndCommandsDoNotCrashTerminal() {
        let t = Terminal(columns: 40, rows: 10)
        t.feed("\u{1B}[?9999h")           // unknown DECSET
        t.feed("\u{1B}[?7777x")           // unknown private final byte
        t.feed("\u{1B}[1;2;3Z")           // unknown CSI final
        t.feed("\u{1B}]9999;ignore\u{07}") // unknown OSC
        t.feed("still works")
        XCTAssertEqual(t.row(0), "still works")
    }

    func testFeedingDataVariantWorks() {
        let t = Terminal(columns: 20, rows: 2)
        let data = Data("hello".utf8)
        t.feed(data)
        XCTAssertEqual(t.row(0), "hello")
    }

    func testOnChangeCallbackFires() {
        let t = Terminal(columns: 10, rows: 2)
        var count = 0
        t.state.onChange = { count += 1 }
        t.feed("a")
        t.feed("b")
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - UTF-8 through the terminal

    func testUTF8TextRendersCorrectly() {
        let t = Terminal(columns: 20, rows: 2)
        t.feed("héllo—世界 🌍")
        t.flush()
        XCTAssertEqual(t.row(0), "héllo—世界 🌍")
    }

    // MARK: - Insert/delete lines respect the scroll region

    func testInsertLineIgnoredWhenCursorOutsideScrollRegion() {
        let t = Terminal(columns: 10, rows: 5)
        t.feed("AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE")
        t.feed("\u{1B}[2;4r")     // scroll region rows 2..4 (indices 1..3)
        t.feed("\u{1B}[5;1H")     // cursor at row 5 (index 4) — outside region
        t.feed("\u{1B}[L")        // IL must be ignored
        XCTAssertEqual(t.row(0), "AAA")
        XCTAssertEqual(t.row(1), "BBB")
        XCTAssertEqual(t.row(2), "CCC")
        XCTAssertEqual(t.row(3), "DDD")
        XCTAssertEqual(t.row(4), "EEE")
    }

    func testDeleteLineIgnoredWhenCursorOutsideScrollRegion() {
        let t = Terminal(columns: 10, rows: 5)
        t.feed("AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE")
        t.feed("\u{1B}[2;4r")
        t.feed("\u{1B}[1;1H")     // row 1 (index 0) — outside region
        t.feed("\u{1B}[M")        // DL must be ignored
        XCTAssertEqual(t.row(0), "AAA")
        XCTAssertEqual(t.row(1), "BBB")
        XCTAssertEqual(t.row(4), "EEE")
    }

    // MARK: - Vertical tab (0x0B) is treated as LF

    func testVerticalTabMovesCursorDown() {
        let t = Terminal(columns: 10, rows: 3)
        t.feed("ab\r")
        t.feed([0x0B]) // VT — treated as LF
        t.feed("cd")
        XCTAssertEqual(t.row(0), "ab")
        XCTAssertEqual(t.row(1), "cd")
    }
}
