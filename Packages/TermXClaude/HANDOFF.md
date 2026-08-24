# TermXClaude Handoff

## Architecture (current)

Modern Claude Code is a **Bun standalone ELF**. Under Blink it dies with **SIGILL**
(exit 132) — same class as the skipped bun acceptance test. Docker-style containers
cannot run on iOS (no Linux kernel to share).

**World approach we ship** (same idea as [qnx/claude-code-qnx](https://github.com/qnx/claude-code-qnx), Apache-2.0):

1. Download current `@anthropic-ai/claude-code-linux-*-*` (payload only)
2. Extract embedded JS (`ClaudeBunExtractor`)
3. Run via `node $HOME/claude/launcher.js` + `bun-shim.js` on NodeMobile

Linux/Blink stays for Alpine `apk`, git, compilers — not for Bun/Claude.

## Files

| Path | Role |
|---|---|
| `ClaudeRuntime.swift` | Probe, Bun extract, Node installer |
| `TermXClaude.swift` | Service / launcher lifecycle |
| `Resources/launcher.js` | Node entry + `/$bunfs/` stubs |
| `Resources/bun-shim.js` | `global.Bun` polyfill |
| `Resources/NOTICE-claude-bun-bridge.txt` | Apache attribution |

## Tests

```
cd Packages/TermXClaude && swift test
# 10 tests, 0 failures (host extract of 2.1.241 → `2.1.241 (Claude Code)` verified)
```
