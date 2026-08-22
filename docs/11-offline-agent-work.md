# TermX — Standalone Work Packages (for an agent with no repo access)

**Read this first.** You are building **self-contained components** for an iOS terminal app
called TermX. You will **not** be given the app's source code, and you must **not** assume
any of it exists. Everything you need is specified in this document.

You will create **new folders from scratch**, each with its own build file and tests, that
run on their own. The maintainer will merge them into the app afterwards. Because of that:

- **Never** write `import TermXCore`, `require('../..')`, or reference any TermX file.
- **No third-party dependencies.** Swift: standard library + Foundation only. JavaScript:
  Node built-ins only (use the built-in `node:test` runner — do not add Jest/Mocha).
- **Implement the exact interfaces given below, byte for byte.** They are the contract the
  maintainer merges against. Do not rename types, change signatures, or "improve" the
  shapes. Add extra internal helpers freely. **The interface blocks are declaration
  sketches — you must supply real bodies** (an `init` shown without `{ … }`, or a
  `static let all: [T]` shown without a value, will not compile as written).
- **Your code must compile.** If you have no Swift/Node toolchain, say so up front and
  keep the delivery small and simple — an unbuildable 3,000-line package costs the
  maintainer more than it saves. Prefer straightforward code over clever code.
- **Pure functions where specified.** Do not call `fork`, `exec`, `Process`, `posix_spawn`,
  `system`, or spawn OS processes anywhere in delivered code (iOS forbids it). Do not
  `import UIKit` or `import Darwin`; use Foundation so the code builds on Linux and macOS.
- **No stubs.** Anything you cannot finish must return a real error, and be listed under
  "Not implemented" in your `HANDOFF.md`. Never return success having done nothing.
- **Tests must actually run.** Paste the real command and its real output into `HANDOFF.md`.

Pick the work package you were assigned. Each one is independent.

---

# WP-A — `termx-shim` (JavaScript, Node.js)

## What it is

TermX runs Node.js inside an iOS app. iOS forbids creating child processes, so Node's
`child_process` module cannot work normally. This shim **replaces `child_process`** and
forwards every request over a JSON channel to the app's own command engine, which runs the
command in-process and replies.

This is what lets `npm install` and Claude Code work inside the app, so correctness against
real Node semantics matters more than anything else here.

## Folder to create

```
termx-shim/
├── package.json              # name "@termx/shim", type "commonjs", scripts.test
├── index.js                  # installs the overrides (entry point, see below)
├── lib/
│   ├── child_process.js      # the full replacement module
│   ├── os.js                 # platform overrides
│   ├── tty.js                # isatty overrides
│   └── ipc.js                # transport: request → reply
├── test/
│   ├── mock-backend.js       # fake engine implementing the protocol (yours, for tests)
│   └── *.test.js             # node:test files
└── HANDOFF.md
```

`index.js` is preloaded by the app with `node --require /path/to/index.js`. It must patch
the module system so that any `require('child_process')` / `require('node:child_process')`
inside npm or any package returns your implementation, and likewise for the `os` and `tty`
overrides. Patching `Module._load` is the expected approach.

## The wire protocol (fixed — the app already speaks this)

Transport is selected by environment variables, in this order:

| Variable | Meaning |
|---|---|
| `TERMX_IPC_SOCKET` | Path to a Unix socket. **This is what the app sets today** — if present, use it. |
| `TERMX_IPC_FD` / `TERMX_IPC_REPLY_FD` | Numeric fds: write requests to the first, read replies from the second. Fallback transport; keep it working. |
| `TERMX_INTERACTIVE` | `"1"` when attached to a terminal, else `"0"`. |

One request is **one line of JSON terminated by `\n`**. One reply is **one line of JSON
terminated by `\n`**. Requests are synchronous: write one, read exactly one reply.

**Request:**
```json
{ "op": "spawnSync",
  "file": "git",
  "args": ["status", "--short"],
  "cwd": "/workspaces/proj",
  "env": { "PATH": "/bin" },
  "shell": false,
  "interactive": false }
```
`op` is one of `"spawn"`, `"spawnSync"`, `"signal"`. To kill a child, send
`{ "op": "signal", "pid": 12, "signal": "SIGTERM" }` — note the op is **`signal`**, not
`kill`; the app replies `{ "ok": true }`. An unrecognised op replies
`{ "error": "unknown op <name>" }`.

**Reply:**
```json
{ "pid": 12, "exitCode": 0, "stdout": "…", "stderr": "…",
  "signal": null, "error": null, "code": null, "encoding": "utf8" }
```
`error` is a message string when the command could not be started (then `code` is e.g.
`"ENOENT"`); otherwise `null`. The app currently always returns `stdout`/`stderr` as
complete strings after the command finishes, so `spawn`'s streams are fed once and then
ended — implement it that way, and note in `HANDOFF.md` that incremental streaming is a
future protocol addition.

Keep all protocol handling in `lib/ipc.js` behind one function, e.g.
`roundTrip(requestObject) -> replyObject`, so the transport can be swapped in tests.

## What to implement

**`child_process`, complete and Node-accurate:**
`spawn`, `spawnSync`, `exec`, `execSync`, `execFile`, `execFileSync`, `fork`.

- Argument normalisation for every documented call form, including `(file)`,
  `(file, args)`, `(file, options)`, `(file, args, options)`, and callback variants.
- `spawn` returns a `ChildProcess`: an `EventEmitter` with `stdout` and `stderr` as
  readable streams (push the returned text, then end them), `stdin` as a writable,
  and properties `pid`, `exitCode`, `signalCode`, `killed`, plus `kill(signal)`,
  `ref()`, `unref()`. It must emit `'spawn'`, then `'exit'` (code, signal), then
  `'close'` (code, signal) — in that order, asynchronously, never before the caller has
  had a chance to attach listeners. Emit `'error'` (not `'exit'`) when the command could
  not start.
- Options honoured: `cwd`, `env`, `shell` (`true` → run through `sh -c`, or an explicit
  path), `stdio` (`'pipe'`, `'inherit'`, `'ignore'`, and array forms), `encoding`
  (including `'buffer'`), `input` (sync variants), `maxBuffer` (exceeding it fails with
  code `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`), `timeout` + `killSignal`, `argv0`,
  `windowsHide` (accept and ignore).
- Return/throw shapes must match Node exactly, because npm inspects them:
  - `spawnSync` → `{ pid, output: [null, stdout, stderr], stdout, stderr, status, signal, error }`
    where `stdout`/`stderr` are Buffers unless an `encoding` says otherwise.
  - `execSync` throws on non-zero exit; the thrown Error carries `status`, `signal`,
    `stdout`, `stderr`, and `message` ending with the command.
  - `exec`/`execFile` callbacks receive `(error, stdout, stderr)`; on non-zero exit the
    error has `code` (the exit status) and `killed`.
  - A missing command produces an Error with `code: 'ENOENT'`, `errno: -2`,
    `syscall: 'spawn <file>'`, `path: <file>`.
- `fork` runs a Node module through the same channel and supports the IPC surface:
  `child.send(msg)`, `'message'` events, `child.disconnect()`. If full IPC is not
  achievable through the protocol, implement the object shape faithfully and document the
  limitation precisely in `HANDOFF.md`.

**`os` overrides:** `platform()` → `'darwin'`; `type()` → `'Darwin'`; `arch()` → `'arm64'`;
`homedir()` from `HOME`; `tmpdir()` from `TMPDIR`; `release()`, `cpus()`, `totalmem()`,
`freemem()`, `endianness()`, `EOL` returning sane values. Everything else passes through to
real `os`.

**`tty` overrides:** `isatty(fd)` → true for fds 0/1/2 when `TERMX_INTERACTIVE === '1'`,
false otherwise. Keep `ReadStream`/`WriteStream` passthrough.

## Tests (required)

`test/mock-backend.js` implements the protocol over a pair of fds or an in-process fake, so
the whole shim runs with **no app, no Swift, no iOS**. Cover at least:

1. `spawn` collecting stdout, with `'exit'` and `'close'` ordering asserted.
2. `spawn` of a missing command emitting `'error'` with the ENOENT shape.
3. `spawnSync` with `input`, and Buffer vs string `encoding`.
4. `exec` callback on success and on non-zero exit (error `code` set).
5. `execSync` throwing with `status`/`stdout`/`stderr` populated.
6. `maxBuffer` overflow producing `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`.
7. `timeout` terminating a long command and reporting the signal.
8. `shell: true` routing through `sh -c` (assert the request payload).
9. `stdio: 'inherit'` and `'ignore'` behaviour.
10. `os.platform()` and `tty.isatty` under both `TERMX_INTERACTIVE` values.

`npm test` must run them all with the built-in runner and exit 0.

---

# WP-B — `TermXShellLang` (Swift, pure Foundation)

## What it is

A shell language layer: parsing and evaluating the constructs a POSIX shell needs. The app
already handles pipelines, redirects, `&&`/`||`/`;`, background jobs and `for` loops. You
are building **everything else**, as a standalone library that never runs a command itself —
it asks a delegate to run command lines and uses the exit codes.

## Folder to create

```
TermXShellLang/
├── Package.swift                       # swift-tools-version: 5.9, no platforms line,
│                                       # one library product "TermXShellLang"
├── Sources/TermXShellLang/
│   ├── ArithmeticEvaluator.swift
│   ├── ParameterExpander.swift
│   ├── HereDocProcessor.swift
│   ├── WordExpander.swift              # brace + tilde expansion
│   ├── ScriptParser.swift              # your AST for the constructs below
│   └── ScriptEvaluator.swift
├── Tests/TermXShellLangTests/*.swift
└── HANDOFF.md
```

## Exact public interfaces (copy these verbatim)

```swift
/// Everything the evaluator needs from the outside world. The app implements this;
/// your tests implement a fake that records command lines and returns canned exit codes.
public protocol ShellHost: AnyObject {
    /// Runs one already-expanded command line (may contain pipes/redirects) and returns
    /// its exit code. Your code must never execute commands itself.
    func run(commandLine: String) -> Int32
    /// Writes to the shell's stdout / stderr.
    func write(_ text: String)
    func writeError(_ text: String)
    /// Variable storage shared with the surrounding shell.
    func value(for name: String) -> String?
    func setValue(_ value: String, for name: String)
}

public enum ArithmeticEvaluator {
    /// Evaluates `$(( … ))` contents. Supports + - * / % ** unary +/- , comparisons
    /// (== != < <= > >=), logical && || !, bitwise & | ^ << >> ~, ternary ?: ,
    /// parentheses, decimal/0x/0 octal literals, and bare variable names resolved
    /// through `variables` (unset or non-numeric = 0). Assignment forms
    /// (= += -= *= /= %= and ++/--) update `variables`.
    public static func evaluate(_ expression: String,
                                variables: inout [String: String]) throws -> Int
}

public enum ParameterExpander {
    /// Expands one word's ${...} forms: ${V}, ${V:-d}, ${V:=d}, ${V:?msg}, ${V:+alt},
    /// ${#V}, ${V#pat}, ${V##pat}, ${V%pat}, ${V%%pat}, ${V/a/b}, ${V//a/b},
    /// ${V:offset}, ${V:offset:length}. Patterns are shell globs (* ? [...]).
    /// `:?` throws. Leaves $VAR / $(...) / $((...)) untouched — other layers handle them.
    public static func expand(_ word: String,
                              variables: inout [String: String]) throws -> String
}

public enum WordExpander {
    /// Brace expansion: {a,b,c} and {1..9} / {a..e} / {1..9..2}, including nesting and
    /// multiple groups per word. Returns words in shell order.
    public static func expandBraces(_ word: String) -> [String]
    /// Tilde expansion: ~ and ~/path using `home`. Unknown ~user is returned unchanged.
    public static func expandTilde(_ word: String, home: String) -> String
}

public enum HereDocProcessor {
    public struct Extraction: Equatable {
        public let commandLine: String   // the command with the here-doc operator removed
        public let body: String          // the here-doc body, expansions already applied
                                         // unless the delimiter was quoted
        public let remainder: [String]   // script lines after the here-doc terminator
    }
    /// Given the line containing `<<WORD` / `<<-WORD` / `<<'WORD'` and the lines that
    /// follow, returns the command, its body, and the unconsumed remainder.
    /// `<<-` strips leading tabs from body lines and the terminator.
    public static func extract(line: String,
                               following: [String],
                               variables: inout [String: String]) throws -> Extraction
}

/// The constructs you parse. Anything that is not one of these is `.command(String)`,
/// which the evaluator hands to `ShellHost.run(commandLine:)` unchanged.
public indirect enum ShellNode: Equatable {
    case command(String)
    case sequence([ShellNode])
    case ifStatement(conditions: [(ShellNode, ShellNode)], elseBranch: ShellNode?)
    case whileLoop(condition: ShellNode, body: ShellNode, isUntil: Bool)
    case caseStatement(subject: String, cases: [(patterns: [String], body: ShellNode)])
    case functionDefinition(name: String, body: ShellNode)
    case breakLoop(levels: Int)
    case continueLoop(levels: Int)
    case returnFromFunction(code: Int32?)
}

public enum ScriptParser {
    /// Parses a script. Returns nil when `source` contains none of the constructs above
    /// (so the caller can fall back to its existing single-line path).
    /// Throws on genuinely malformed input (`if` with no `fi`, unterminated `case`, …).
    public static func parse(_ source: String) throws -> ShellNode?
}

public final class ScriptEvaluator {
    public init(host: ShellHost)
    /// Evaluates a parsed script and returns the exit code of the last command run.
    public func evaluate(_ node: ShellNode, variables: inout [String: String]) throws -> Int32
    /// Calls a function defined earlier by `functionDefinition`, binding $1…$9, $#, $@, $*.
    public func callFunction(named: String, arguments: [String],
                             variables: inout [String: String]) throws -> Int32
}

public enum ShellLangError: Error, Equatable {
    case syntax(String)
    case parameterUnset(String)   // ${V:?msg}
    case arithmetic(String)
    case undefinedFunction(String)
}
```

## Behaviour that must be right

- `if / then / elif / else / fi` with the condition's exit code deciding the branch
  (0 = true). `while` / `until` with `break`, `break 2`, `continue`.
- `case x in a*) … ;; b|c) … ;; *) … esac` using glob matching, first match wins,
  `;;` terminating.
- Functions: both `name() { … }` and `function name { … }`; `$1…$9`, `$#`, `$@`, `$*`,
  `return`, and restoring the caller's positional parameters afterwards.
- Nesting must work: loops inside conditionals inside functions, arbitrarily deep.
- Comments (`#`), blank lines, `;` separators, and multi-line constructs written on one
  line (`if [ -f x ]; then echo y; fi`) all parse.

## Tests (required)

XCTest with a fake `ShellHost` that returns scripted exit codes and records what was run.
Cover every construct plus: nesting three deep, `break 2`, a function calling another
function, `${V:-d}` family (each form), 20+ arithmetic expressions including precedence and
assignment, brace/tilde expansion, all three here-doc forms, and each `ShellLangError`.
`swift test` must pass.

---

# WP-C — `TermXCommands` (Swift, pure Foundation)

## What it is

Unix commands as **pure functions**: text in, text out, no process spawning. The app wires
them to real file descriptors; you never touch fds.

## Folder to create

```
TermXCommands/
├── Package.swift                      # swift-tools-version: 5.9, no platforms line,
│                                      # library product "TermXCommands"
├── Sources/TermXCommands/
│   ├── CommandIO.swift                # the interfaces below, exactly as written
│   ├── SedCommand.swift
│   ├── AwkCommand.swift
│   ├── DiffCommand.swift
│   └── … one file per command
├── Tests/TermXCommandsTests/*.swift
└── HANDOFF.md
```

## Exact public interfaces (copy these verbatim)

```swift
public struct CommandIO {
    public let argv: [String]          // argv[0] is the command name
    public let stdin: String           // "" when nothing is piped in
    public let cwd: String             // absolute; resolve relative paths against it
    public let environment: [String: String]
    public init(argv: [String], stdin: String = "", cwd: String, environment: [String: String] = [:])
}

public struct CommandResult: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0)
}

public protocol TermXCommand {
    /// The name typed in the shell, e.g. "sed".
    static var name: String { get }
    /// Runs the command. Must never spawn a process, never call exit(), never crash.
    static func run(_ io: CommandIO) -> CommandResult
}

/// Lookup table the maintainer registers with the app.
public enum TermXCommandRegistry {
    public static let all: [any TermXCommand.Type]   // every command you implement
    public static func command(named: String) -> (any TermXCommand.Type)?
}
```

## Rules for every command

- **No file operands ⇒ read `io.stdin`.** A literal `-` operand also means stdin. This is
  what makes pipelines work and is the most common thing to get wrong.
- Errors go to `stderr` as `name: message`, with a non-zero `exitCode` (use `1` for general
  failure, `2` for usage errors) — never to stdout.
- Unknown flags produce a usage error; they must not crash or be silently ignored.
- Reading a missing file is an error, not an empty result.
- Filesystem access is allowed via `FileManager`/`String(contentsOfFile:)`; resolve every
  relative path against `io.cwd`.

## Commands to implement, in priority order

**Priority 1 (the app's AI agent shells out to these constantly):**
- `sed` — `s/pat/rep/[gIp]` with any delimiter, `-n`, `-e`, `-f`, `-i`, `d`, `p`, `q`,
  line-number and `/regex/` addresses and ranges, `\1`-style backreferences.
- `awk` — `-F`, `-v`, `BEGIN`/`END`, `/regex/` and expression patterns, `$0…$NF`, `NR`,
  `NF`, `FS`, `OFS`, `print`, `printf`, variables, arithmetic, string comparison,
  `if`/`for`/`while` inside actions, and the functions `length substr index split
  toupper tolower gsub sub match sprintf`.
- `diff` — unified `-u` (correct hunk headers and context), `-q`, exit code 0 same /
  1 different / 2 error.
- `chmod` (octal and symbolic `u+x`, `go-w`, `a=r`, `-R`), `stat` (`-c`/`%` format),
  `readlink` (`-f`), `mktemp` (`-d`, template `XXXXXX`).

**Priority 2:** `tac`, `rev`, `nl`, `split`, `comm`, `join`, `paste`, `fold`, `expand`,
`unexpand`, `shuf`, `expr`, `md5sum`, `shasum` (`-a 1|256|512`), `xxd`, `hexdump -C`,
`file` (by magic bytes), `truncate`, `printenv`, `id`, `tree`, `timeout`.

**Priority 3:** `gzip`/`gunzip` and `tar` (`-c -x -t -z -f -v`, ustar + GNU long names),
`zip`/`unzip`, `base64` (`-d`, `-w`), and `curl`/`wget` on `URLSession`
(`-o -O -L -s -S -I -H -X -d --fail --max-time`, correct exit codes; **synchronous** —
block on a semaphore and return the result).

Do as many as you can in order. A smaller set done properly beats a large set of
approximations — list exactly what you finished in `HANDOFF.md`.

## Tests (required)

An XCTest per command with real fixtures, always including a **stdin case** and an **error
case**. Compare against real Unix output (run the real tool on your machine to generate
expected values, and say so in the test comments). `swift test` must pass.

---

# What to deliver (all packages)

Deliver the folder exactly as laid out, plus `HANDOFF.md` containing:

1. What you implemented, and what you deliberately left out.
2. The exact test command and its **real** output, pasted.
3. Any assumption you made about the protocol or interfaces.
4. Anything the maintainer must wire up on their side.

Do not modify the given interfaces. If one seems wrong, implement it as specified and
explain the concern in `HANDOFF.md` instead.
