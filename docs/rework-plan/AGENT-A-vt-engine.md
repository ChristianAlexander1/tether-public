# Agent brief A — `TetherVTEngine` (terminal byte-stream engine)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`TetherVTEngine`**, a pure-Swift package (zero dependencies beyond
Foundation) that understands the terminal escape-sequence protocol at the byte
level. It will sit between a PTY master and a terminal renderer inside an iOS
terminal app. It must provide four things:

1. **`VTStreamTokenizer`** — an incremental, lossless tokenizer for
   ANSI/VT500-family byte streams (text, C0 controls, ESC, CSI, OSC, DCS).
2. **`TUIStateTracker`** — tracks the terminal-mode state a full-screen TUI
   (vim, htop, Claude Code, Ink apps) can put a terminal into — alternate
   screen, hidden cursor, mouse reporting, bracketed paste, etc. — and
   synthesizes the exact **restore sequence** that returns the terminal to a
   clean shell state. This is what prevents "the app crashed and my terminal
   is stuck on a blank alternate screen with no cursor."
3. **`VTQueryResponder`** — answers terminal queries the downstream renderer
   does not handle (color-scheme reporting, XTGETTCAP, DECRQM), while
   forwarding everything else byte-for-byte.
4. **`VTOutputPipeline`** — a composition of the three above with one `feed`
   call.

The package will be dropped, as a folder, into an existing iOS project and
wired into its output path by a separate integrator. You never see that
project; you only honor the contract below.

## Context you need

- The host app is a real terminal: a Darwin PTY feeds a SwiftTerm renderer.
  SwiftTerm already implements the character grid, alternate screen buffer,
  cursor addressing, SGR colors, and answers cursor-position reports (CPR)
  itself. **You must not re-implement a renderer** and must never answer
  queries whose answer depends on grid contents (like CPR) — those are
  forwarded.
- Your engine taps the byte stream *before* the renderer. Everything you do
  must be **lossless for bytes you don't consume**: forwarding must reproduce
  the input exactly, split across any call boundaries.
- Programs running behind the PTY include busybox tools, vim, less, htop,
  and Node-based TUIs (Ink / Claude Code) that use DECSET 1049, DECSET 2004,
  DECSET 2026 (synchronized output), kitty keyboard protocol pushes, and
  OSC 10/11 color queries.

## Ground rules

- Swift 5.9+ package: `// swift-tools-version:5.9`, platforms
  `.macOS(.v13), .iOS(.v16)`.
- **Foundation only.** The package must `swift build` and `swift test` on
  Linux Swift as well as macOS — no Darwin-only imports anywhere.
- Zero third-party dependencies; tests run offline with `swift test`.
- No timers, threads, or global state: everything is synchronous,
  deterministic, and instance-scoped.
- Handle **hostile input gracefully**: truncated escapes, absurd parameter
  counts, 10 MB OSC payloads, interleaved partial UTF-8 — never crash, never
  hang, never allocate unboundedly (cap buffered sequence length at 64 KiB;
  overlong sequences are flushed through as plain text).

## Deliverable layout

```
TetherVTEngine/
  Package.swift
  README.md
  HANDOFF.md
  Sources/TetherVTEngine/
    VTToken.swift
    VTStreamTokenizer.swift
    TUIModeState.swift
    TUIStateTracker.swift
    TerminalIdentity.swift
    ResponsePolicy.swift
    VTQueryResponder.swift
    VTOutputPipeline.swift
  Tests/TetherVTEngineTests/
    TokenizerTests.swift
    TokenizerFuzzTests.swift
    TrackerTests.swift
    RestoreSequenceTests.swift
    ResponderTests.swift
    PipelineTests.swift
    Fixtures/          (raw byte fixture files, see Test plan)
```

## Public API contract (FROZEN — implement exactly; you may add, never change)

```swift
public enum VTToken: Equatable, Sendable {
    case text(Data)                       // printable runs, incl. UTF-8
    case c0(UInt8)                        // BEL, BS, TAB, LF, CR, ...
    case esc(final: UInt8, intermediates: [UInt8])
    case csi(params: [Int], intermediates: [UInt8], final: UInt8, isPrivate: Bool)
    case osc(code: Int, payload: Data)
    case dcs(payload: Data)
    case incomplete                       // internal marker, never emitted by feed()
}

public final class VTStreamTokenizer {
    public init()
    /// Incremental: safe to feed bytes split at any boundary, including
    /// mid-escape and mid-UTF-8. Buffers partial sequences internally.
    public func feed(_ bytes: Data) -> [VTToken]
    /// Flush any buffered partial sequence as raw text (stream ended).
    public func flush() -> [VTToken]
    /// Exact bytes of a token, for lossless pass-through re-emission.
    public static func serialize(_ token: VTToken) -> Data
}

public struct TUIModeState: Equatable, Sendable {
    public var alternateScreen: Bool          // DECSET 47 / 1047 / 1049
    public var cursorHidden: Bool             // DECSET 25 (l = hidden)
    public var mouseModes: Set<Int>           // 9,1000,1002,1003,1005,1006,1015
    public var bracketedPaste: Bool           // DECSET 2004
    public var applicationCursorKeys: Bool    // DECSET 1
    public var applicationKeypad: Bool        // ESC = / ESC >
    public var focusReporting: Bool           // DECSET 1004
    public var synchronizedOutput: Bool       // DECSET 2026
    public var scrollRegionSet: Bool          // DECSTBM with non-default args
    public var savedCursor: Bool              // DECSC without matching DECRC
    public var kittyKeyboardDepth: Int        // CSI > u pushes / CSI < u pops
    public var isClean: Bool { get }          // true when everything is default
    public init()
}

public final class TUIStateTracker {
    public init()
    public private(set) var state: TUIModeState
    public func observe(_ token: VTToken)
    /// Minimal byte sequence that returns a terminal in `state` to a clean,
    /// usable shell state (exit alt screen, show cursor, disable mouse /
    /// bracketed paste / focus events, reset SGR + scroll region + charset,
    /// pop kitty keyboard levels, end synchronized update). Empty if clean.
    public func restoreSequence() -> Data
    public func reset()
}

public struct TerminalIdentity: Sendable {
    public var termName: String               // e.g. "xterm-256color"
    public var da1: String                    // primary device attributes reply
    public var da2: String                    // secondary DA reply
    public var colorSchemeIsDark: Bool
    public var capabilities: [String: String] // XTGETTCAP name → value
    public init(termName: String, da1: String, da2: String,
                colorSchemeIsDark: Bool, capabilities: [String: String])
    public static var xterm256Color: TerminalIdentity { get }
}

public struct ResponsePolicy: Sendable {
    public var answerColorScheme: Bool        // DECSET/DECRST 2031, CSI ?996n, CSI ?2031$p
    public var answerXTGETTCAP: Bool          // DCS + q ... ST
    public var answerDECRQM: Set<Int>         // modes it may answer from the tracker
    public var answerOSCColorQueries: Bool    // OSC 10/11 with '?' payload
    public init(answerColorScheme: Bool, answerXTGETTCAP: Bool,
                answerDECRQM: Set<Int>, answerOSCColorQueries: Bool)
    public static var conservativeDefault: ResponsePolicy { get } // 2031+996, XTGETTCAP, DECRQM {2026,2031}, no OSC
}

public final class VTQueryResponder {
    public init(identity: TerminalIdentity, policy: ResponsePolicy)
    public var identity: TerminalIdentity { get set }
    /// Splits input into bytes to forward downstream and reply bytes to write
    /// back to the PTY. Consumed queries are removed from `forward`.
    public func process(_ input: Data) -> (forward: Data, replies: Data)
    /// Emitted when identity.colorSchemeIsDark changes while 2031 reporting on.
    public var onUnsolicitedReply: ((Data) -> Void)? { get set }
}

public final class VTOutputPipeline {
    public init(identity: TerminalIdentity, policy: ResponsePolicy)
    public func feed(_ bytes: Data) -> (forward: Data, replies: Data)
    public var trackerState: TUIModeState { get }
    public func restoreSequence() -> Data
}
```

## Behavior specification

### Tokenizer

- Implement the classic VT500-series parser state machine (the Paul Williams
  DEC parser model): GROUND, ESCAPE, ESCAPE_INTERMEDIATE, CSI_ENTRY/PARAM/
  INTERMEDIATE/IGNORE, OSC_STRING, DCS families, SOS/PM/APC ignore.
- CSI: parse semicolon-separated numeric params (empty param → 0; colon
  sub-params may be flattened into the following param list but must
  round-trip via `serialize` — store raw bytes internally to guarantee
  losslessness). `isPrivate` is true when the first param byte is `?`, `<`,
  `=`, or `>`; record which one internally so serialize is exact.
- OSC terminates on BEL (0x07) or ST (ESC `\`). `code` is the leading integer
  (or `-1` if malformed); payload excludes code and separator. Serialization
  must reproduce the original terminator.
- Text runs: coalesce printable and non-control UTF-8 bytes into maximal
  `text` tokens. A UTF-8 sequence split across `feed` calls must not be split
  across tokens.
- C0 controls other than ESC are emitted as `c0`.
- 8-bit C1 controls (0x80–0x9F) inside UTF-8 text must NOT be treated as
  controls (UTF-8 continuation bytes overlap that range) — only interpret C1
  when the byte is not part of a valid multi-byte sequence in progress.
- Losslessness invariant: for any input split into any chunking,
  `concat(serialize(token) for token in feed(...) + flush())` equals the
  original input bytes exactly.

### Tracker

- `DECSET`/`DECRST` (`CSI ? Pm h/l`) with multiple params updates each mode.
- 1049 set → alternateScreen true (and conceptually saves cursor); 1049 reset
  → false. 47 and 1047 also toggle alternateScreen.
- `ESC 7`/`DECSC` sets savedCursor; `ESC 8`/`DECRC` clears it.
- `ESC =` sets applicationKeypad, `ESC >` clears it.
- `CSI r` with no/default params clears scrollRegionSet; with params sets it.
- Kitty keyboard: `CSI > Pn u` increments depth (min 0), `CSI < Pn u`
  decrements by Pn (default 1, floor 0), `CSI = Pn ; Pm u` leaves depth
  unchanged.
- `RIS` (`ESC c`) and `DECSTR` (`CSI ! p`) reset the whole state to clean.
- `restoreSequence()` emits, in this order, only the pieces needed:
  1. `ESC[?2026l` (end synchronized update) if set
  2. `ESC[<mode>l` for every active mouse mode
  3. `ESC[?2004l` if bracketed paste
  4. `ESC[?1004l` if focus reporting
  5. kitty pops: `ESC[<u` repeated `kittyKeyboardDepth` times
  6. `ESC[r` if scrollRegionSet
  7. `ESC8` if savedCursor (restore), then `ESC[?1049l` if alternateScreen
  8. `ESC[?1l` and `ESC>` if application cursor keys / keypad
  9. `ESC[0m` always when anything was emitted (SGR reset)
  10. `ESC[?25h` if cursorHidden
  Empty `Data` when `state.isClean`.

### Responder

- Color-scheme protocol (matches an existing adapter being replaced —
  keep byte-exact):
  - `ESC[?2031h` → start reporting, consume. `ESC[?2031l` → stop, consume.
  - `ESC[?996n` → reply `ESC[?997;1n` (dark) or `ESC[?997;2n` (light), consume.
  - `ESC[?2031$p` → reply `ESC[?2031;<1|2>$y` (1 = reporting on, 2 = off), consume.
  - When `identity.colorSchemeIsDark` changes while reporting is on, invoke
    `onUnsolicitedReply` with the `997` report.
- XTGETTCAP: `DCS + q <hex-names> ST` → for each semicolon-separated
  hex-encoded name, look up `identity.capabilities`; reply
  `DCS 1 + r name=value ST` (hex-encoded) for hits, `DCS 0 + r ST` for a
  query with no hits. Consume the query.
- DECRQM (`CSI ? Pd $ p`): if `Pd ∈ policy.answerDECRQM`, reply
  `CSI ? Pd ; Ps $ y` where Ps is 1/2 (set/reset) from an internal mirror of
  those modes (the responder tracks h/l for the modes it may answer); other
  modes are forwarded untouched.
- OSC 10/11 `?` queries: answered only when `answerOSCColorQueries` is true,
  using two fixed palettes (dark: fg `rgb:ffff/ffff/ffff` bg `rgb:0000/0000/0000`;
  light: inverted) — otherwise forwarded.
- Everything not consumed is forwarded **byte-exact**, including malformed
  sequences.

## Edge cases you MUST handle (each needs a test)

1. Escape sequence split across three `feed` calls at every possible byte
   boundary (parameterized test).
2. UTF-8 4-byte emoji split across two chunks; no corruption in forward.
3. OSC payload of 100,000 bytes → forwarded intact (under the 64 KiB cap this
   flushes as text — pick one behavior, document it in HANDOFF, and keep the
   losslessness invariant).
4. `ESC[?1049h` then program killed with no reset → `restoreSequence`
   contains `ESC[?1049l`, `ESC[0m`, `ESC[?25h` (cursor was also hidden) in the
   specified order.
5. DECSET with multiple params: `ESC[?1049;2004;25l` updates all three.
6. `ESC[?2031$p` before/after `2031h` returns 2 then 1.
7. Kitty push ×3, pop ×1 → depth 2; restore emits exactly 2 pops.
8. `RIS` mid-TUI → tracker clean, restore empty.
9. Interleaved consumed and forwarded sequences in one buffer: forward output
   equals input minus exactly the consumed query bytes.
10. Zero-length feed, feed of a single ESC byte then nothing, flush behavior.
11. CSI with 300 parameters or a parameter of 20 digits → parsed without
    overflow (clamp params to Int32 range), forwarded losslessly.
12. DECRQM for a mode not in the policy set → forwarded, not answered.

## Test plan (minimum)

- **Losslessness fuzz**: generate 1,000 random byte strings (mix of valid
  sequences, truncated sequences, UTF-8, binary noise), random chunkings;
  assert serialize-round-trip identity. Use a fixed RNG seed for determinism.
- **Fixture files** under `Tests/.../Fixtures/`: recorded real-world-style
  streams (a vim-like session: 1049h, cursor moves, SGR, 1049l; an
  Ink-like session: 2004h, 25l, repaint loops; an interrupted session that
  never restores). Assert final tracker state and restore bytes per fixture.
- Responder tests for every consumed query, including split delivery.
- 150+ assertions total is the expected order of magnitude.

## Acceptance checklist (verify before you finish)

- [ ] `swift build` and `swift test` pass with zero warnings on Linux Swift 5.9+.
- [ ] Public API matches the frozen contract exactly (names, signatures).
- [ ] Losslessness fuzz passes with 1,000 seeds.
- [ ] All 12 edge cases above have named tests.
- [ ] No `import` other than Foundation/XCTest anywhere.
- [ ] `HANDOFF.md` documents: entry points, the OSC-cap decision from edge
      case 3, and a 10-line example wiring `VTOutputPipeline` between a
      byte source and a renderer.

## Non-goals (do NOT build these)

- No rendering, no grid, no cursor position tracking, no scrollback.
- No input-direction (keyboard encoding) work.
- No PTY, no processes, no sockets, no async.
- Never answer CPR (`CSI 6 n`), DA1/DA2, or DSR-5 — those belong to the
  downstream renderer; forward them. (`TerminalIdentity.da1/da2` exist for a
  future policy toggle; the conservative default must NOT answer them.)
