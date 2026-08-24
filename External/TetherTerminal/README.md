# TetherTerminal

A small, fault-tolerant **VT100/xterm escape-sequence parser** for Swift, built
for the Tether terminal product. It turns a raw PTY byte stream into a
navigable in-memory screen model — and it **never crashes on unknown
sequences** (the original `Unhandled DECSET 2031` / smashed-CLI-text bug).

This package is the isolated parser component only: no iOS app, no UIKit, no
SwiftUI.

## Usage

```swift
import TetherTerminal

let terminal = Terminal(columns: 80, rows: 24)

terminal.feed("\u{1B}[?2031h")        // DECSET 2031 — safe, no crash
terminal.feed("\u{1B}[31mred\u{1B}[0m")
print(terminal.row(0))                // "red"
```

Feed chunks straight from a PTY — sequences and UTF-8 characters split across
reads are reassembled automatically:

```swift
terminal.feed([0x1B])
terminal.feed("[?2031")
terminal.feed("h")
terminal.feed("café 世界 🌍")
```

Use the low-level parser on its own if you have a custom screen model:

```swift
final class MyScreen: EscapeSequenceParserDelegate {
    let parser = EscapeSequenceParser()
    init() { parser.delegate = self }
    func parser(_ p: EscapeSequenceParser, didReadCSI c: CSICommand) { /* ... */ }
    // other callbacks default to no-op
}
```

## What it handles

- CSI cursor movement, erase, insert/delete, scroll region.
- SGR: 16/256/24-bit colors, bold/faint/italic/underline/blink/inverse/strike.
- DECSET/DECRST private modes, including **2031 (safe ignore)**, **1049
  alternate screen**, and **2004 bracketed paste**.
- OSC 0/2 window titles (BEL or ST terminated).
- DCS/SOS/PM/APC strings, charset designations, C1 controls.
- UTF-8 text, including multibyte characters split across writes.
- Default 80×24; resize via API or `CSI 8 ; rows ; cols t`.

See [TERMINAL-PROTOCOL.md](TERMINAL-PROTOCOL.md) for the full sequence
reference and [HANDOFF.md](HANDOFF.md) for status and architecture.

## Build & test

```bash
swift build
swift test     # 76 tests, all green
```

Requires Swift 5.9+ (Swift 6 supported).

## License

MIT — see [LICENSE](LICENSE).
