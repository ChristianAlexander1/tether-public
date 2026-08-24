# Track I2 — Blink + mounts + fakefs (Mac integrator only)

**You need:** Mac, Xcode, Blink.xcframework built, P4/P5/P7 zips (optional but recommended).

## Goal
ios-linuxkit-class filesystem: all workspaces mounted, fakefs optional, native offload registry.

## Steps

### 1. Multi-workspace mounts
For each bookmark in `WorkspaceManager`:
```c
termx_blink_mount(hostPath, "/workspaces/<sanitized-name>");
```
Keep `/work` → active workspace (existing).

Files: `Packages/TermXLinux/`, `App/IntegrationSource/TermXIntegration.swift`

### 2. Guest write round-trip
Run from `TermXFiles/HANDOFF.md`:
```sh
echo hello > /work/test.txt
cat /work/test.txt
```
Must appear on host disk.

### 3. Merge P5 dispatch manifest (required)
Replace hardcoded `path_is_host_backed()` in `termx_blink_bridge.c` with P5 registry.

**Verify:**
- `apk add git` → `/usr/bin/git` is **guest ELF** (dispatch = GUEST_ELF)
- `xdg-open https://example.com` → URL opener class (any https URL)
- Only manifest `host_runtimes` rows use host_exec (node/npm/claude stubs)

### 4. Merge P4 fakefs (when ready)
Optional rootfs path: fakefs image instead of plain tar extract in `AlpineBootstrap`.

### 5. P7 harness
Run on Mac/Linux CI; fix syscall gaps listed in SYSCALL-GAP-LOG.md.

### 6. Single-session safety
Keep `termx_blink_is_busy()` — no second `blink_run` during login shell. Document in LIMITATIONS until queue exists.

## Tests
```bash
(cd Packages/TermXLinux && swift test)
# Simulator: apk add git; ls /work; ls /workspaces/other
```

## Done when
- [ ] Every bookmark visible under `/workspaces/name`
- [ ] Guest writes persist on host
- [ ] P7 fixtures ≥90% pass

## After I2
Proceed to [I3-final-integration.md](I3-final-integration.md)
