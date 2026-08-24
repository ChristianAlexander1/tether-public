# Track P2 — Shell language (Swift)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS, no other teams' code.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. Use `Tether` in all new types and folders. Never use TermX or `termx`.
4. **Build only** the Swift package below.
5. **`swift test`** — all green, **50+ fixtures**.
6. **Zip:** `TetherShellLang-P2.zip`

---

# Your job: POSIX shell parser + evaluator (Swift)

## One-sentence spec
Parse shell script text into AST, evaluate with a `ShellHost` callback for running commands. No OS processes.

## Deliver
```
TetherShellLang/
├── Package.swift              # name: TetherShellLang
├── LICENSE
├── Sources/TetherShellLang/
├── Tests/TetherShellLangTests/fixtures/   # NN_name.sh + NN_name.expected
└── HANDOFF.md
```

## ShellHost protocol
```swift
public protocol ShellHost: AnyObject {
    func run(commandLine: String) -> Int32
    func write(_ text: String)
    func writeError(_ text: String)
    func value(for name: String) -> String?
    func setValue(_ value: String?, for name: String)
}
```

Tests use a **mock** ShellHost.

## Required syntax
if/elif/else, while/until, for, case/esac, functions, `$(( ))`, `${var:-default}`,
pipes, redirects on compounds, here-docs, `&&`, `||`, `. file`

## Fixtures: **50+** pairs — all must pass

Examples: if/while/for/case/function/arithmetic/${:-default}/pipe/redirect/here-doc/break.

## HANDOFF.md: fixture count + `swift test` output.

## Reference: [mksh](https://github.com/MirBSD/mksh) behavior (MirOS). License: MIT.
