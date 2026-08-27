# Agent brief G — `tether-bun-compat` (honest Bun API polyfill for Node)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`tether-bun-compat`**, a zero-dependency Node.js (CommonJS) library
that installs a faithful subset of the **Bun** global so that JavaScript
bundles originally built for the Bun runtime can execute on Node 18+.

Context: the host is an iOS app that runs a large third-party CLI (originally
shipped as a Bun-bundled program) on an embedded Node runtime. Its existing
Bun shim works but is hardcoded in ugly ways — most notably `Bun.which()`
special-cases a fixed list of command names instead of scanning `PATH`. Your
library replaces it with honest, generic mechanisms. **No hardcoded command
names anywhere.**

Everything platform-specific is injected, so the whole library is unit-testable
on any machine with plain Node.

## Ground rules

- Node 18+; pure CommonJS; **zero npm dependencies**.
- Tests: built-in `node:test` runner only (`node --test test/`).
- No real child processes, sockets, or network in tests (the `default-wiring`
  smoke test may spawn `node` itself; everything else uses injected fakes).
- Never special-case a command or file name. If you find yourself typing a
  program's name into logic, stop and generalize.
- Every API you install must match Bun's documented behavior closely enough
  that code written against Bun works; where you deliberately simplify,
  document it in HANDOFF.md under "Fidelity notes".

## Deliverable layout (FROZEN)

```
tether-bun-compat/
  lib/index.js          // installBunGlobal(options)
  lib/which.js          // real PATH directory scan; zero hardcoded names
  lib/file.js           // Bun.file / Bun.write over node:fs
  lib/spawn.js          // Bun.spawn / Bun.spawnSync mapped onto child_process shape
  lib/util.js           // Bun.sleep, Bun.env, Bun.version, stringWidth, deepEquals, etc.
  test/
  HANDOFF.md
  package.json          // "name": "tether-bun-compat", no dependencies
```

## Public surface (FROZEN)

```js
const { installBunGlobal } = require('tether-bun-compat');

installBunGlobal({
  // All optional; defaults shown.
  force: false,                       // refuse to overwrite an existing global Bun unless true
  version: '1.1.0-tether',            // reported as Bun.version
  platformInfo: null,                 // { platform, arch } — default: process values
  pathDirs: null,                     // array of PATH directories — default: process.env.PATH split
  fs: null,                           // node:fs-compatible object — default: require('fs')
  spawnImpl: null,                    // child_process-compatible { spawn, spawnSync } — default: require('child_process')
  env: null,                          // env object — default: process.env
});
```

- `installBunGlobal` returns the installed `Bun` object. Calling it when
  `globalThis.Bun` already exists and `force !== true` throws an `Error`
  with `code = 'EEXIST'`.
- All injected dependencies are captured at install time (no re-reading
  `process.env.PATH` later) — this is what makes tests deterministic.

## Behavior specification — the Bun subset to implement

### `lib/which.js` — `Bun.which(name, options?)`

- Scan `pathDirs` in order; return the first path whose file **exists and is
  executable** via the injected `fs` (`fs.accessSync(p, fs.constants.X_OK)`;
  on Windows-style setups executability may be approximated by existence —
  document it). Return `null` when not found (Bun's behavior).
- `options.PATH` (string) overrides the search path for that call;
  `options.cwd` makes relative PATH entries resolve against it.
- `name` containing a path separator → check that path directly (no scan).
- Empty name, absolute non-existent path, empty PATH → `null`, never throw.
- **Identical logic for every name** — a test must assert that looking up two
  arbitrary names (`"zzz-made-up"` vs `"claude"`) goes through byte-identical
  code paths (e.g. by injecting an fs spy and comparing call shapes).

### `lib/file.js` — `Bun.file(path)` and `Bun.write(dest, data)`

- `Bun.file(path)` returns a lazy `BunFile`-like object:
  `{ name, size, type, exists(): Promise<boolean>, text(): Promise<string>,
  arrayBuffer(): Promise<ArrayBuffer>, bytes(): Promise<Uint8Array>,
  json(): Promise<any>, stream(): ReadableStream }`.
  - `size` reads lazily via `fs.statSync` at property access; missing file →
    `size === 0`, `exists()` resolves false, `text()` rejects with
    `ENOENT`-coded error.
  - `type` from a minimal extension → MIME map (`.json`, `.txt`, `.js`,
    `.html`, `.wasm`, default `application/octet-stream`) — a data table,
    not logic.
- `Bun.write(dest, data)`: dest is a string path or BunFile; data is a
  string, Uint8Array/ArrayBuffer, or BunFile (copy). Returns
  `Promise<number>` of bytes written. Creates parent directories.

### `lib/spawn.js` — `Bun.spawn(cmd, options?)` / `Bun.spawnSync`

- `Bun.spawn(["cmd","arg"], { cwd, env, stdin, stdout, stderr, onExit })`
  maps onto the injected `spawnImpl.spawn` and returns a Bun-shaped
  `Subprocess`: `{ pid, stdin, stdout, stderr, exited: Promise<number>,
  exitCode, signalCode, kill(signal?), unref(), ref() }`.
  - `stdout: "pipe"` → expose a WHATWG `ReadableStream` (wrap the Node
    stream with `stream.Readable.toWeb`); `"inherit"` and `"ignore"` pass
    through.
  - `exited` resolves with the exit code (or rejects never — on signal it
    resolves with 128+signo convention and sets `signalCode`); `onExit`
    callback fires with `(subprocess, exitCode, signalCode, error)`.
- `Bun.spawnSync` maps onto `spawnImpl.spawnSync`, returning
  `{ success, exitCode, stdout, stderr, signalCode }` with stdout/stderr as
  `Buffer`s (Bun returns typed arrays; Buffer is a Uint8Array — fine).
- ENOENT from the impl → `Bun.spawn` throws synchronously with
  `code:'ENOENT'` (Bun throws; Node emits — you bridge by intercepting the
  `error` event before returning; document the design).

### `lib/util.js`

- `Bun.sleep(ms)` → Promise via timer; `Bun.sleepSync(ms)` via
  `Atomics.wait` on a SharedArrayBuffer.
- `Bun.env` → the injected env object (same reference).
- `Bun.version` from options; `Bun.revision` a fixed string.
- `Bun.stringWidth(str)` — terminal display width: ASCII printable = 1,
  zero-width joiners/combining marks = 0, East-Asian Wide/Fullwidth = 2,
  ANSI escape sequences stripped before measuring. Implement the Unicode
  ranges as a compact data table (no dependency). Perfect Unicode coverage
  is not required; the documented ranges are: combining (U+0300–U+036F,
  U+200B–U+200D, U+FE00–U+FE0F), wide (U+1100–U+115F, U+2E80–U+A4CF,
  U+AC00–U+D7A3, U+F900–U+FAFF, U+FF00–U+FF60, U+FFE0–U+FFE6, emoji
  U+1F300–U+1FAFF).
- `Bun.deepEquals(a, b, strict?)` — structural equality incl. Maps, Sets,
  typed arrays, Dates, cyclic references (track visited pairs).
- `Bun.hash(input)` — Wyhash is Bun's default; a documented stand-in is
  acceptable: implement FNV-1a 64-bit returning BigInt, and say so in
  Fidelity notes (programs use it for caching, not interop).
- `Bun.randomUUIDv7()` → RFC 9562 v7 UUID (timestamp from an injectable
  clock for tests).
- `Bun.fileURLToPath` / `Bun.pathToFileURL` → delegate to `node:url`.
- `Bun.gc()` → no-op returning 0 (document).
- `Bun.main` → `process.argv[1] || ''`.

## Edge cases you MUST handle (each needs a test)

1. `installBunGlobal()` twice without `force` → second throws `EEXIST`;
   with `force: true` → replaces cleanly.
2. `which`: name found in the 3rd of 5 PATH dirs; name that is a directory
   (not executable) → skipped; PATH entry that doesn't exist → skipped
   without throwing; `options.PATH` override respected.
3. `which` generic-path proof: spy-fs test showing identical call sequences
   for arbitrary names (the no-hardcoding test).
4. `Bun.file` on missing path: `exists()` false, `text()` rejects ENOENT,
   `size` 0 — and on a real temp file: correct text/json/bytes round-trip.
5. `Bun.write` string → file; BunFile → BunFile copy; auto-creates nested
   parent dirs; returns byte count for multi-byte UTF-8 (bytes, not chars).
6. `spawn` happy path with a fake impl: pid, streamed stdout via
   ReadableStream reader, `exited` resolves, `onExit` fires once.
7. `spawn` ENOENT → synchronous throw with `code:'ENOENT'`, no unhandled
   `error` event, no unhandled rejection (assert via
   `process.on('unhandledRejection')` guard in the test).
8. `spawnSync` with non-zero exit → `success === false`, exitCode correct,
   stdout Buffer intact.
9. Signal exit: fake impl reports SIGKILL → `exited` resolves 137,
   `signalCode === 'SIGKILL'`, `exitCode === null`.
10. `stringWidth`: `"hello"`=5, `"héllo"`=5 (combining), `"你好"`=4,
    `"\u001b[31mred\u001b[0m"`=3, emoji=2, empty=0.
11. `deepEquals`: cyclic objects equal to isomorphic cyclic objects; Map/Set
    order-insensitivity; `strict` distinguishing `{a:1}` vs class instance.
12. `randomUUIDv7`: version/variant bits correct; two UUIDs with the same
    injected timestamp still differ (random part); monotonic timestamps sort
    lexicographically.

## Test plan (minimum)

- Suites: `install.test.js`, `which.test.js`, `file.test.js`,
  `spawn.test.js`, `util-width.test.js`, `util-equals.test.js`,
  `util-misc.test.js`.
- Injected fakes for fs/spawn everywhere except one `file.test.js` section
  using `fs.mkdtempSync` real temp dirs (cleaned up in `after`).
- Target ≥ 120 assertions.

## Acceptance checklist

- [ ] `node --test test/` passes on Node 18+ (document the version used).
- [ ] Zero npm dependencies.
- [ ] All 12 edge cases have named tests.
- [ ] Grep proves no command-name literals in `lib/` (test fixtures may use
      arbitrary names).
- [ ] HANDOFF.md: install order relative to the target bundle, Fidelity
      notes (hash stand-in, gc no-op, width simplifications), and a 10-line
      usage example.

## Non-goals

- No `Bun.serve`, no `bun:sqlite`, no `Bun.build`, no FFI, no WebSocket
  server — the target CLIs don't need them; document their absence.
- No TypeScript, no bundling.
- No patching of Node globals other than installing `Bun`.
- No IPC protocol work (a separate component owns process bridging; your
  `spawnImpl` injection point is where they meet).
