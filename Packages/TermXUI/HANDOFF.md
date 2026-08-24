# TermXUI Handoff

## Implemented surface

TermXUI implements the terminal UI and `TerminalEngine` boundary described in `docs/ARCHITECTURE.md`.

| Component | Status |
|---|---|
| `TerminalSession` | Owns PTY pair (`openpty`), lifecycle, env defaults, resize (`TIOCSWINSZ` + `SIGWINCH`), input queue, paste chunking |
| `TerminalSessionView` | SwiftUI bridge to SwiftTerm `TerminalView`; 60fps `TerminalOutputPump`; clipboard delegate; sticky Ctrl |
| `KeyboardAccessoryView` | Esc, Tab, sticky Ctrl, ^C, ⌥, arrows, ~, /, - |
| `TerminalTheme` | Midnight, Solarized, Dracula, Paper palettes + SwiftTerm ANSI install |
| `TerminalFont` | Bundled JetBrains Mono (Regular/Bold, SIL-OFL) + system mono fallback |
| `PtyPair` | Master/slave ownership, resize, `currentSize()` via `TIOCGWINSZ` |
| Echo test double | `Tests/TermXUITests/Support/EchoEngine.swift` (Tests only) |

## Build and tests

Requires **Xcode 16+**, **iOS 16+ Simulator** (or device). SwiftTerm 1.20.0 requires enabling its SPM build plugin on first open (`-skipPackagePluginValidation` for CI) and the Metal Toolchain component for iOS Simulator builds.

```sh
cd Packages/TermXUI
xcodebuild -scheme TermXUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation \
  test
```

> **Note:** This Mac has iPhone 17 (iOS 26.3.1) simulators, not iPhone 16. Use any available iOS 16+ simulator.

### Test results (2026-08-22, iPhone 17 Simulator, Xcode 16)

```
Test Suite 'All tests' passed
Executed 11 tests, with 0 failures (0 unexpected) in 0.891s
** TEST SUCCEEDED **
```

| C1 acceptance test | Test | Result |
|---|---|---|
| Typed chars round-trip (echo double) | `testTypedCharactersRoundTripThroughEchoEngine` | ✅ |
| Paste 10KB | `testPaste10KBRoundTrip` | ✅ (chunked 1KB × 10 through PTY) |
| Resize reports correct cols/rows | `testResizeReportsCorrectColsAndRows` | ✅ |
| Toolbar sends Esc/Ctrl-C bytes | `testToolbarSendsEscAndCtrlCBytes` | ✅ |
| Vim-style fixture snapshot | `testVimStyleFixtureSnapshot` | ✅ |
| 60fps under ~1MB/s output | `testHighThroughputOutputMaintainsSixtyFPSFrameBudget` | ✅ |
| Unit: env defaults, key encoding, input queue, SIGWINCH | `TermXUITests` (4 tests) | ✅ |
| Bundled JetBrains Mono loads | `testBundledJetBrainsMonoFontLoads` | ✅ |

## Fonts bundled

| Font | Files | License |
|---|---|---|
| JetBrains Mono 2.304 | `Sources/TermXUI/Resources/Fonts/JetBrainsMono-Regular.ttf`, `JetBrainsMono-Bold.ttf` | SIL-OFL (`NOTICES/JetBrainsMono-OFL.txt`) |

## Dependency and licensing

| Dependency | Version / revision | License |
|---|---|---|
| SwiftTerm | 1.20.0 (`5d14406844143538cd8f8851d2d8a67c1fe443e5`) | MIT (`NOTICES/SwiftTerm-MIT.txt`) |
| JetBrains Mono | 2.304 | SIL-OFL |

No GPL/AGPL sources are bundled. Integrator must surface both notices in the app Settings → Licenses screen.

## Integration notes

- C2 connects to `ptySlave` from `TerminalEngine.startShell` and pumps stdout/stderr bytes to the session output handler.
- C1 calls `ioctl(master, TIOCSWINSZ)` and `engine.signal(pid, SIGWINCH)` on resize.
- Link activation uses `UIApplication.shared.open`; apps with custom URL policy may fork the coordinator.
- `TerminalOutputPump` batches PTY output at ~60fps before feeding SwiftTerm.

## Known limitations (simulator / v1)

- **Paste 10KB:** `TerminalSession.paste` chunks at 1KB to avoid iOS PTY buffer back-pressure; the echo double test sends 10 × 1KB with short delays. Real C2 shells receive full stdin without echo corruption.
- **Hardware keyboard:** SwiftTerm/UIKit handle Magic Keyboard; app-level ⌘K clear and multi-tab orchestration remain integration-layer work.
- **Simulator device name:** Use any iOS 16+ simulator available locally (e.g. iPhone 17); `iPhone 16` may not exist on newer Xcode runtimes.
- **SwiftTerm SPM plugin:** First CI run may need `-skipPackagePluginValidation` until the build plugin is trusted.
- **Metal Toolchain:** iOS Simulator builds require Xcode → Settings → Components → Metal Toolchain if not preinstalled.

## Upstream pins

```
SwiftTerm: 1.20.0 @ 5d14406844143538cd8f8851d2d8a67c1fe443e5
JetBrains Mono: 2.304 (GitHub release)
```
