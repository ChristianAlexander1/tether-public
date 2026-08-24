# Merge and verify — after all agent zips arrive

**Who:** Mac with Xcode + this repo (`~/Projects/tether`).

**When:** Every P-track zip is received and each agent's `HANDOFF.md` shows tests passing.

---

## Frozen agent deliverables (P1–P10)

**Do not re-run or rewrite agent briefs** — those tracks are already in flight or done.
Integrator work is **adapt and wire**, not ask agents to redo work:

| Agent zip | If naming differs | Mac action |
|-----------|-------------------|------------|
| `TetherNativeOffload-P5.zip` | `tether_dispatch.h` vs `termx_blink_dispatch_*` | Merge logic into `TermXBlinkBridge` **or** keep in-repo manifest (already wired) |
| `claude-fixtures-P10.zip` | vs `tether-spawn-fixtures-P10.zip` | Same tests — unzip to `External/tether-spawn-fixtures/` |
| P3 `@tether/shim` | old `termx-shim` folder name | rsync into `Packages/TermXNode/.../shim/` |

**In-repo baseline (already on Mac):** `Packages/TermXLinux/Resources/tether_dispatch_manifest.json`
+ `GuestDispatchManifest.swift` + `termx_blink_dispatch_*` in the bridge. P5 zip is optional
enhancement if it adds JSON loader tests — not required to ship manifest dispatch.

See `GUEST-PLATFORM.md` for the platform contract agents did not need to know about.

---

## Step 0 — Collect zips

**Naming:** agent zips use **Tether** (`TetherCommands`, `@tether/shim`). Existing app modules may still be `Packages/TermX*` until the Mac rename pass. Unzip new code under `External/` / `Vendor/` with Tether names, then wire into current packages.

| Expected zip | Unzip to |
|--------------|----------|
| `TetherCommands-P1.zip` | `External/TetherCommands/` |
| `TetherShellLang-P2.zip` | `External/TetherShellLang/` |
| `tether-shim-P3.zip` | `External/tether-shim/` then sync into Node package Resources/shim/ |
| `TetherFakefs-P4.zip` | `Vendor/TetherFakefs/` |
| `TetherNativeOffload-P5.zip` | `Vendor/TetherNativeOffload/` |
| `TetherWasm-P6.zip` | `External/TetherWasm/` |
| `tether-linux-harness-P7.zip` | `Vendor/tether-linux-harness/` |
| `TetherRiscv-P8.zip` | `Vendor/TetherRiscv/` (report only until engine chosen) |
| `TetherTerminal-P9.zip` | `External/TetherTerminal/` |
| `claude-fixtures-P10.zip` or `tether-spawn-fixtures-P10.zip` | `External/tether-spawn-fixtures/` |
| `tether-docs-P11.zip` | `docs/` (merge ARCHITECTURE, LIMITATIONS, etc.) |
| `TetherNativeTools-P12.zip` | `Vendor/TetherNativeTools/` |

Missing zip? Continue others — but note gap in `docs/LIMITATIONS.md`.

---

## Step 1 — Host tests (no Simulator yet)

Run from repo root:

```bash
cd ~/Projects/tether

# Swift external packages
for p in TetherCommands TetherShellLang TetherTerminal; do
  echo "=== External/$p ==="
  (cd External/$p && swift test) || exit 1
done

# Node packages
(cd External/tether-shim && npm test) || exit 1
(cd External/tether-spawn-fixtures && npm test) || (cd External/claude-fixtures && npm test) || exit 1

# Existing packages
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  echo "=== Packages/$p ==="
  (cd Packages/$p && swift test) || exit 1
done
```

**Fix compile errors** before Simulator — see `External/INTEGRATION-NOTES.md` for past patterns.

---

## Step 2 — Wire P1 commands

1. Open `Packages/TermXCore/Sources/TermXCore/ExternalCommands.swift`
2. Register every new command from `TetherCommandRegistry.all`
3. Skip name collisions with `CoreCommands` (keep one `base64`, etc.)
4. Re-run `Packages/TermXCore` tests

**Verify:** `swift test` in TermXCore passes.

---

## Step 3 — Wire P2 shell

Already partially wired via `ShellLangIntegration`. After P2 zip:

1. Diff `External/TetherShellLang` vs previous
2. Ensure `ShellSession.eval` still tries `ScriptParser` first
3. Run `External/TetherShellLang` fixture count — must match HANDOFF (50+)

---

## Step 4 — Wire P3 shim

```bash
rsync -a External/tether-shim/ Packages/TermXNode/Sources/TermXNode/Resources/shim/
# Keep TermX-specific files if rsync overwrote:
#   bootstrap.js, ensure-ipc.mjs — merge manually from git if needed
```

**Critical:** `lib/ipc.js` request/reply keys must match `NodeSpawnBridge.swift`:

- Request: `kind`, `file`, `args`, `cwd`, `env`, `interactive`
- Reply: `ok`, `exitCode`, `stdout`, `stderr`, `pid`

Run P10 fixtures against merged shim.

---

## Step 4b — Wire P5 dispatch (replace hardcoded tool list)

**Required.** Hardcoded strcmp list is **removed** in-repo; dispatch is manifest-driven.

1. Confirm `Packages/TermXLinux/Resources/tether_dispatch_manifest.json` is in app bundle
2. **Default dispatch = guest ELF** — `apk add git/python/gcc` never host-proxied
3. `browser_openers` → `SystemOpen` for **any** https URL
4. `host_runtimes` only → host_exec (node/npm/claude **stubs**)
5. Guest login env: `/etc/profile.d/tether-env.sh` (DISPLAY, WAYLAND_DISPLAY, BROWSER)

**Optional:** merge `TetherNativeOffload-P5.zip` tests if agent delivered extra JSON loader coverage.

**Pass:**
- `apk add git && git status` runs as **guest ELF**
- `xdg-open https://example.com` opens Safari (not claude.com-only)
- `claude login` uses same URL opener class

---

## Step 4c — Ctrl+C / cancel (do not regress)

| Layer | What | Test |
|-------|------|------|
| **Linux guest** | SIGINT in Alpine shell | P7 fixtures 11–12 pass; in app: `sleep 60` + Ctrl-C stops |
| **Claude (Node)** | 1st ^C warning, 2nd ^C exit 130 | Double Ctrl-C → `tether:/work$` **no crash** |
| **P3 shim** | `{"kind":"cancel"}` → exit 130 | `npm test` in tether-shim |

**Do NOT** call `linux.interrupt()` from UI on Claude ^C (crashes app — already fixed).

---

## Step 4d — Regression gate (must pass before Simulator)

```bash
# ALL must exit 0 — fix before continuing
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  (cd Packages/$p && swift test) || exit 1
done
(cd External/tether-shim && npm test) || exit 1
(cd External/tether-spawn-fixtures && npm test) || (cd External/claude-fixtures && npm test) || exit 1
# Optional: Vendor/tether-linux-harness/run-all.sh
```

If any test fails after merge, **fix before Simulator** — avoids iteration loops.

---

## Step 5 — Wire P9 terminal

1. Add `External/TetherTerminal` as local package dep of TermXUI (or copy parser into TermXUI)
2. Feed PTY bytes through `EscapeSequenceParser` before/alongside SwiftTerm
3. Handle DECSET 2031 (ignore safely)

---

## Step 6 — Mac tracks I1, I2, I3

Follow dedicated briefs:

- [I1-ios-system.md](I1-ios-system.md)
- [I2-blink-integration.md](I2-blink-integration.md)
- [I3-final-integration.md](I3-final-integration.md)

---

## Step 7 — Build app

```bash
cd ~/Projects/tether
xcodegen generate
xcodebuild -project Tether.xcodeproj -scheme Tether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation build
```

Install + launch per `HOW-TO-RUN.md`.

---

## Step 8 — Final smoke test (Simulator)

Type in app terminal (Alpine session at `/work`):

| # | Command / action | Pass |
|---|------------------|------|
| 1 | `uname -a` | shows Linux |
| 2 | `apk add git ripgrep` | completes |
| 3 | `git --version` | version string |
| 4 | `node --version` | v24.x |
| 5 | `claude --version` | 2.x |
| 6 | `claude login` | Safari opens; paste code; success |
| 7 | `claude` | TUI readable (not smashed) |
| 8 | Ask Claude to create `hello.txt` | file appears at `/work` |
| 9 | `git init && git add . && git commit -m test` | commit succeeds |
| 10 | `rg hello` | finds match |
| 11 | Double Ctrl-C in Claude | `tether:/work$`, **app alive** |
| 12 | Ctrl-C during `sleep 30` in Alpine | sleep stops, prompt returns |
| 13 | Copy log | `node spawn open` before OAuth URL line |
| 14 | `npm test` + `swift test` all packages | all green |

Check all boxes before calling the integration done.

---

## Step 8b — Robustness chain (required — catches install cascades)

Run **in one app session** without force-quit. App must stay alive after **every** step.

```sh
apk update
apk add git && git --version
apk add python3 && python3 --version
apk add ripgrep && rg --version
apk add build-base && gcc --version
xdg-open https://example.com    # generic URL opener — any https
node --version                  # manifest host_runtime only
claude --version
claude login
# Safari + paste code
claude
# double Ctrl-C exit
claude
# must start again — terminal not deaf
```

| # | Pass |
|---|------|
| R1 | Full apk chain completes (no crash mid-install) |
| R2 | Manifest host runtimes (node/claude stubs) still work after apk chain |
| R3 | URL opener works after apk chain (`xdg-open` or login) |
| R4 | Claude → exit → Claude again (no deaf PTY) |
| R5 | `sleep 30` + ^C in Alpine (guest signal, not app hack) |

See [ROBUSTNESS.md](ROBUSTNESS.md) for why each rule exists.

---

## Step 9 — Physical device

Run `docs/DEVICE-PASS.md` checklist on real iPhone.

---

## If something fails

| Symptom | Check |
|---------|-------|
| Claude "Browser didn't open?" | P3 DISPLAY/BROWSER env; P10 fixtures; SystemOpen log |
| Smashed TUI | P9 wired into TermXUI? |
| git not found | `apk add git` — must be **guest ELF**, not host list; fix syscalls if guest git fails |
| npm install fails | P3 shim; Node 24 full xcframework |
| App crash on ^C | NodeMobile cancel path (existing fix) |
| App crash after `apk add` | Run Step 8b chain; check Blink logs; never second `blink_run` from UI |
| App crash after `apk add X` then `apk add Y` | Step 8b — guest only, one session |
| Claude works only via terminal URL fallback | Step 4b — primary `open` spawn must fire |
| Installing tools breaks Claude/node | host_exec must stay registered after apk; R2 in Step 8b |

Log failures in `docs/LIMITATIONS.md` with owner track.

---

## Sign-off

When Steps 1–9 pass, update:

- `STATUS-AND-REWORK.md`
- `docs/LIMITATIONS.md` (shrink open gaps)
- `PROJECT-CONTEXT.md` current state date
