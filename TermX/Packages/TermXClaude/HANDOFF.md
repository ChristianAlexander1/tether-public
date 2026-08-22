# TermXClaude Handoff (C5)

## Implemented

| Item | Status |
|---|---|
| `ClaudeCodeService` lifecycle | ✅ install / login / run / interrupt |
| `ClaudeLauncher` (@MainActor SwiftUI UX) | ✅ first-run install + state machine |
| npm install `@anthropic-ai/claude-code` (user-owned) | ✅ `npm install -g` via `ClaudeNodeRunner` |
| OAuth / login orchestration | ✅ `claude login` PTY-backed; persists `termx.claude.authenticated` |
| PTY launch | ✅ interactive `run(..., interactive: true)` + `TERMX_INTERACTIVE=1` |
| Interrupt forwarding | ✅ `interrupt()` → node runner |
| `registry.json` (`claude` command) | ✅ `Sources/TermXClaude/Resources/registry.json` |

Claude Code package is **not** redistributed — fetched by user via npm under their Anthropic agreement (App Store 2.5.2 interpreted code).

## Depends on C4b

Wire `ClaudeCodeService(node: NodeAdapter(service: embeddedNodeService))` as in `App/IntegrationSource/TermXIntegration.swift`. Node jobs must preload `@termx/shim` (`NODE_OPTIONS=--require …`).

## Test results (2026-08-22, macOS arm64)

```
Test Suite 'ClaudeTests' passed
  testStartsUnauthenticated          PASS
  testInstallMarksInstalled          PASS
  testLoginMarksAuthenticated        PASS
  testRunRequiresAuthWhenNotLoggedIn PASS
  testInterruptForwardsToNode        PASS
  testLauncherInstallFlow            PASS

Executed 6 tests, 0 failures
```

### docs/09 §3 C5 checklist

| Acceptance test | Result |
|---|---|
| Fresh install `@anthropic-ai/claude-code` via npm | ⏳ requires device/simulator + network + NodeMobile linked |
| Login completes | ⏳ requires Anthropic account (manual) |
| File edit + `git commit` + `rg` + Esc interrupt + TUI snapshot | ⏳ blocked on C4b iOS runtime + C2 engine + user credentials |

Unit/orchestration tests pass with `TestNode` double. Full C5 e2e is an **integrator/device gate** once C4b NodeMobile is linked in the app target.

## Manual device test plan

1. Build app with `NodeMobile.xcframework` + TermXCore engine.
2. Open workspace; run `claude` (or use `ClaudeLauncher.ensureInstalled`).
3. Complete browser OAuth login.
4. In sample repo: list files, edit, `git commit`, `rg` search, Esc to interrupt.
5. Capture SwiftTerm PTY snapshot for TUI regression.

## Known limitations

- No Anthropic package bundling (by design).
- Login state stored in `UserDefaults`; production should migrate to Keychain credential helper.
- Route 2 (Linux static binary) and Route 3 (native TermX Agent) out of scope for this package.

## License

Launcher code: project. Claude Code: user-installed under Anthropic terms.
