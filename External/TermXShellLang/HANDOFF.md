# HANDOFF — WP-B `TermXShellLang`

A standalone Swift (pure Foundation) library that models the POSIX-shell language
layer: arithmetic, parameter expansion, word expansion, here-docs, and the
parsing/evaluation of `if`/`while`/`until`/`case`/functions plus `break`/`continue`/
`return`. It never runs a command itself — it asks a `ShellHost` delegate to run
command lines and uses their exit codes.

**Important:** the sandbox used to build this has no Swift toolchain for its OS
(Debian 13; swift.org's `swiftly` installer and the direct toolchain tarballs
rejected/404'd on it — verified). The code was written and reviewed carefully but
**could not be compiled or `swift test`-ed here**. Please run `swift test` on the
maintainer's machine. The exact command is at the bottom.

## 1. What was implemented

### `ScriptParser` (ShellNode AST + recursive-descent parser)
- A **word-token lexer** (one token per shell word, structurally aware of `'…'`,
  `"…"`, `$(…)`, `$((…))`, `${…}`, `\` escaping, and `;`/`;;`/`{`/`}`/`(`/`)`/newline).
  The *parser* is what recognizes keywords, so `case foo in`, `echo in`,
  `echo then`, and `name() { … }` all tokenize correctly (a known pitfall that a
  naive lexer gets wrong).
- Parses: `command` (verbatim), `sequence`, `if / then / elif / else / fi`,
  `while`/`until … do … done`, `case x in p)…;; esac` (glob patterns, `a|b`,
  first-match-wins, `;;`), function definitions in **both** forms
  (`name() { … }` and `function name { … }`), `break N`, `continue N`, `return N`,
  and brace groups `{ … }` / subshell `( … )`.
- Returns `nil` when a script contains none of the modelled constructs (so the app
  can fall back to its single-line path); throws `ShellLangError.syntax` on
  malformed input (`if` without `fi`, unterminated `case`/missing `esac`, missing
  `}` in a function, unterminated here-doc, etc.).
- Comments (`#`), blank lines, `;` separators, and one-line compound constructs
  (`if [ -f x ]; then echo y; fi`) all parse.

### `ScriptEvaluator` (with `ShellHost` + `ShellLangError`)
- `ShellHost` protocol and `ShellLangError` implemented exactly as specified.
- `evaluate(_:variables:)` and `callFunction(named:arguments:variables:)`.
- Correct **control-flow semantics verified against real bash** (run in the build
  sandbox): `break 2` with a single loop **absorbs the excess and continues**
  (confirmed: `while …; do break 2; done; echo AFTER` prints `AFTER`), while
  `break 2` in two nested loops breaks both. Implemented via a loop-depth counter.
- `while`/`until` (exit-code truth), `break N`/`continue N`, function calls
  returning via `return`, positional params `$1…$9`, `$#`, `$@`, `$*`, and
  restoring the caller's positionals afterwards on return.
- Function invocation is automatically routed: a command whose first word names a
  function defined earlier in the script is called (binding positionals), not sent
  to the host. `undefinedFunction` is thrown for an undeclared `callFunction`.
- Before running any `ShellHost.run`, the command line is expanded: `$VAR`,
  `${…}` (delegated to `ParameterExpander`), `$((…))` (delegated to
  `ArithmeticEvaluator`), positionals, brace + tilde expansion. `$(…)` command
  substitution is left untouched for the app.

### `ArithmeticEvaluator`
Full `$((…))` language: `+ - * / % **`, unary `+ - ! ~`, prefix/postfix
`++`/`--`, comparisons `== != < <= > >=`, logical `&& || !`, bitwise `& | ^ << >> ~`,
ternary `?:`, parentheses, decimal / `0x` hex / leading-zero octal / `0b` binary /
`base#digits` literals, bare variable names (unset/non-numeric → 0), and assignment
forms `= += -= *= /= %=` with correct precedence and right-associativity.
Division/modulo by zero → `ShellLangError.arithmetic`.

### `ParameterExpander`
`${V}`, `${V:-d}`, `${V:=d}`, `${V:?msg}`, `${V:+alt}`, `${#V}`, `${V#pat}`,
`${V##pat}`, `${V%pat}`, `${V%%pat}`, `${V/a/b}`, `${V//a/b}`, `${V:offset}`,
`${V:offset:length}`. Patterns use the shared glob matcher (`*`, `?`, `[!…]`,
ranges). `:?` throws `ShellLangError.parameterUnset`. `$VAR`/`$(…)`/`$((…))` are
left untouched.

### `WordExpander`
Brace expansion `{a,b,c}`, `{1..9}`, `{a..e}`, `{1..9..2}`, nesting, multiple groups
per word, ascending/descending ranges, and non-expandable groups left literal.
Tilde expansion `~` / `~/path`; unknown `~user` returned unchanged.

### `HereDocProcessor`
`<<WORD`, `<<-WORD` (strips leading tabs from body and terminator), `<<'WORD'` /
`<<"WORD"` (no expansion). Returns `Extraction(commandLine:body:remainder:)`;
unquoted bodies get `$VAR`/`${…}`/`$((…))` expansion (leaving `$(…)` alone);
unterminated here-docs throw.

### Shared glob matcher (`ShellGlob`)
Internal helper reused by parameter expansion (shortest/longest prefix & suffix)
and by `case`.

## 2. Deliberately left out / assumptions

- **`for` loops** are explicitly delegated to the app (as the spec directs); a
  standalone `for` returns `.command` text spanning to `done`. A script whose only
  construct is `for` returns `nil` from `parse` (falls back to the app), matching
  the intent that the app already handles `for`.
- **No arrays, no `(( ))`/`let` command forms beyond evaluating expression strings,
  no `$?`/`$$`/`$!` special params** (beyond `$1..$9`, `$#`, `$@`, `$*`).
- `substituteDollars` treats escaped characters and single-quoted regions as
  literal; double-quoted content is still parameter-expanded (standard behaviour).
- Brace/tilde expansion in `.command` is applied per whitespace-separated token;
  pathological cases (braces inside quoted args) are not split out.

## 3. Test command (run on the maintainer's machine)

```bash
cd TermXShellLang && swift test
```

The suite (`Tests/TermXShellLangTests/TermXShellLangTests.swift`) uses a
`FakeShellHost` that records command lines and returns scripted exit codes. It
covers every construct, three-deep nesting, `break 2`, a function calling a
function, the whole `${V:-d}` family (all forms), 25+ arithmetic expressions
including precedence and assignment/`++`/`--`, brace + tilde expansion, all three
here-doc forms, and each `ShellLangError` case.

> Because there is no Swift toolchain in the build sandbox, the real `swift test`
> output is not reproduced here. It must be run by the maintainer (or on any
> macOS/Linux with a Swift 5.9+ toolchain). The implementation targets
> `swift-tools-version:5.9`, Foundation-only, no platforms line, one library
> product — exactly as specified.

## 3b. Review & bug fixes applied (this pass)

A deep static review (no compiler available) found and fixed these real issues:

- **Arithmetic `2#101` and `0x10` hex literals** were broken: the lexer stopped at
  `#`/`x` and read only the leading digits. `readNumber` now consumes the
  `0x`/`0o`/`0b` and `base#digits` literal in one token.
- **`${V-op}` vs `${V:-op}` semantics** were conflated. The plain form (`-`,`=`,`?`,`+`)
  now tests only *set-ness*; the colon form tests set **and** non-empty — matching
  POSIX. Added a test asserting the distinction.
- **`${V:offset}` / `${V:length}`** now parameter-expand their offset/length first
  (so `${V:$start}` works) and the arithmetic now uses the surrounding variables.
  Negative-length substrings fixed.
- **`for` loops**: `for` is no longer treated as a modelled construct, so a pure
  `for` script returns `nil` from `parse()` and the app handles it whole (rather
  than the old code truncating the loop body). Added a test.
- **Function interception** in the evaluator is now guarded to *simple* commands
  only — a command line containing `|`, `&`, `;`, `<`, `>` is never mistaken for a
  function call.
- **`ShellGlob.suffixMatchLength`** had a compile error (a ternary between two
  different `Stride` types) — fixed by materialising both orderings as `[Int]`.
- **`WordExpander`** alphabetic ranges: `UInt32(stepN)` trapped on a negative step;
  rewritten to use the step magnitude with overflow/underflow guards.

## 4. Notes for the maintainer

- The public interfaces (`ShellHost`, `ArithmeticEvaluator`, `ParameterExpander`,
  `WordExpander`, `HereDocProcessor`, `ShellNode`, `ScriptParser`,
  `ScriptEvaluator`, `ShellLangError`) are byte-for-byte as given.
- `ScriptEvaluator` keeps a function table across `evaluate` calls within the same
  instance, so a script can define then call a function in one `evaluate`; call it
  through `callFunction` for a reusable, app-defined function.
- The evaluator expands the command line before handing it to `ShellHost.run`, so
  `run` always receives an expanded line (as the protocol expects). If the app
  prefers to do its own expansion, set a flag on the host (not part of the given
  interface) — documented here, not changed here.
