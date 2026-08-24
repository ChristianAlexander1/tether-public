# TetherShellLang — Track P2 handoff

POSIX shell **parser + evaluator** as a standalone, dependency-free Swift
package. Shell script text is parsed into an AST and executed against a
`ShellHost` callback — **no OS processes, no file system, no environment**
of its own. Everything external goes through the host.

- **Package:** `TetherShellLang` (library)
- **Toolchain used:** Swift 6.0.3 (Debian `swiftlang` 6.0.3-2), `swift-tools-version:5.9`
- **License:** MIT (see `LICENSE`)
- **Behavior reference:** mksh (MirOS) unless POSIX says otherwise

```
TetherShellLang/
├── Package.swift
├── LICENSE
├── Sources/TetherShellLang/
│   ├── ShellHost.swift      # public ShellHost protocol + TetherShellParseError
│   ├── AST.swift            # TetherWord/HereDoc/Redirect/Command/Program tree
│   ├── ScanUtil.swift       # quote-aware scanners ($( .. ), ${ .. }, quotes)
│   ├── Lexer.swift          # tokenizer, keeps words raw + here-doc bodies
│   ├── Parser.swift         # recursive-descent POSIX/mksh grammar → AST
│   ├── Glob.swift           # TetherGlob pattern tokens + matcher
│   ├── Arithmetic.swift     # full C/ksh arithmetic (incl. base#n, **, ++)
│   ├── Expansion.swift      # parameter/cmdsub/arith/split/glob engine
│   ├── Evaluator.swift      # TetherShell: execution, scoping, virtual FS
│   └── Builtins.swift       # builtin commands + test/[ parser
├── Tests/TetherShellLangTests/
│   ├── TestSupport.swift    # MockShellHost + fixture directive parsing
│   ├── FixtureTests.swift   # runs all fixture pairs
│   ├── LexerTests.swift / ParserTests.swift / ArithmeticTests.swift
│   ├── GlobTests.swift / ExpansionTests.swift / EvaluatorTests.swift
│   └── fixtures/            # 66 pairs: NN_name.sh + NN_name.expected
└── HANDOFF.md
```

## Using it

```swift
import TetherShellLang

final class MyHost: ShellHost {
    func run(commandLine: String) -> Int32 { /* run forward */ return 0 }
    func write(_ text: String)         { /* stdout sink */ }
    func writeError(_ text: String)    { /* stderr sink */ }
    func value(for name: String) -> String? { nil }
    func setValue(_ value: String?, for name: String) {}
}

let shell = TetherShell(host: MyHost())
shell.arguments = ["one", "two"]          // becomes $1..$n, $#, $@, $*
shell.setVirtualFile("input.txt", contents: "hello\n")
let status = try shell.run("""
    cat < input.txt | {
        while read line; do echo "got: $line"; done
    }
    """)
// shell.lastStatus == status ($?)
```

Public surface: `init(host:)`, `run(_ source: String) throws -> Int32`,
`parse(_ source:) throws -> TetherProgram`, `run(_ program:) -> Int32`, plus knobs
`fileSystem`, `scriptName` (`$0`), `pid` (`$$`), `arguments`, `cwd`,
`maxCommandExecutions`, `setVirtualFile(_:contents:)`, `virtualFile(_:)`.

**Naming.** Per the Tether rule, every public type carries the `Tether`
prefix (`TetherShell`, `TetherShellParseError`, `TetherShellParser`,
`TetherProgram`, `TetherCommand`, `TetherWord`, `TetherRedirect`,
`TetherGlob`, …) and all folders are `TetherShellLang` /
`TetherShellLangTests`. The only unprefixed public type is `ShellHost`,
which is fixed by the track's interface contract. Module-internal helpers
(`Lexer`, `Parser`, `ScanUtil`, …) are non-public implementation details.

## Supported syntax

| Area | Support |
|---|---|
| Lists | `;` `&&` `||` `!` pipelines `\|`; `&` runs synchronously, status 0 |
| Conditionals | `if/elif/else/fi`, `test`, `[ ]` (`-z -n = != -eq -ne -lt -le -gt -ge -e -f -d -s`, `!`, `-a`, `-o`, `( )`) |
| Loops | `while`, `until`, `for x [in ...]`, `for ((i=0; i<n; i++))`, `break [n]`, `continue [n]` |
| Case | `case/esac`, `\|`-alternation, optional `(`, `;;`, mksh `;&` (fall-through) and `;;&` (re-test) |
| Functions | `name() compound`, `function name compound`, `local`, `return`, recursion, redirects stored per call; dynamic scoping like mksh |
| Parameters | `$x` `${x}` `$1..$9 ${10}` `$@` `$*` `$#` `$?` `$$` `$0` `$-` `$!`, `${x:-w}` `${x-w}` `${x:=w}` `${x:=?}` `${x:?w}` `${x:+w}` `${x+w}`, `${#x}`, `${x#p}` `${x##p}` `${x%p}` `${x%%p}` |
| Substitution | `$( ... )` (nested), `` `...` `` (legacy), `$(( ... ))` |
| Arithmetic | C/ksh precedence: `* / % + - << >> < <= > >= == != & ^ \| && \|\| ?: ,`, assignments `= += -= *= /= %= <<= >>= **= &= \|= ^=`, `++ --` pre/post, `**` (right-assoc), `0x..`, `0..` octal, `base#n` (2–36); `(( cmd ))` |
| Quoting | single, double, backslash, `$'…'` not supported (mksh extension, out of scope) |
| Redirects | `<` `>` `>>` `<>` `>\|`, `N>`, `N>>`, `>&N`, `<&N`, `>&-`, `2>&1` etc., here-docs `<<`/`<<-` (quoted delimiter = literal), here-strings `<<<`; redirects on **all** compound commands |
| Sourcing | `. file [args]` / `source`, runs in current shell with positional save/restore |
| Builtins | `echo` (`-n -e -E`), `printf` (`%s %d %i %u %x %X %o %c %b %%`, width/precision/flags, format recycling), `true`, `false`, `:`, `test`, `[`, `read` (`-r`, IFS split, remainder to last var, `REPLY`), `cat`, `shift`, `set [--]`, `export`, `local`, `unset` (`-f`/`-v`), `eval`, `.`, `source`, `command`, `exec`, `exit`, `return`, `break`, `continue`, `pwd`, `cd` (virtual) |
| Word ops | field splitting via `$IFS`, quoted `$@`/`$*` field semantics, pathname glob (`* ? [...]`) over the virtual FS, tilde `~`/`~/` via `$HOME` |

## Execution model notes

- **Virtual file system.** Redirects write to an in-memory `[path: content]`
  map (`/`-rooted, `.`/`..` normalized). `cat`, `<`, `. file`, `[ -e ]`, and
  globbing all read from it, and each `TetherShell` has its own copy.
  `/dev/null` is special-cased. This keeps tests fully deterministic.
- **Environment layering.** Plain assignments stay in the shell unless the
  name is exported; `export` mirrors into the host (`setValue`). Reads fall
  through to the host. `NAME=val cmd` is a temporary scope for the command's
  duration (POSIX), and `local` uses mksh-style dynamic scoping.
- **Subshells** (`( ... )` and command substitution) snapshot variables,
  functions, positionals *and* the virtual FS; host-env writes from inside
  are captured by an overlay so nothing leaks outward. `exit`/`$?` behavior
  matches.
- **Pipelines** run left-to-right; each stage's captured stdout becomes the
  next stage's stdin (buffers like mksh's temp files). The last stage runs
  in the current shell, so `echo x | read v` keeps `v` — mksh's default too.
- **Here-docs** are collected by the lexer at the terminating newline, in
  command order, with `<<-` tab stripping; expansion inside follows POSIX
  (params/arithmetic/cmdsub only).
- **Safety valve:** `maxCommandExecutions` (default 250 000) aborts runaway
  scripts instead of hanging the host.

## Known limits (documented, not bugs)

1. `ShellHost.run(commandLine:)` receives one expanded **string**. Piped
   stdin can't cross that boundary, and command substitutions *of external
   commands* capture nothing — builtins make both fully testable, per the
   track's mock-host design.
2. Globbing covers virtual-FS basenames only (there are no subdirectories),
   and dotfiles aren't special-cased.
3. Custom `$IFS` characters all behave like whitespace runs; the full
   POSIX whitespace/non-whitespace IFS split rules are simplified.
4. Arrays (`${arr[i]}`) abort with a diagnostic — mksh arrays are out of scope.
5. `$((a - -b))` with a space between the inner operators won't parse;
   `$((a - - b))` and `$((a- -b))` also collapse. Use `a + (-b)` style.
   (`<=` glued or split both work, since adjacent operators rejoin cleanly.)
6. `&`, `!` job control, traps, and `getopts` are absent (no processes).

## Testing

**Fixtures: 66 pairs** (spec required 50+) under
`Tests/TetherShellLangTests/fixtures/`, executed alphabetically by
`FixtureTests.testAllFixtures` against a fresh `MockShellHost` each time.
Every `.sh` runs through the real parser+evaluator; the transcript
(stdout, then a `[stderr]` block when non-empty, plus directive assertions)
is compared byte-for-byte with the sibling `.expected` file.

Fixture directives (shell comments, so fixtures are still self-contained
scripts): `#@ argv:` / `#@ env:` / `#@ cmd:` / `#@ cmdout:` / `#@ file:` /
`#@ want:` / `#@ status:` / `#@ verify-env:`.

Coverage map of the fixtures: selection (01–04, 52-if variants), loops
(05–12, 24, 43), `case` incl. `;&`/`;;&`/globs/defaults (13–16, 66),
functions (17–20, 56), arithmetic (21–24, 63), parameter expansion
(25–27, 65), command substitution (28), pipes (29–31), `&&`/`||` (32),
redirects incl. compounds (33–36, 56), here-docs/-strings (37–40),
`read` (41–43), `.` sourcing (44–45), subshell/groups (46–47),
positionals (10, 48, 64), `test`/`[` (49–50), statuses/`exit` (31, 51, 52),
quoting/splitting/globbing (53–55, 59), `eval` (57), `printf` (58),
`unset`/`export` (60–61), comments/multi-line (62).

Additionally **63 unit/behavior test methods** across `LexerTests`,
`ParserTests`, `ArithmeticTests`, `GlobTests`, `ExpansionTests` and
`EvaluatorTests` (64 XCTest tests in total with the fixture runner).

### `swift test` output (verbatim tail)

```
Test Suite 'ArithmeticTests' passed
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.204 (0.204) seconds
Test Suite 'EvaluatorTests' passed
	 Executed 17 tests, with 0 failures (0 unexpected) in 0.212 (0.212) seconds
Test Suite 'ExpansionTests' passed
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.003 (0.003) seconds
Test Suite 'FixtureTests' passed
	 Executed 1 test, with 0 failures (0 unexpected) in 0.033 (0.033) seconds
Test Suite 'GlobTests' passed
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.101 (0.101) seconds
Test Suite 'LexerTests' passed
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds
Test Suite 'ParserTests' passed
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds
Test Suite 'debug.xctest' passed
	 Executed 64 tests, with 0 failures (0 unexpected) in 0.557 (0.557) seconds
Test Suite 'All tests' passed
	 Executed 64 tests, with 0 failures (0 unexpected) in 0.557 (0.557) seconds
```

**Result: 64/64 tests green, 66/66 fixtures passing.**

## How to run

```sh
cd TetherShellLang
swift build        # library
swift test         # full suite (unit + fixtures)
```
