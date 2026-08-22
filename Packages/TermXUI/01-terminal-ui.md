# C1 — Terminal UI

**Goal:** A terminal view that feels like macOS Terminal / iTerm2: full xterm/VT100
emulation, colors, cursor addressing (so vim/nano/Claude Code's TUI render correctly),
fast scrolling, selection/copy/paste, tabs, and an iOS-friendly keyboard.

## Reuse decision

**Use [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — MIT license.**
Written by Miguel de Icaza (creator of Xamarin/Gnome). It is *the* terminal emulator
engine for Swift: VT100/xterm escape sequences, 24-bit color, mouse events, sixel,
`UIKitTerminalView` for iOS out of the box. Used by La Terminal and secure ShellFish —
proven on the App Store. This saves us months and is better than anything we'd write.

We do NOT reuse Blink Shell's UI (GPLv3) — don't even copy code from it. SwiftTerm is
cleaner anyway.

## Architecture

```
SwiftUI App
 └─ TerminalSessionView (UIViewRepresentable)
     └─ SwiftTerm.TerminalView  ◀── bytes out (what programs print)
            │ bytes in (what user types)
            ▼
     TerminalSession (our class, one per tab)
            │  pty master/slave pair (openpty — available on iOS)
            ▼
     C2 Shell & Command Engine
```

- `TerminalSession` owns a **pseudo-terminal (pty)**: `openpty()` works on iOS. The
  SwiftTerm view reads/writes the master side; the shell/commands get the slave side as
  their stdin/stdout/stderr. This is exactly how macOS Terminal works and is what makes
  interactive TUIs (vim, Claude Code's spinner/panels) behave correctly.
- Window size changes (rotation, split view, keyboard show/hide) → `ioctl(TIOCSWINSZ)` on
  the pty + SIGWINCH-equivalent notification into the command engine.

## Feature checklist

### MVP (M1–M2)
- [ ] SwiftTerm view embedded in SwiftUI, one session
- [ ] pty plumbing (master ↔ view, slave ↔ engine)
- [ ] Correct resize handling (cols/rows recompute on layout change)
- [ ] **Accessory keyboard bar** above the iOS keyboard: `Esc  Tab  Ctrl  ⌥  ← ↑ ↓ →  |  ~  /  -`
      (Ctrl is sticky: tap Ctrl then C = ^C). Copy a-Shell's UX idea, implement fresh.
- [ ] Hardware keyboard support (iPad Magic Keyboard): all ctrl/meta combos, ⌘K clear
- [ ] Copy/paste, long-press selection, drag-select
- [ ] Font choice (bundle 2–3 SIL-OFL fonts: JetBrains Mono, Fira Code, SF Mono system)
- [ ] Light/dark themes + classic palettes (Solarized, Dracula — public domain/MIT schemes)

### V2
- [ ] Multiple tabs (SwiftUI TabView or custom tab bar), swipe to switch
- [ ] iPad multi-window (UIScene) — two folders side by side
- [ ] Adjustable font size (pinch), haptics on bell
- [ ] URL/path detection → tap to open/insert
- [ ] Scrollback search

## Key implementation notes

- Run SwiftTerm's data feed on a dedicated serial queue; batch writes (Claude Code streams
  fast; feed in chunks per frame to keep 60fps).
- Bell/beep → gentle haptic.
- Keep the terminal alive when app backgrounds: request `beginBackgroundTask` so short
  commands finish; long tasks pause gracefully (document this behavior; iSH uses a
  location-hack we will NOT ship initially).
- The keyboard toolbar is the #1 usability feature on iPhone. Budget real design time.

## Deliverable

Swift Package `TermXUI`:
- `TerminalSessionView` (SwiftUI)
- `TerminalSession` (pty + lifecycle)
- `KeyboardAccessoryView`
- Theme engine + bundled fonts
- Demo target: echoes typed input through a fake engine (so this package is testable
  before C2 exists).
