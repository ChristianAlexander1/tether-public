# Agent briefs — for YOU (not for sub-agents)

## What to paste into each online agent

**Yes — one file per agent, P1 through P12.**

| Agent chat | Paste this file only | They return |
|------------|----------------------|-------------|
| Agent 1 | `P1-commands.md` | `TetherCommands-P1.zip` |
| Agent 2 | `P2-shell.md` | `TetherShellLang-P2.zip` |
| Agent 3 | `P3-node-shim.md` | `tether-shim-P3.zip` |
| … | … | … |
| Agent 12 | `P12-native-tools.md` | `TetherNativeTools-P12.zip` |

**Do NOT give sub-agents:**
- This README
- `MERGE-AND-VERIFY.md`
- `I1` / `I2` / `I3` (Mac integrator — for you or Cursor on Mac)
- The Tether repo or app description
- Other P-track files

Each agent works **from scratch** on **one component** with **no project context**.

**Naming:** new code is **Tether** (`TetherCommands`, `@tether/shim`, `tether_*`). Never TermX. Existing app packages may still say TermX until Mac merge.

---

## Your workflow

1. Open **one** file (e.g. `P3-node-shim.md`)
2. Copy **the entire file** into a **new** chat
3. Wait for zip + `HANDOFF.md` with **all tests green**
4. Repeat for other agents (parallel is fine)
5. When zips are back → **`MERGE-AND-VERIFY.md`** on your Mac

---

## Full track list

| File | Component | Zip name |
|------|-----------|----------|
| [P1-commands.md](P1-commands.md) | Unix commands (Swift) | `TetherCommands-P1.zip` |
| [P2-shell.md](P2-shell.md) | Shell parser (Swift) | `TetherShellLang-P2.zip` |
| [P3-node-shim.md](P3-node-shim.md) | Node child_process shim (JS) | `tether-shim-P3.zip` |
| [P4-fakefs.md](P4-fakefs.md) | fakefs (C) | `TetherFakefs-P4.zip` |
| [P5-native-offload.md](P5-native-offload.md) | Native offload registry (C) | `TetherNativeOffload-P5.zip` |
| [P6-wasm.md](P6-wasm.md) | WASM runner | `TetherWasm-P6.zip` |
| [P7-linux-harness.md](P7-linux-harness.md) | Linux/Blink tests | `tether-linux-harness-P7.zip` |
| [P8-libriscv.md](P8-libriscv.md) | riscv spike | `TetherRiscv-P8.zip` |
| [P9-terminal.md](P9-terminal.md) | VT100 parser (Swift) | `TetherTerminal-P9.zip` |
| [P10-claude-fixtures.md](P10-claude-fixtures.md) | Generic spawn protocol tests (JS) | `tether-spawn-fixtures-P10.zip` |
| [P11-docs.md](P11-docs.md) | Docs only | `tether-docs-P11.zip` |
| [P12-native-tools.md](P12-native-tools.md) | rg/fd/jq scripts | `TetherNativeTools-P12.zip` |

**Mac integrator (you):** [I1-ios-system.md](I1-ios-system.md) · [I2-blink-integration.md](I2-blink-integration.md) · [I3-final-integration.md](I3-final-integration.md) · [MERGE-AND-VERIFY.md](MERGE-AND-VERIFY.md) · [ROBUSTNESS.md](ROBUSTNESS.md)

---

## Suggested order (all can run in parallel)

```
Start together:  P3, P10, P9  (login + TUI)
                 P7            (Linux signals / Ctrl+C in guest)
                 P1, P2        (commands + shell)
Later:           P4, P5, P6, P8, P12, P11
Mac when ready:  I1 → I2 → MERGE-AND-VERIFY → I3
```

---

## What sub-agents do NOT cover (Mac integrator fixes in repo)

These stay in the existing Tether app — **not** rebuilt by P1–P12:

| Issue | Who fixes on merge |
|-------|-------------------|
| In-app Safari for OAuth URL | Mac integrator (`SystemOpen` — already in repo) |
| `DISPLAY` / `BROWSER` for Claude login spawn | Mac integrator (Claude launcher in repo) |
| Double Ctrl-C exiting Claude without crash | Already in repo — **must not regress** (I3 retest) |
| Pure Alpine Ctrl+C / signals | Proven by **P7** harness + Blink (real Linux behavior) |

P3/P10 ensure **`open` / `xdg-open` spawn correctly** (Linux-faithful, not UI-only hacks). P7 ensures **Linux guest** handles pipelines, fork, SIGINT, and **apk install chains**. After merge, run **Step 8b** in MERGE-AND-VERIFY — see [ROBUSTNESS.md](ROBUSTNESS.md).
