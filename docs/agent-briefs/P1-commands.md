# Track P1 — Unix commands (Swift)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS, no other teams' code.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. Use `Tether` in all new types, folders, and zips. Never use TermX or `termx` in new code.
4. **Build only** the Swift package below.
5. **`swift test`** — all green. Paste output in HANDOFF.md.
6. **Zip:** `TetherCommands-P1.zip`

---

# Your job: in-process Unix commands (Swift package)

## One-sentence spec
Each command is a pure function: `(argv, stdin, cwd, env) → (stdout, stderr, exitCode)`. **No** `fork`, **no** `Process`, **no** OS spawn.

## Deliver
```
TetherCommands/
├── Package.swift              # name: TetherCommands
├── LICENSE
├── Sources/TetherCommands/
│   ├── CommandIO.swift
│   ├── Registry.swift
│   └── one file per command
├── Tests/TetherCommandsTests/
└── HANDOFF.md
```

## Interface (exact)

```swift
public struct CommandIO {
    public let argv: [String]
    public let stdin: String
    public let cwd: String
    public let environment: [String: String]
}

public struct CommandResult: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32   // 0 ok, 1 error, 2 usage
}

public protocol TetherCommand {
    static var name: String { get }
    static func run(_ io: CommandIO) -> CommandResult
}

public enum TetherCommandRegistry {
    public static let all: [String: TetherCommand.Type]
}
```

## Implement **40+** commands
`xargs`, `tee`, `cut`, `tr`, `uniq`, `sort`, `which`, `type`, `test`, `env`, `printenv`,
`id`, `whoami`, `uname`, `date`, `split`, `paste`, `join`, `od`, `strings`, `file`, `stat`,
`readlink`, `realpath`, `basename`, `dirname`, `mktemp`, `ln`, `du`, `sleep`, `timeout`,
`yes`, `seq`, `expr`, `printf`, `echo`, `true`, `false`.

Behavior reference: man pages, [uutils/coreutils](https://github.com/uutils/coreutils) MIT.

## Tests — minimum **80** (≥2 per command + integration)

| ID | Test | Expected |
|----|------|----------|
| T1 | cut -d: -f1 | `a\n` from `a:b` |
| T2 | tr a-z A-Z | `HI` |
| T3 | test -f missing | exit 1 |
| T4 | sort -r | reversed lines |
| T5 | basename /a/b/c | `c\n` |

Use real temp dirs (`FileManager`).

## HANDOFF.md: full `swift test` output + command table.

## License: MIT
