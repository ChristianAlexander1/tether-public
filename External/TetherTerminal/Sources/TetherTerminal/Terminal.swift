//
//  Terminal.swift
//  TetherTerminal
//
//  High-level facade that couples an `EscapeSequenceParser` with a
//  `TerminalState`, so callers can feed raw bytes and read back the screen
//  without wiring delegates themselves.
//

import Foundation

/// A complete, self-contained terminal: parser + screen state.
///
/// ```swift
/// let terminal = Terminal(columns: 80, rows: 24)
/// terminal.feed("\u{1B}[31mred\u{1B}[0m")
/// print(terminal.text)
/// ```
public final class Terminal {

    /// The escape-sequence parser.
    public let parser: EscapeSequenceParser

    /// The mutable screen/cursor state.
    public let state: TerminalState

    /// Number of columns.
    public var columns: Int { state.columns }
    /// Number of rows.
    public var rows: Int { state.rows }

    /// The full visible screen as plain text (rows trimmed of trailing spaces).
    public var text: String { state.screenText() }

    /// Current window title (from OSC 0/2).
    public var title: String { state.windowTitle }

    /// Whether bracketed-paste mode (DECSET 2004) is active.
    public var bracketedPaste: Bool { state.bracketedPaste }

    /// Whether the alternate screen (DECSET 1049) is active.
    public var alternateScreenActive: Bool { state.alternateScreenActive }

    public init(columns: Int = 80, rows: Int = 24) {
        self.state = TerminalState(columns: columns, rows: rows)
        self.parser = EscapeSequenceParser()
        self.parser.delegate = state
    }

    /// Feed raw bytes.
    public func feed(_ bytes: [UInt8]) {
        parser.feed(bytes)
    }

    /// Feed raw `Data`.
    public func feed(_ data: Data) {
        parser.feed(data)
    }

    /// Feed a Swift string.
    public func feed(_ string: String) {
        parser.feed(string)
    }

    /// Flush any buffered text to the state.
    public func flush() {
        parser.flush()
    }

    /// Resize the terminal.
    public func resize(columns: Int, rows: Int) {
        state.resize(columns: columns, rows: rows)
    }

    /// Full reset (RIS).
    public func reset() {
        state.hardReset()
    }

    /// Returns the text of one row (trailing spaces removed).
    public func row(_ index: Int) -> String {
        state.textOfRow(index)
    }

    /// Returns the cursor position (0-based).
    public var cursorPosition: CursorPosition {
        CursorPosition(row: state.cursorRow, column: state.cursorColumn)
    }
}
