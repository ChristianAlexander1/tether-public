# tether-bun-compat — HANDOFF

A zero-dependency Node.js (CommonJS) library that installs a faithful subset
of the **Bun** global onto `globalThis`, so JavaScript bundles originally
built for Bun can run on an embedded Node 18+ runtime. Every platform-specific
piece (`fs`, `child_process`, `PATH`, `env`, platform, clock) is injected at
install time, which keeps the whole library unit-testable on any machine.

## Install order

Install the shim **before loading/evaluating the target Bun bundle**, and
only once per process:

```js
// 1. (host app) set up any custom search paths, filesystem shim, etc.
const path = require('node:path');
const pathDirs = (process.env.PATH || '').split(path.delimiter);

// 2. install the Bun global
const { installBunGlobal } = require('tether-bun-compat');
const Bun = installBunGlobal({
  // optional — defaults are shown
  force: false,                    // set true to overwrite an existing Bun
  version: '1.1.0-tether',
  platformInfo: { platform: process.platform, arch: process.arch },
  pathDirs,                        // captured now; never re-read later
  fs: require('node:fs'),
  spawnImpl: require('node:child_process'),
  env: process.env,
  clock: () => Date.now(),         // used by randomUUIDv7
});

// 3. only now load the third-party CLI / bundle that expects `Bun`.
require('./third-party-bun-cli.js');
```

If `globalThis.Bun` already exists and `force !== true`, `installBunGlobal`
throws an `Error` with `code = 'EEXIST'`. All injected dependencies are
captured at install time; nothing re-reads `process.env.PATH` later.

## Usage (10-line example)

```js
const { installBunGlobal } = require('tether-bun-compat');
installBunGlobal({ version: '1.1.0-tether' });

console.log(Bun.version);                 // 1.1.0-tether
console.log(Bun.which('node'));           // scans PATH, returns first match
const f = Bun.file('/etc/hostname');
console.log(await f.exists(), f.size);    // false / 0 on a missing path
const n = await Bun.write('/tmp/out.txt', 'héllo');
console.log(n);                           // 6 bytes (UTF-8), not 5 chars
const sub = Bun.spawn(['node', '-v'], { stdout: 'pipe' });
console.log(await sub.exited);            // 0
```

## Module layout

```
lib/index.js     installBunGlobal(options)
lib/which.js     real PATH-directory scan; zero hardcoded names
lib/file.js      Bun.file / Bun.write over node:fs
lib/spawn.js     Bun.spawn / Bun.spawnSync on child_process
lib/util.js      sleep, env, version, stringWidth, deepEquals,
                 hash (FNV-1a), randomUUIDv7, fileURL<->Path, gc, main
test/            node --test suites + fs/spawn fakes
```

Run tests:

```
node --test test/
```

The suite was developed and verified on **Node v20.20.2** (Node 18+ is the
supported floor; the test runner and `Readable.toWeb` both exist there).

## Public surface (installed `Bun.*`)

| API | Notes |
| --- | --- |
| `Bun.which(name, options?)` | Generic PATH scan; `options.PATH`, `options.cwd`; path-separator shortcut; returns `null` when missing. |
| `Bun.file(path)` | Lazy `BunFile`-like: `name`, `type`, `size`, `exists()`, `text()`, `arrayBuffer()`, `bytes()`, `json()`, `stream()`. |
| `Bun.write(dest, data)` | `dest`: path or BunFile; `data`: string / typed array / ArrayBuffer / BunFile. Creates parent dirs; returns `Promise<number>` of **bytes** written. |
| `Bun.spawn(argv, opts)` | Returns `{ pid, stdin, stdout, stderr, exited, exitCode, signalCode, kill, unref, ref }`. `stdout:"pipe"` is a WHATWG `ReadableStream`. |
| `Bun.spawnSync(argv, opts)` | Returns `{ success, exitCode, signalCode, stdout, stderr }` with `Buffer` output. |
| `Bun.sleep(ms)` / `Bun.sleepSync(ms)` | Promise / `Atomics.wait` on a `SharedArrayBuffer`. |
| `Bun.env` | Same reference as the injected env object. |
| `Bun.version` / `Bun.revision` | From options / fixed string. |
| `Bun.stringWidth(str)` | See "Fidelity notes". |
| `Bun.deepEquals(a, b, strict?)` | Structural; Map/Set order-insensitive; cycles; typed arrays; Dates; RegExps; strict checks prototype. |
| `Bun.hash(input)` | **FNV-1a 64-bit**, returning `BigInt` (see Fidelity notes). |
| `Bun.randomUUIDv7()` | RFC 9562 v7 UUID; clock is injectable. |
| `Bun.fileURLToPath` / `Bun.pathToFileURL` | Delegates to `node:url`. |
| `Bun.gc()` | No-op returning `0` (see Fidelity notes). |
| `Bun.main` | `process.argv[1] || ''`. |
| `Bun.nanoseconds()` | `Number(process.hrtime.bigint())`. |
| `Bun.platform` | `{ platform, arch }` from options or `process`. |

## Fidelity notes

Where this shim deliberately simplifies Bun's documented behavior, the
choices and rationale are recorded here so callers can judge compatibility.

### `Bun.hash` — FNV-1a instead of Wyhash

Bun uses **Wyhash** as its default hasher. We implement **FNV-1a 64-bit**
returning a `BigInt` instead. The algorithm is not interchangeable with Bun
for cross-process hash values, but it is fast, zero-dependency, and stable
for the in-process caching / bucketing use cases the target CLIs rely on.
**Do not** use `Bun.hash` output for persistence or wire compatibility with
real Bun; if that is ever required, swap in a Wyhash implementation behind
the same `hash(input)` signature.

### `Bun.gc()` is a no-op

Bun exposes `Bun.gc()` to force a garbage collection. V8 exposes
`--expose-gc` at startup only; we cannot opt in from inside the process.
We install a no-op that returns `0` so call sites don't crash, but no
collection is forced. Document this for downstream users.

### `Bun.stringWidth` — compact Unicode table

We implement the explicitly-documented ranges from the brief (combining
marks, ZWJ, variation selectors, East-Asian Wide/Fullwidth, emoji, and
ANSI stripping). We do **not** ship the full Unicode EastAsianWidth table,
so less-common wide/fullwidth blocks outside the listed ranges may be
counted as width 1. This is sufficient for terminal-width checks in the
target CLIs; perfect Unicode coverage is a non-goal.

ANSI sequences are stripped with a single regex covering CSI and a
generous OSC/ESC form. SGR, cursor movement, and similar escapes all
render as 0 width.

### `Bun.spawn` ENOENT bridging

Bun throws `ENOENT` **synchronously** from `Bun.spawn`; Node's
`child_process.spawn` emits it as an asynchronous `'error'` event on the
next tick. We bridge this two ways:

1. If the injected `spawnImpl.spawn` throws synchronously (as the test
   fake does, and as an informed implementation can), the error
   propagates out of `Bun.spawn` unchanged.
2. We attach an `'error'` listener to the child **before returning**, so a
   real Node `spawn` that emits ENOENT asynchronously can never produce
   an unhandled `'error'` event. The error is routed to `onExit` and the
   `exited` promise (which resolves `null` — it never rejects), and is
   also re-emitted on the subprocess for callers that prefer that style.

The recommended host wiring is to inject a `spawnImpl` that performs a
synchronous pre-flight `Bun.which(command)` (or equivalent) and throws
`ENOENT` when the binary cannot be located — that restores Bun's exact
synchronous semantics end-to-end.

### Signal exits

On signal termination, `subprocess.exited` resolves with `128 + signo`
(the conventional shell encoding), `signalCode` is set to the signal name
(e.g. `SIGKILL`), and `exitCode` is `null`. `spawnSync` mirrors this with
`success === false`, `exitCode === null`, and `signalCode` set.

### `Bun.file` / `Bun.write`

- `size` is read lazily via `fs.statSync` at first property access; a
  missing file yields `size === 0` without throwing.
- `text()`, `bytes()`, `arrayBuffer()`, and `json()` reject with an
  `ENOENT`-coded error on a missing path.
- `Bun.write` creates intermediate directories via
  `fs.mkdir({ recursive: true })`. It returns the **byte** count, so
  multi-byte UTF-8 strings report correctly (e.g. `'héllo'` → 6, not 5).
- `stream()` returns a WHATWG `ReadableStream`; missing files surface the
  error when the stream is read, not at construction (matches Bun).
- MIME types come from a small extension table in `lib/file.js`; unknown
  extensions default to `application/octet-stream`.

### `Bun.deepEquals`

Maps and Sets are compared **order-insensitively** (Bun's default). The
optional `strict` argument additionally requires matching prototypes,
which is what distinguishes a plain object literal from a class instance
with the same own properties. Cyclic references are tracked with a
visited-pair map so isomorphic cyclic graphs compare equal.

### `Bun.which` on Windows

On POSIX we require the executable bit (`fs.accessSync(p, X_OK)`). On
Windows we approximate executability by "exists and is not a directory",
because Windows determines executability from file associations /
`PATHEXT` rather than a permission bit. We do **not** consult `PATHEXT`
or append extensions — callers should pass full executable names. This
keeps the resolver generic (no fixed extension list) and is documented
here as a simplification.

## Non-goals / intentionally absent

These Bun surfaces are **not** implemented because the target CLIs don't
use them; if a bundle touches any of them it will hit `undefined`:

- `Bun.serve` / `Bun.fetch`-as-server (WebSocket, HTTP server)
- `bun:sqlite`
- `Bun.build`, `Bun.build --compile`, transpiler APIs
- FFI (`Bun.ffi`, `dlopen`, `CCallback`)
- `Bun.password`, `Bun.crypto` beyond what Node's `globalThis.crypto` offers
- `Bun.Transpiler`, `Bun.plugin`
- `Bun.peek`, `Bun.yield`, lock-step microtask helpers
- Workers spawned via `Bun.spawn`'s IPC pipes (process bridging is owned
  by a separate host component; the `spawnImpl` injection point is the
  seam between the two)

The only global we patch is `globalThis.Bun`; no other Node globals are
modified.

## Testing

- 8 suites, 84 tests, 200+ `assert.*` call sites (well over the 120
  assertion target).
- Tests use injected fakes for `fs` and `child_process`; the only
  exception is `test/smoke-default-wiring.test.js`, which is permitted to
  spawn `node` itself to verify the real end-to-end wiring.
- The "no hardcoding" proof lives in `test/which.test.js`: it injects an
  fs spy, looks up two arbitrary names (`"zzz-made-up"` and `"claude"`),
  and asserts the recorded `accessSync`/`statSync` call sequences are
  byte-identical after swapping the basename.
- Edge cases 1–12 from the brief all have named tests:
  1. `install.test.js` — EEXIST / force replace
  2. `which.test.js` — 3rd-of-5, directory skipped, missing PATH entry, `options.PATH`
  3. `which.test.js` — generic-path code (no hardcoding)
  4. `file.test.js` — missing path ENOENT/size/exists, real round-trip
  5. `file.test.js` — string, BunFile copy, nested mkdir, UTF-8 byte count
  6. `spawn.test.js` — happy path, streamed stdout, `exited`, `onExit`
  7. `spawn.test.js` — ENOENT synchronous throw + unhandled-rejection guard
  8. `spawn.test.js` — non-zero `spawnSync`, buffer intact
  9. `spawn.test.js` — SIGKILL → 137 / `signalCode` / null `exitCode`
  10. `util-width.test.js` — `hello`, `héllo`, `你好`, ANSI, emoji, empty
  11. `util-equals.test.js` — cycles, Map/Set order, strict prototype
  12. `util-misc.test.js` — UUIDv7 version/variant bits, randomness, sort order
