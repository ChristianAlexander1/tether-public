# C10 — Remaining Work (Mac integrator)

*For offline/online agents without Mac or repo access, use **`13-parallel-agent-plan.md`**
instead — self-contained P1–P12 tracks.*

**Platform contract:** [`GUEST-PLATFORM.md`](GUEST-PLATFORM.md) — read before merging any track.

## Mac integrator tracks (repo required)

| ID | Task | Doc |
|---|---|---|
| **I1** | ios_system xcframework + lg2 git + register 50+ commands | `02-shell-core.md`, P12 |
| **I2** | Blink mounts, fakefs VFS, **P5 manifest dispatch** (remove strcmp list) | `06-linux-emulation.md`, P4, P5 |
| **I3** | Merge P1–P12; platform smoke (8b apk chain); device pass; ship | `HOW-TO-RUN.md`, `DEVICE-PASS.md` |

## Simulator-verified baseline (2026-08-22+)

Shell, Python, Node 24, npm, Claude `--version`, Alpine/Blink login shell, manifest-listed
host stubs (node/claude/open), copy log format 3. See `STATUS-AND-REWORK.md`.

## Open integrator items (platform-first)

| Priority | Item | Why |
|----------|------|-----|
| **P0** | ~~Wire P5 manifest; delete `path_is_host_backed()`~~ | **Done in-repo** |
| **P0** | ~~Guest login env (DISPLAY, BROWSER, …)~~ | **Done** — `etc/profile.d/tether-env.sh` |
| **P0** | SpawnExecuting → guest one-shot for ELFs in guest PATH | JS CLIs spawn arbitrary tools |
| **P1** | URL opener primary path (spawn → Safari); PTY scrape backup only | OAuth is one URL shape |
| **P1** | `/workspaces/<name>` bind for every bookmark | Multi-root projects |
| **P1** | SwiftTerm DEC 2031 + column width (merge P9) | Any TUI (Claude, vim, …) |
| **P2** | Syscall gaps from P7 harness | Fix Blink, not host lists |
| **P2** | Physical iPhone/iPad checklist | Ship |

## Verification

```bash
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  (cd Packages/$p && swift test); done
xcodebuild -scheme Tether -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation test
```

Post-merge: Step 8b in `agent-briefs/MERGE-AND-VERIFY.md` (`apk` chain + `xdg-open` + node/claude in **one session**).

## Rules (unchanged — safety, not scope limits)

See `PROJECT-CONTEXT.md` hard-won rules and `09-integration-contracts.md` frozen APIs.
