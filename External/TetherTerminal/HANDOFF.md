# HANDOFF — TetherTerminal P9 (VT100/xterm parser)

## What this is

A standalone Swift package implementing a fault-tolerant VT100/xterm escape
sequence parser plus an in-memory terminal model. It was built to fix two
problems seen in the Claude Code TUI:

1. **Smashed CLI text** caused by escape sequences split across PTY reads and
   by mishandled newline/wrap behavior.
2. **`Unhandled DECSET 2031`** — the parser treated an unknown DEC private
   mode as an exception.

The parser now treats *all* unknown/truncated/malformed sequences as safe
no-ops, so neither problem can crash or corrupt the display.

This is the **isolated parser component only** (per the P9 brief). There is no
iOS app, no UIKit/SwiftUI, no `termx` naming.

## Requirements met

- ✅ Swift package `TetherTerminal` (library product + test target).
- ✅ No iOS UI / app target.
- ✅ `swift test` — **76 tests, all green** (requirement was 30+), in both
  debug and release builds, zero warnings.
- ✅ CSI cursor moves, SGR colors, erase.
- ✅ **DECSET/DECRST 2031** — safe ignore, no crash (dedicated tests).
- ✅ Alternate screen `1049` (save/restore primary buffer).
- ✅ Bracketed paste `2004`.
- ✅ UTF-8 text, including multibyte characters split across writes.
- ✅ Default **80 columns**; resize via API and via `CSI 8 ; rows ; cols t`.
- ✅ Split sequences across multiple writes reassemble correctly.
- ✅ Unknown DECSET/DECRST/CSI/OSC/DCS never crash (including a 5,000-byte
  deterministic fuzz test).
- ✅ C0 control handling: NUL ignored, DEL ignored, **CAN/SUB abort in-progress
  sequences**, BS/HT/LF/VT/FF/CR/BEL delivered, OSC/DCS strings preserved.
- ✅ IL/DL (`CSI L` / `CSI M`) correctly ignored when the cursor is outside the
  scroll region, matching xterm.
- ✅ No TODOs, no placeholders, no `fatalError`/force-unwraps on input paths.
- ✅ MIT `LICENSE`, `TERMINAL-PROTOCOL.md`, `README.md`, this `HANDOFF.md`.

## Package layout

```
TetherTerminal/
├── Package.swift
├── LICENSE                         (MIT)
├── TERMINAL-PROTOCOL.md            (sequence reference + architecture)
├── HANDOFF.md                      (this file)
├── Sources/TetherTerminal/
│   ├── ANSITypes.swift             (CSICommand, SGRAttributes, AnsiColor, Cell, CursorPosition, MouseEvent)
│   ├── EscapeSequenceParser.swift  (streaming state machine + delegate protocol)
│   ├── TerminalState.swift         (grid/cursor/modes/scroll/alt-screen; implements delegate)
│   └── Terminal.swift              (high-level facade: parser + state)
└── Tests/TetherTerminalTests/
    ├── EscapeSequenceParserTests.swift  (33 tests, incl. UTF-8 split & fuzz)
    └── TerminalStateTests.swift         (36 integration tests)
```

## How to build & test

Requires Swift 5.9+ (developed with Swift 6.0.3 on Linux; works on macOS too).

```bash
cd TetherTerminal
swift build
swift test
```

Expected output:

```
Test Suite 'EscapeSequenceParserTests' passed — Executed 37 tests, 0 failures
Test Suite 'TerminalStateTests' passed      — Executed 39 tests, 0 failures
Test Suite 'All tests' passed               — Executed 76 tests, 0 failures
```

## Quick start

```swift
import TetherTerminal

let terminal = Terminal(columns: 80, rows: 24)

// DECSET 2031 is accepted silently — no exception, no smashed text.
terminal.feed("\u{1B}[?2031h")

// SGR color + reset.
terminal.feed("\u{1B}[31mred\u{1B}[0m")
print(terminal.row(0))                       // "red"
terminal.state.cellAt(row: 0, column: 0)?
    .attributes.foreground                    // .palette(1) (.red)

// Clear + home, alternate screen, bracketed paste, resize.
terminal.feed("\u{1B}[2J\u{1B}[H")
terminal.feed("\u{1B}[?1049h")                // alt screen on
terminal.feed("\u{1B}[?2004h")                // bracketed paste on
terminal.bracketedPaste                       // true
terminal.feed("\u{1B}[8;40;120t")            // resize -> 40 rows, 120 cols
```

Feed data straight from a PTY — chunks may arrive at any byte boundary:

```swift
terminal.feed([0x1B])        // ESC alone
terminal.feed("[?2031")      // rest of the sequence later
terminal.feed("h")
```

Use just the low-level parser if you have your own screen model:

```swift
final class MyScreen: EscapeSequenceParserDelegate {
    let parser = EscapeSequenceParser()
    init() { parser.delegate = self }
    func parser(_ p: EscapeSequenceParser, didReadCSI c: CSICommand) { /* ... */ }
    // implement only the callbacks you need; the rest default to no-op
}
```

## Design notes

- **Fault tolerance by construction.** `EscapeSequenceParser` is a state
  machine. Any byte that doesn't fit the current production (garbage after ESC,
  unknown CSI final byte, unknown DEC private mode, truncated sequences) resets
  to `ground` rather than trapping. `TerminalState` then has an explicit
  `default: break` for every unknown code. There is no `throw` path on the
  feed API and no force-unwraps on byte input.
- **Streaming UTF-8.** Printable bytes are buffered and decoded incrementally.
  A leading byte whose continuation bytes haven't arrived yet stays buffered
  until the next `feed`; invalid bytes become `U+FFFD`. This is what allows
  `é` (or `🌍`) to be split across writes without corruption.
- **Unknown DEC private modes.** DECSET/DECRST simply record/remove the mode
  number in `decModes`; a small switch handles the modes Tether models
  (1049, 2004, 25, 6, 7, mouse modes, 2031). Everything else falls through.
- **Newlines.** `LF` moves down *without* resetting the column (VT behavior).
  The test suite uses `\r\n` (network newline) as real CLIs do. A host app that
  sees bare `\n` should translate it at the PTY boundary if its use case
  requires.
- **Alternate screen 1049** snapshots the primary grid + cursor on entry and
  restores them on exit, matching xterm.
- **Resize** (API or `CSI 8 t`) preserves content, clamps the cursor, rebuilds
  tab stops, and resets the scroll region.

## Coverage map (tests)

Required headline cases:
- `testDECSET2031DoesNotThrowAndLeavesNoTrace`
- `testDECRST2031DoesNotThrow`
- `testClearScreenAndHome`
- `testRedThenResetSGR`
- `testSplitSequenceAcrossTwoWritesStillValid`

Other coverage groups:
- Plain text, multiple feeds, NUL/DEL/BEL/CR/HT/BS controls.
- CAN (0x18) aborts an in-progress CSI; SUB (0x1A) is a control in ground and
  aborts sequences otherwise.
- Incomplete UTF-8 lead byte at an ESC boundary is flushed as U+FFFD rather
  than being held indefinitely.
- CSI: cursor up/down/forward/back, position, save/restore, clamp.
- SGR: 16 colors, bright/bold, 256-color, 24-bit RGB, defaults 39/49.
- Erase in display/line, insert/delete chars & lines, scroll at margin.
- DEC private modes: 1049 alt screen, 2004 bracketed paste, unknown modes.
- OSC 0/2 titles via BEL and ST; text resumes after OSC.
- DCS/SOS/PM/APC skipped; charset designation accepted; C1 CSI byte.
- UTF-8: one-shot, 2-byte split, 4-byte split, invalid-byte replacement.
- Split ESC, split CSI, truncated-then-completed sequence, `reset()`.
- Garbage-after-ESC and a 5,000-byte deterministic fuzz test.
- Resize: default 80 cols, `CSI 8 t`, API resize preserving content.
- Hard reset `ESC c`, change notification callback, `Data` feed variant.

## Known limitations / future work

These are intentional non-goals for P9 (parser component only):
- No scrollback buffer model (ED 3 clears screen only).
- No mouse event decoding beyond accepting the tracking modes; `MouseEvent`
  exists as a type but the parser does not yet parse `CSI <` mouse reports.
- No response generation (DSR/DA reports to the PTY) — queries are accepted
  and ignored.
- No re-encoding of the grid back to ANSI for output.
- No double-width / combining-character / sixel support.
- No synchronization with CoreText rendering or a SwiftUI/UIKit view.

When the iOS/Tether app integrates this package:
1. Create one `Terminal` per PTY session.
2. Read from the PTY and call `terminal.feed(data)` for every chunk.
3. Observe `terminal.state.onChange` to trigger a screen repaint.
4. Read `terminal.state.grid` / `terminal.row(_:)` for rendering.
5. Keep the PTY reader on a single serial queue/dispatch source.

## License

MIT — see `LICENSE`. Reference/attribution for SwiftTerm and the vt100.net /
xterm documentation is included in the license file.
