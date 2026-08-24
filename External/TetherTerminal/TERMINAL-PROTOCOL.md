# TetherTerminal — VT100/xterm Escape-Sequence Reference

This document describes the control sequences that **TetherTerminal** parses and
the terminal state they affect. It is written for integrators embedding the
parser in a TUI/terminal app (e.g. fixing smashed CLI text and the
`Unhandled DECSET 2031` warning seen in Claude Code's TUI).

The parser is **streaming** and **fault-tolerant**: unknown, malformed, or
truncated sequences are never fatal. This is the core guarantee that addresses
the "smashed text / DECSET 2031" bug.

---

## 1. Architecture

```
        bytes (String / Data / [UInt8])
                    │
                    ▼
        ┌───────────────────────────┐
        │   EscapeSequenceParser     │  state machine: ground, escape,
        │   (Paul Williams-style)    │  CSI, OSC, DCS, charset ...
        └───────────────────────────┘
                    │ delegate callbacks
                    ▼
        ┌───────────────────────────┐
        │      TerminalState         │  grid, cursor, SGR, modes,
        │  (screen + cursor model)   │  scroll region, alt screen
        └───────────────────────────┘
                    ▲
                    │ wrapped by
        ┌───────────────────────────┐
        │         Terminal           │  high-level facade: feed() + text
        └───────────────────────────┘
```

- `EscapeSequenceParser` knows nothing about screens. It turns a byte stream
  into decoded text + structured commands (`CSICommand`, OSC strings, C0
  controls, two-byte escapes) delivered through
  `EscapeSequenceParserDelegate`.
- `TerminalState` implements that delegate and maintains a grid of `Cell`s,
  the cursor, current SGR attributes, DEC private modes, the scroll region,
  and the alternate-screen buffer.
- `Terminal` is a convenience that wires the two together.

All three types are `public` so a host app may use the parser alone, the state
alone with a custom delegate, or the combined facade.

---

## 2. Feeding data

The parser accepts three input forms and may be called repeatedly; all state is
retained between calls, so sequences split across writes are reassembled.

```swift
let terminal = Terminal(columns: 80, rows: 24)

terminal.feed("\u{1B}[?2031h")        // String
terminal.feed(Data([0x1B, 0x5B, 0x48])) // Data
terminal.feed([0x1B, 0x5B, 0x4A])     // [UInt8]

terminal.flush()                      // deliver any buffered trailing text
```

**Splitting safety** — these all parse identically:

```swift
terminal.feed("\u{1B}[31mred")
// versus
terminal.feed("\u{1B}[3")
terminal.feed("1mred")
// versus
terminal.feed([0x1B])
terminal.feed("[31m")
terminal.feed("red")
```

UTF-8 multibyte characters split across writes are also reassembled (e.g. the
two bytes of `é` may arrive in separate chunks). Invalid bytes are replaced with
`U+FFFD` rather than trapping.

---

## 3. Plain text and C0 controls

| Bytes        | Name        | Effect                                            |
|--------------|-------------|---------------------------------------------------|
| `0x07` (BEL) | Bell        | Delivered as a control; OSC string terminator.    |
| `0x08` (BS)  | Backspace   | Cursor left one column (clamped at 0).            |
| `0x09` (TAB) | Horizontal tab | Advances to the next 8-column tab stop.        |
| `0x0A` (LF)  | Line feed   | Cursor down one row; scrolls at bottom margin.    |
| `0x0B` (VT)  | Vertical tab| Treated as LF.                                    |
| `0x0C` (FF)  | Form feed   | Treated as LF.                                    |
| `0x0D` (CR)  | Carriage return | Cursor to column 0.                            |
| `0x00` (NUL) | Null        | Ignored.                                          |
| `0x7F` (DEL) | Delete      | Ignored.                                          |

> **Note on newlines.** TetherTerminal follows the VT model where `LF` moves the
> cursor *down but keeps the column*. Real CLI streams almost always send
> `CR LF` (`\r\n`); the host app should either feed data verbatim (and emit
> `\r\n` itself) or enable its pipeline's newline translation. The parser does
> **not** silently turn `\n` into `\r\n`, because that would corrupt raw-mode
> TUIs that deliberately address columns.

Printable UTF-8 text is written into the grid at the cursor using the current
SGR attributes, advancing the cursor. At the right margin (auto-wrap mode, on
by default) the next character wraps to the next line.

---

## 4. CSI sequences

CSI is `ESC [` (or the single C1 byte `0x9B`) followed by parameter bytes
(`0x30–0x3F`), optional intermediates (`0x20–0x2F`), and a final byte
(`0x40–0x7E`). A leading `?` marks a DEC **private** sequence.

### 4.1 Cursor movement

| Sequence        | Effect                                      |
|-----------------|---------------------------------------------|
| `CSI n A`       | Cursor up `n` (default 1).                  |
| `CSI n B`       | Cursor down `n`.                            |
| `CSI n C`       | Cursor forward (right) `n`.                 |
| `CSI n D`       | Cursor backward (left) `n`.                 |
| `CSI n E`       | Cursor next line (down `n`, column 0).      |
| `CSI n F`       | Cursor previous line (up `n`, column 0).    |
| `CSI n G`       | Cursor to column `n` (1-based).             |
| `CSI n d`       | Cursor to row `n` (1-based).                |
| `CSI row ; col H` / `f` | Cursor position (1-based, default 1).|

All movements clamp to the grid and clear the "pending wrap" flag.

### 4.2 Erase and edit

| Sequence   | Effect                                                                 |
|------------|------------------------------------------------------------------------|
| `CSI 0 J`  | Erase from cursor to end of screen (default).                          |
| `CSI 1 J`  | Erase from start of screen to cursor.                                  |
| `CSI 2 J`  | Erase whole screen.                                                    |
| `CSI 3 J`  | Erase whole screen + scrollback (scrollback not modeled).              |
| `CSI 0 K`  | Erase from cursor to end of line (default).                            |
| `CSI 1 K`  | Erase from start of line to cursor.                                    |
| `CSI 2 K`  | Erase entire line.                                                     |
| `CSI n @`  | Insert `n` blank characters at cursor (shifts right; rightmost lost).  |
| `CSI n P`  | Delete `n` characters at cursor (shifts left; blanks at right).        |
| `CSI n X`  | Erase `n` characters at cursor (no shift).                             |
| `CSI n L`  | Insert `n` lines at cursor (within scroll region).                     |
| `CSI n M`  | Delete `n` lines at cursor (within scroll region).                     |
| `CSI n S`  | Scroll scroll region up `n` lines.                                     |
| `CSI n T`  | Scroll scroll region down `n` lines.                                   |

### 4.3 Scroll region

`CSI top ; bottom r` — set the scrolling region (DECSLPP), 1-based. The cursor
is moved to home. A parameter of 0/omitted uses the screen edge. Setting the
region to a single row resets to the full screen.

### 4.4 SGR (Select Graphic Rendition) — `CSI ... m`

Parameters are semicolon-separated and applied left to right:

| Code(s)           | Effect                                  |
|-------------------|-----------------------------------------|
| `0`               | Reset all attributes.                   |
| `1`               | Bold.                                   |
| `2`               | Faint/dim.                              |
| `3`               | Italic.                                 |
| `4`               | Underline.                              |
| `5`, `6`          | Blink.                                  |
| `7`               | Inverse/reverse video.                  |
| `8`               | Hidden/concealed.                       |
| `9`               | Strikethrough.                          |
| `21`              | Bold off.                               |
| `22`              | Bold/faint off.                         |
| `23`–`29`         | Italic/underline/blink/inverse/hidden/strike off. |
| `30–37`           | Foreground: standard 8 colors.          |
| `90–97`           | Foreground: bright 8 colors.            |
| `39`              | Default foreground.                     |
| `40–47`           | Background: standard 8 colors.          |
| `100–107`         | Background: bright 8 colors.            |
| `49`              | Default background.                     |
| `38;5;n`          | Foreground: 256-color palette index.    |
| `48;5;n`          | Background: 256-color palette index.    |
| `38;2;r;g;b`      | Foreground: 24-bit RGB.                 |
| `48;2;r;g;b`      | Background: 24-bit RGB.                 |

Unknown SGR sub-codes are ignored. Colors are represented by the `AnsiColor`
enum (`.palette`, `.indexed`, `.rgb`).

### 4.5 Window / resize — `CSI t`

`CSI 8 ; rows ; cols t` resizes the terminal's text area (e.g. xterm reports
size changes this way). TetherTerminal resizes its grid, preserving visible
content. Other `CSI t` subfunctions (minimize/maximize, title queries) are
accepted and ignored.

### 4.6 Modes (non-private `h`/`l`)

`CSI h` (SM) and `CSI l` (RM) for *non-private* ANSI modes are parsed; the
modes themselves have no modeled side effects and are ignored safely.

---

## 5. DEC private modes — `CSI ? ... h/l` (the DECSET 2031 fix)

`CSI ? n h` sets (**DECSET**) and `CSI ? n l` resets (**DECRST**) a private
mode `n`. The mode number is stored in `TerminalState.decModes`.

The following modes have behavior:

| Mode  | Name / effect                                                        |
|-------|----------------------------------------------------------------------|
| `1`   | Application cursor keys (accepted).                                  |
| `6`   | Origin mode (cursor addressing relative to scroll region).           |
| `7`   | Auto-wrap mode (on by default).                                      |
| `25`  | Cursor visibility.                                                   |
| `47`, `1047`, `1048` | Alternate-screen variants (accepted).                     |
| `1049`| **Alternate screen**: save cursor/attrs, switch to a fresh buffer; on reset, restore the primary screen and cursor. |
| `2004`| **Bracketed paste**: exposed via `Terminal.bracketedPaste`.          |
| `1000–1015`, `1006` | Mouse tracking modes (accepted; the host app wires events). |
| `2031`| **The flagged mode.** Accepted and recorded; intentionally has no side effect. It must never throw or smash text. |

**Unknown modes and unknown final bytes are ignored.** Concretely, every one of
these is a safe no-op beyond recording the mode number:

```swift
terminal.feed("\u{1B}[?2031h")   // DECSET 2031  — safe
terminal.feed("\u{1B}[?2031l")   // DECRST 2031  — safe
terminal.feed("\u{1B}[?9999h")   // unknown mode — safe
terminal.feed("\u{1B}[?7777x")   // unknown final — safe
terminal.feed("\u{1B}[1;2;3Z")   // unknown CSI   — safe
```

This is the direct fix for `Unhandled DECSET 2031`: rather than treating the
sequence as an exceptional case, the parser simply does not consider *any*
unknown sequence exceptional.

---

## 6. Other escape sequences

| Sequence        | Effect                                                   |
|-----------------|----------------------------------------------------------|
| `ESC 7`         | Save cursor position and attributes (DECSC).             |
| `ESC 8`         | Restore cursor position and attributes (DECRC).          |
| `ESC c`         | Full reset (RIS): clears the grid and all modes.         |
| `ESC M`         | Reverse index (cursor up; scroll down at top margin).    |
| `ESC D`         | Index (cursor down; scroll at bottom).                   |
| `ESC E`         | Next line (index + CR).                                  |
| `ESC ( B` etc.  | Character set designation — accepted, ignored (UTF-8).   |
| `ESC ] ... BEL` / `ESC ] ... ESC \` | OSC — see below.                       |
| `ESC P ... ESC \` | DCS — consumed and discarded safely.                   |
| `ESC X / ^ / _` | SOS/PM/APC — consumed and discarded safely.             |

---

## 7. OSC (Operating System Commands)

OSC strings are `ESC ] code ; text BEL` or `ESC ] code ; text ESC \`.
TetherTerminal handles:

| Code | Effect                                     |
|------|--------------------------------------------|
| `0`  | Set icon name **and** window title.        |
| `2`  | Set window title (exposed via `Terminal.title` / `TerminalState.windowTitle`). |

Unknown OSC codes (color reports, clipboard, etc.) are parsed and discarded
without affecting the display. A `onTitleChange` callback is available.

---

## 8. Sizing

- Default size is **80 columns × 24 rows**.
- Resize with `Terminal.resize(columns:rows:)` or by feeding `CSI 8 ; rows ; cols t`.
- Resize preserves as much on-screen content as possible, clamps the cursor,
  rebuilds tab stops, and resets the scroll region to the full screen.

---

## 9. Threading and safety

Types are Swift classes not internally synchronized; feed all data from one
thread (or serialize externally), which matches how a PTY reader loop normally
operates. The parser performs no I/O and allocates only small byte/string
buffers, making it suitable for embedding directly in a terminal view's input
path.

---

## 10. References

- [vt100.net — VT510 RM (Reset Mode)](https://vt100.net/docs/vt510-rm/RM) and the
  surrounding [VT510 programmer reference](https://vt100.net/docs/vt510-rm/contents.html).
- [Paul Williams' VT100 parser state
  table](https://vt100.net/emu/dec_ansi_parser) — the conceptual basis for the
  state machine.
- [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
  for DECSET 1049/2004/2031 and `CSI t`.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) — a much larger,
  battle-tested Mac/iOS terminal used as a reference for behavior.
