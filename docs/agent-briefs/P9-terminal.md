# Track P9 — Terminal escape parser (Swift)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No iOS app, no UIKit/SwiftUI.
2. **Do not ask** for the iOS app.
3. **Naming:** product is **Tether**. Package `TetherTerminal`. Never TermX/`termx`.
4. **Build only** Swift parser module + tests.
5. **`swift test`** — **30+** tests, all green.
6. **Zip:** `TetherTerminal-P9.zip`

---

# Your job: VT100/xterm escape sequence parser (Swift)

Fixes smashed CLI text and **DECSET 2031** — parser must **never crash** on unknown sequences.

## Context
Claude Code TUI shows smashed text and `Unhandled DECSET 2031`. Build a VT100/xterm parser Swift module + docs.

## YOUR job ONLY
Swift package + tests. No iOS UI app.

## Deliver
```
TetherTerminal/
├── Package.swift
├── Sources/EscapeSequenceParser.swift, TerminalState.swift, ...
├── Tests/ (30+ tests)
├── TERMINAL-PROTOCOL.md
├── LICENSE
└── HANDOFF.md
```

## Must handle
- CSI moves, SGR colors, erase
- **DECSET/DECRST 2031** — safe ignore (no crash)
- Alternate screen 1049
- Bracketed paste 2004
- UTF-8 text
- Default 80 columns; resize CSI `t`

## Tests (30+)

| Input | Result |
|-------|--------|
| `\e[?2031h` | no throw |
| `\e[2J\e[H` | clear + home |
| `\e[31mred\e[0m` | red then reset |
| Split sequence across 2 writes | still valid |

## Zip: **`TetherTerminal-P9.zip`**

## Open source
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT
- [vt100.net](https://vt100.net/docs/vt510-rm/RM) spec

## License: MIT
