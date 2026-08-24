//
//  TerminalState.swift
//  TetherTerminal
//
//  Maintains a VT100/xterm screen model driven by decoded escape commands.
//

import Foundation

/// Mutable terminal state: grid, cursor, attributes, modes, scroll region.
///
/// `TerminalState` is itself an `EscapeSequenceParserDelegate`, so it can be
/// plugged directly into an `EscapeSequenceParser`:
///
/// ```swift
/// let terminal = TerminalState(columns: 80, rows: 24)
/// parser.delegate = terminal
/// parser.feed(data)
/// ```
public final class TerminalState: EscapeSequenceParserDelegate {

    // MARK: Grid storage

    /// Rows of cells. Indexed `[row][column]`, both zero-based.
    private(set) public var grid: [[Cell]]

    /// Number of columns (width).
    private(set) public var columns: Int

    /// Number of rows (height).
    private(set) public var rows: Int

    // MARK: Cursor

    /// Cursor column (0-based).
    private(set) public var cursorColumn: Int = 0
    /// Cursor row (0-based).
    private(set) public var cursorRow: Int = 0
    /// Whether the cursor is visible.
    public var cursorVisible: Bool = true

    // MARK: Attributes / modes

    /// Current graphic rendition applied to newly written cells.
    private(set) public var currentAttributes: SGRAttributes = SGRAttributes()

    /// DEC private modes that have been SET.
    private(set) public var decModes: Set<Int> = []

    /// Saved cursor position/attributes (DECSC/DECRC).
    private struct SavedCursor {
        var row: Int
        var column: Int
        var attributes: SGRAttributes
        var originMode: Bool
    }
    private var savedCursor: SavedCursor?

    /// DEC origin mode (cursor addressing relative to scroll region).
    private var originMode: Bool = false

    /// Auto-wrap mode (DECAWM). On by default.
    public var autoWrap: Bool = true

    /// True when the last printed character reached the right margin and the
    /// next printable character should wrap to the next line.
    private var pendingWrap: Bool = false

    // MARK: Scroll region

    /// Top of the scroll region (0-based, inclusive).
    private(set) public var scrollTop: Int = 0
    /// Bottom of the scroll region (0-based, inclusive).
    private(set) public var scrollBottom: Int

    // MARK: Tabs

    private var tabStops: [Bool]

    // MARK: Titles / paste

    /// Most recent window title set by OSC 0 / OSC 2.
    private(set) public var windowTitle: String = ""

    /// True when bracketed-paste mode (DECSET 2004) is active.
    public var bracketedPaste: Bool { decModes.contains(2004) }

    /// True when the alternate-screen buffer is active (DECSET 1049).
    private(set) public var alternateScreenActive: Bool = false

    /// Saved primary grid for alternate-screen switching.
    private var savedPrimaryGrid: [[Cell]]?
    private var savedPrimaryCursorRow: Int = 0
    private var savedPrimaryCursorColumn: Int = 0

    // MARK: Observation

    /// Closure called whenever the visible screen changes (text or cursor).
    public var onChange: (() -> Void)?
    /// Closure called when the window title changes.
    public var onTitleChange: ((String) -> Void)?

    // MARK: Init

    public init(columns: Int = 80, rows: Int = 24) {
        precondition(columns > 0 && rows > 0, "terminal size must be positive")
        self.columns = columns
        self.rows = rows
        self.scrollBottom = rows - 1
        self.grid = TerminalState.makeGrid(columns: columns, rows: rows)
        var tabs = [Bool](repeating: false, count: max(columns, 1))
        var col = 0
        while col < tabs.count {
            tabs[col] = true
            col += 8
        }
        self.tabStops = tabs
    }

    private static func makeGrid(columns: Int, rows: Int) -> [[Cell]] {
        let blank = Cell()
        return (0..<rows).map { _ in [Cell](repeating: blank, count: columns) }
    }

    // MARK: Resize

    /// Resize the terminal, preserving as much on-screen content as possible.
    public func resize(columns newColumns: Int, rows newRows: Int) {
        precondition(newColumns > 0 && newRows > 0)
        let blank = Cell()
        // Rebuild rows.
        var newGrid = [[Cell]]()
        newGrid.reserveCapacity(newRows)
        for r in 0..<newRows {
            if r < grid.count {
                var row = grid[r]
                if row.count < newColumns {
                    row.append(contentsOf: [Cell](repeating: blank, count: newColumns - row.count))
                } else if row.count > newColumns {
                    row = [Cell](row.prefix(newColumns))
                }
                newGrid.append(row)
            } else {
                newGrid.append([Cell](repeating: blank, count: newColumns))
            }
        }
        grid = newGrid
        columns = newColumns
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = min(cursorRow, newRows - 1)
        cursorColumn = min(cursorColumn, newColumns - 1)
        // Rebuild tab stops for the new width.
        var tabs = [Bool](repeating: false, count: newColumns)
        var col = 0
        while col < tabs.count { tabs[col] = true; col += 8 }
        tabStops = tabs
        notifyChange()
    }

    /// Reset the terminal to its initial state (like ESC c — RIS).
    public func hardReset() {
        grid = TerminalState.makeGrid(columns: columns, rows: rows)
        cursorRow = 0
        cursorColumn = 0
        currentAttributes = SGRAttributes()
        decModes.removeAll()
        originMode = false
        autoWrap = true
        pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
        savedCursor = nil
        alternateScreenActive = false
        savedPrimaryGrid = nil
        cursorVisible = true
        notifyChange()
    }

    // MARK: Text rendering

    public func parser(_ parser: EscapeSequenceParser, didReadText text: String) {
        for ch in text {
            putCharacter(ch)
        }
        notifyChange()
    }

    private func putCharacter(_ ch: Character) {
        if pendingWrap && autoWrap {
            newline()
            cursorColumn = 0
            pendingWrap = false
        }
        if cursorColumn >= columns {
            if autoWrap {
                newline()
                cursorColumn = 0
            } else {
                cursorColumn = columns - 1
            }
        }
        grid[cursorRow][cursorColumn] = Cell(character: ch, attributes: currentAttributes)
        cursorColumn += 1
        if cursorColumn >= columns {
            // At right margin; wrap on the *next* printable character.
            pendingWrap = true
            cursorColumn = columns - 1
        }
    }

    // MARK: C0 controls

    public func parser(_ parser: EscapeSequenceParser, didReadControl byte: UInt8) {
        switch byte {
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            newline()
        case 0x0D: // CR
            cursorColumn = 0
            pendingWrap = false
        case 0x08: // BS
            if cursorColumn > 0 { cursorColumn -= 1 }
            pendingWrap = false
        case 0x09: // TAB
            var c = cursorColumn + 1
            while c < columns && !tabStops[c] { c += 1 }
            cursorColumn = min(c, columns - 1)
        default:
            break
        }
        notifyChange()
    }

    private func newline() {
        if cursorRow == scrollBottom {
            scrollUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    /// Scroll the scroll region up by one line (new blank line at bottom).
    private func scrollUp(lines: Int = 1) {
        let n = min(lines, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            for r in scrollTop..<scrollBottom {
                grid[r] = grid[r + 1]
            }
            let blank = Cell()
            grid[scrollBottom] = [Cell](repeating: blank, count: columns)
        }
    }

    /// Scroll the scroll region down by one line (new blank line at top).
    private func scrollDown(lines: Int = 1) {
        let n = min(lines, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            var r = scrollBottom
            while r > scrollTop {
                grid[r] = grid[r - 1]
                r -= 1
            }
            let blank = Cell()
            grid[scrollTop] = [Cell](repeating: blank, count: columns)
        }
    }

    // MARK: CSI dispatch

    public func parser(_ parser: EscapeSequenceParser, didReadCSI command: CSICommand) {
        // Private/DEC sequences (start with '?'). These must NEVER crash — unknown
        // final bytes fall through and are ignored safely.
        if command.isPrivate {
            handlePrivateCSI(command)
            notifyChange()
            return
        }

        let ch = Character(Unicode.Scalar(command.finalByte))
        switch ch {
        case "A": cursorUp(command.parameter(0, default: 1))
        case "B": cursorDown(command.parameter(0, default: 1))
        case "C": cursorForward(command.parameter(0, default: 1))
        case "D": cursorBackward(command.parameter(0, default: 1))
        case "E": cursorNextLine(command.parameter(0, default: 1))
        case "F": cursorPreviousLine(command.parameter(0, default: 1))
        case "G": cursorToColumn(command.parameter(0, default: 1) - 1)
        case "H", "f":
            let row = command.parameter(0, default: 1) - 1
            let col = command.parameter(1, default: 1) - 1
            cursorTo(row: row, column: col)
        case "J": eraseInDisplay(mode: command.parameter(0, default: 0))
        case "K": eraseInLine(mode: command.parameter(0, default: 0))
        case "L": insertLines(command.parameter(0, default: 1))
        case "M": deleteLines(command.parameter(0, default: 1))
        case "P": deleteCharacters(command.parameter(0, default: 1))
        case "@": insertCharacters(command.parameter(0, default: 1))
        case "X": eraseCharacters(command.parameter(0, default: 1))
        case "S": scrollUp(lines: command.parameter(0, default: 1))
        case "T": scrollDown(lines: command.parameter(0, default: 1))
        case "r": setScrollRegion(top: command.parameter(0, default: 1),
                                  bottom: command.parameter(1, default: rows))
        case "m": applySGR(command)
        case "t": handleWindowCSI(command)
        case "d": cursorToRow(command.parameter(0, default: 1) - 1)
        case "`": cursorToColumn(command.parameter(0, default: 1) - 1)
        case "h": // SET modes (non-private; mostly ignored)
            break
        case "l": // RESET modes (non-private; mostly ignored)
            break
        case "n", "c", "u", "s", "q", ">", "=", "<", "?":
            // Device status / device attrs / save-restore / others — safe ignore.
            break
        default:
            // Unknown CSI final byte — safe ignore (this is the core
            // "never crash on unknown sequences" guarantee).
            break
        }
        notifyChange()
    }

    // MARK: Private (DEC) CSI — the heart of DECSET 2031 safety

    private func handlePrivateCSI(_ command: CSICommand) {
        let ch = Character(Unicode.Scalar(command.finalByte))
        let mode = command.parameter(0, default: 0)

        switch ch {
        case "h": // DECSET — enable mode
            decModes.insert(mode)
            handleKnownModeSet(mode)
        case "l": // DECRST — disable mode
            decModes.remove(mode)
            handleKnownModeReset(mode)
        case "r", "m", "y", "n", "s", "t", "L", "F", "G", "`":
            // Various DEC private reports/queries (e.g. DECSTBM, DECPCTERM,
            // XTerm resources). We do not support responses; ignore safely.
            break
        default:
            // Unknown DEC private final byte (e.g. anything attached to 2031 we
            // don't model) — **explicitly ignored**, never throws.
            break
        }
    }

    private func handleKnownModeSet(_ mode: Int) {
        switch mode {
        case 1049:
            enableAlternateScreen()
        case 2004:
            break // tracked via decModes
        case 25:
            cursorVisible = true
        case 1000...1015, 1006:
            break // mouse tracking modes — accepted, no crash
        case 47, 1047, 1048:
            break // alternate screen variants — accepted
        case 1, 6, 7:
            if mode == 6 { originMode = true }
            if mode == 7 { autoWrap = true }
        case 2031:
            // DECSET 2031: "Unhandled" in the upstream TUI. We accept it and do
            // nothing — the whole point is that this must not crash or smash text.
            break
        default:
            break // unknown mode — safe ignore
        }
    }

    private func handleKnownModeReset(_ mode: Int) {
        switch mode {
        case 1049:
            disableAlternateScreen()
        case 25:
            cursorVisible = false
        case 6:
            originMode = false
        case 7:
            autoWrap = false
        case 2031:
            break // safe ignore on reset too
        default:
            break
        }
    }

    // MARK: Alternate screen (1049)

    private func enableAlternateScreen() {
        guard !alternateScreenActive else { return }
        savedPrimaryGrid = grid
        savedPrimaryCursorRow = cursorRow
        savedPrimaryCursorColumn = cursorColumn
        grid = TerminalState.makeGrid(columns: columns, rows: rows)
        cursorRow = 0
        cursorColumn = 0
        alternateScreenActive = true
    }

    private func disableAlternateScreen() {
        guard alternateScreenActive else { return }
        if let saved = savedPrimaryGrid { grid = saved }
        cursorRow = savedPrimaryCursorRow
        cursorColumn = savedPrimaryCursorColumn
        savedPrimaryGrid = nil
        alternateScreenActive = false
    }

    // MARK: Cursor movement

    private func clampCursor() {
        cursorRow = min(max(cursorRow, 0), rows - 1)
        cursorColumn = min(max(cursorColumn, 0), columns - 1)
        pendingWrap = false
    }

    private func cursorUp(_ n: Int) {
        cursorRow = max(cursorRow - max(n, 1), originMode ? scrollTop : 0)
        pendingWrap = false
    }
    private func cursorDown(_ n: Int) {
        let bottom = originMode ? scrollBottom : rows - 1
        cursorRow = min(cursorRow + max(n, 1), bottom)
        pendingWrap = false
    }
    private func cursorForward(_ n: Int) {
        pendingWrap = false
        cursorColumn = min(cursorColumn + max(n, 1), columns - 1)
    }
    private func cursorBackward(_ n: Int) {
        cursorColumn = max(cursorColumn - max(n, 1), 0)
        pendingWrap = false
    }
    private func cursorNextLine(_ n: Int) {
        cursorDown(n)
        cursorColumn = 0
    }
    private func cursorPreviousLine(_ n: Int) {
        cursorUp(n)
        cursorColumn = 0
    }
    private func cursorToRow(_ row: Int) {
        cursorRow = min(max(row, 0), rows - 1)
        pendingWrap = false
    }
    private func cursorToColumn(_ col: Int) {
        cursorColumn = min(max(col, 0), columns - 1)
        pendingWrap = false
    }
    private func cursorTo(row: Int, column: Int) {
        if originMode {
            cursorRow = min(max(row, 0) + scrollTop, scrollBottom)
        } else {
            cursorRow = min(max(row, 0), rows - 1)
        }
        cursorColumn = min(max(column, 0), columns - 1)
        pendingWrap = false
    }

    // MARK: Erase / edit

    private func blankLine() -> [Cell] {
        [Cell](repeating: Cell(), count: columns)
    }

    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 0: // cursor to end
            eraseInLine(mode: 0)
            if cursorRow + 1 < rows {
                for r in (cursorRow + 1)..<rows { grid[r] = blankLine() }
            }
        case 1: // start to cursor
            for c in 0...cursorColumn { grid[cursorRow][c] = Cell() }
            if cursorRow > 0 {
                for r in 0..<cursorRow { grid[r] = blankLine() }
            }
        case 2, 3: // whole screen (and scrollback, which we don't model)
            grid = TerminalState.makeGrid(columns: columns, rows: rows)
        default:
            break
        }
    }

    private func eraseInLine(mode: Int) {
        switch mode {
        case 0: // cursor to end
            for c in cursorColumn..<columns { grid[cursorRow][c] = Cell() }
        case 1: // start to cursor
            for c in 0...cursorColumn { grid[cursorRow][c] = Cell() }
        case 2: // whole line
            grid[cursorRow] = blankLine()
        default:
            break
        }
    }

    private func eraseCharacters(_ n: Int) {
        let count = min(max(n, 1), columns - cursorColumn)
        for c in cursorColumn..<(cursorColumn + count) { grid[cursorRow][c] = Cell() }
    }

    private func insertCharacters(_ n: Int) {
        guard cursorColumn < columns else { return }
        let count = min(max(n, 1), columns - cursorColumn)
        // Shift cells right; cells pushed past the right margin are discarded.
        for c in stride(from: columns - 1, through: cursorColumn + count, by: -1) {
            grid[cursorRow][c] = grid[cursorRow][c - count]
        }
        for c in cursorColumn..<min(cursorColumn + count, columns) {
            grid[cursorRow][c] = Cell()
        }
    }

    private func deleteCharacters(_ n: Int) {
        guard cursorColumn < columns else { return }
        let count = min(max(n, 1), columns - cursorColumn)
        // Shift cells left from the right of the deletion range.
        for c in cursorColumn..<(columns - count) {
            grid[cursorRow][c] = grid[cursorRow][c + count]
        }
        for c in (columns - count)..<columns { grid[cursorRow][c] = Cell() }
    }

    private func insertLines(_ n: Int) {
        // Per xterm: IL/DH is ignored if the cursor is outside the scroll region.
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let count = min(max(n, 1), scrollBottom - cursorRow + 1)
        for _ in 0..<count {
            var r = scrollBottom
            while r > cursorRow { grid[r] = grid[r - 1]; r -= 1 }
            grid[cursorRow] = blankLine()
        }
        cursorColumn = 0
    }

    private func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let count = min(max(n, 1), scrollBottom - cursorRow + 1)
        for _ in 0..<count {
            var r = cursorRow
            while r < scrollBottom { grid[r] = grid[r + 1]; r += 1 }
            grid[scrollBottom] = blankLine()
        }
        cursorColumn = 0
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        var t = max(top - 1, 0)
        var b = min(bottom - 1, rows - 1)
        if t > b { swap(&t, &b) }
        if t == b { t = 0; b = rows - 1 }
        scrollTop = t
        scrollBottom = b
        cursorRow = 0
        cursorColumn = 0
    }

    // MARK: SGR colors

    private func applySGR(_ command: CSICommand) {
        let params = command.numericParameters
        if params.isEmpty {
            currentAttributes = SGRAttributes()
            return
        }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentAttributes = SGRAttributes()
            case 1: currentAttributes.bold = true
            case 2: currentAttributes.faint = true
            case 3: currentAttributes.italic = true
            case 4: currentAttributes.underline = true
            case 5, 6: currentAttributes.blink = true
            case 7: currentAttributes.inverse = true
            case 8: currentAttributes.hidden = true
            case 9: currentAttributes.strikethrough = true
            case 21: currentAttributes.bold = false
            case 22: currentAttributes.bold = false; currentAttributes.faint = false
            case 23: currentAttributes.italic = false
            case 24: currentAttributes.underline = false
            case 25: currentAttributes.blink = false
            case 27: currentAttributes.inverse = false
            case 28: currentAttributes.hidden = false
            case 29: currentAttributes.strikethrough = false
            case 30...37:
                currentAttributes.foreground = .palette(p - 30)
            case 39:
                currentAttributes.foreground = nil
            case 40...47:
                currentAttributes.background = .palette(p - 40)
            case 49:
                currentAttributes.background = nil
            case 90...97:
                currentAttributes.foreground = .palette(p - 90 + 8)
            case 100...107:
                currentAttributes.background = .palette(p - 100 + 8)
            case 38:
                // Extended foreground: 38;5;n  or 38;2;r;g;b
                if let (color, advanced) = parseExtendedColor(params: params, index: i) {
                    currentAttributes.foreground = color
                    i = advanced
                }
            case 48:
                if let (color, advanced) = parseExtendedColor(params: params, index: i) {
                    currentAttributes.background = color
                    i = advanced
                }
            default:
                break // unknown SGR — safe ignore
            }
            i += 1
        }
    }

    /// Parses an extended color (`5;n` or `2;r;g;b`) following a 38/48 code.
    /// Returns the color and the index of the last consumed parameter.
    private func parseExtendedColor(params: [Int], index: Int) -> (AnsiColor, Int)? {
        let next = index + 1
        guard next < params.count else { return nil }
        switch params[next] {
        case 5: // 256-color: 38;5;n
            let ni = next + 1
            guard ni < params.count else { return nil }
            return (.indexed(params[ni]), ni)
        case 2: // RGB: 38;2;r;g;b
            let r = next + 1, g = r + 1, b = g + 1
            guard b < params.count else { return nil }
            return (.rgb(red: params[r], green: params[g], blue: params[b]), b)
        default:
            return nil
        }
    }

    // MARK: Window / resize CSI t

    private func handleWindowCSI(_ command: CSICommand) {
        // CSI 8 ; rows ; cols t — resize the window ("text area size").
        let op = command.parameter(0, default: 0)
        if op == 8 {
            let newRows = command.parameter(1, default: rows)
            let newCols = command.parameter(2, default: columns)
            if newRows > 0 && newCols > 0 && (newRows != rows || newCols != columns) {
                resize(columns: newCols, rows: newRows)
            }
        }
        // Other "t" operations (window state, title manipulation) are ignored.
    }

    // MARK: OSC

    public func parser(_ parser: EscapeSequenceParser, didReadOSC string: String) {
        // OSC format: "code;text". Common codes: 0 = icon+title, 2 = title.
        let parts = string.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let codeStr = parts.first, let code = Int(codeStr) else { return }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case 0, 2:
            windowTitle = value
            onTitleChange?(value)
        default:
            break // unknown OSC (color reports, etc.) — safe ignore
        }
    }

    public func parser(_ parser: EscapeSequenceParser, didReadEscape finalByte: UInt8) {
        switch finalByte {
        case 0x4D: // ESC M — reverse line feed
            if cursorRow == scrollTop { scrollDown() }
            else if cursorRow > 0 { cursorRow -= 1 }
        case 0x37: // ESC 7 — DECSC save cursor
            savedCursor = SavedCursor(row: cursorRow, column: cursorColumn,
                                      attributes: currentAttributes, originMode: originMode)
        case 0x38: // ESC 8 — DECRC restore cursor
            if let s = savedCursor {
                cursorRow = s.row
                cursorColumn = s.column
                currentAttributes = s.attributes
                originMode = s.originMode
                clampCursor()
            }
        case 0x63: // ESC c — RIS full reset
            hardReset()
        case 0x44: // ESC D — index (cursor down, scroll at bottom)
            newline()
        case 0x45: // ESC E — next line
            newline(); cursorColumn = 0
        default:
            break // unknown two-char escape — safe ignore
        }
        notifyChange()
    }

    public func parser(_ parser: EscapeSequenceParser, didReadCharsetDesignation finalByte: UInt8) {
        // Character set designation (ESC ( B etc.). We only support ASCII/UTF-8,
        // so these are accepted and ignored.
    }

    // MARK: Screen accessors

    /// Returns the rendered text of a single row, minus trailing spaces.
    public func textOfRow(_ row: Int) -> String {
        guard row >= 0 && row < grid.count else { return "" }
        let chars = grid[row].map { $0.character }
        var str = String(chars)
        while str.hasSuffix(" ") { str.removeLast() }
        return str
    }

    /// Returns the full visible screen as a newline-joined string.
    public func screenText(trimTrailingSpaces: Bool = true) -> String {
        let rows = grid.map { textOfRowTrim($0, trim: trimTrailingSpaces) }
        return rows.joined(separator: "\n")
    }

    private func textOfRowTrim(_ row: [Cell], trim: Bool) -> String {
        let chars = row.map { $0.character }
        var str = String(chars)
        if trim {
            while str.hasSuffix(" ") { str.removeLast() }
        }
        return str
    }

    /// Returns the cell at the given position, or nil if out of bounds.
    public func cellAt(row: Int, column: Int) -> Cell? {
        guard row >= 0 && row < grid.count else { return nil }
        guard column >= 0 && column < grid[row].count else { return nil }
        return grid[row][column]
    }

    // MARK: Change notification

    private func notifyChange() {
        onChange?()
    }
}
