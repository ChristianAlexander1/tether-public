# Track I3 — Final integration (Mac only — NOT for sub-agents)

**For you / Cursor on Mac with repo.** Sub-agents never see this file.

## Must pass before ship

### Automated (no Simulator)
- [ ] All Steps in MERGE-AND-VERIFY.md through 4d
- [ ] P10 replay tests against merged P3 shim
- [ ] P7 harness ≥30 offline PASS (if P7 delivered)

### Browser / OAuth
- [ ] Copy log: `node spawn open https://claude.com/...`
- [ ] In-app Safari opens (not "Browser didn't open?" only)
- [ ] Login completes with paste code

### Ctrl+C — three layers
- [ ] Alpine: `sleep 30` + ^C stops (Linux, not app hack)
- [ ] Claude: 1st ^C message, 2nd ^C → prompt, **no crash**
- [ ] P3: cancel test exit 130

### Claude + git + packages
- [ ] `claude` TUI readable (P9)
- [ ] edit file in `/work`
- [ ] `git commit` works
- [ ] `rg` works (P12 or `apk add ripgrep`)
- [ ] `apk add` arbitrary package smoke test

### Crash regression
- [ ] Full **Step 8b** apk chain (git → python3 → ripgrep → build-base) — no crash
- [ ] `claude` works **after** full apk chain (R2)
- [ ] `claude` → double ^C → open `claude` again (no deaf terminal)
- [ ] resize terminal during Claude (no kill)
- [ ] `xdg-open http://127.0.0.1:9999` → info sheet, no crash (while shell idle)

### Replace hardcoded bridge list (required with P5)
- [ ] `path_is_host_backed()` strcmp list **removed**
- [ ] P5 manifest loaded; default = guest ELF
- [ ] `apk add git` → git runs as **guest**, not host proxy
- [ ] `xdg-open https://example.com` works (any URL, not vendor-specific)

### Linux-faithful (not hack-only)
- [ ] URL opener is **generic class** (manifest list)
- [ ] Host runtimes only via **manifest** rows
- [ ] Alpine ^C stops `sleep` without app-specific signal code
- [ ] `apk add` tools need **no** new Swift/C code per tool

See [ROBUSTNESS.md](ROBUSTNESS.md).

### Device
- [ ] docs/DEVICE-PASS.md

## Final script — all commands succeed

```sh
apk update && apk add git ripgrep
git --version && node --version && claude --version
claude login
claude
# create hello.txt, git commit, rg hello
# double Ctrl-C to exit
sleep 30
# Ctrl-C once — must stop
```

Sign off in STATUS-AND-REWORK.md only when **every** box above is checked.
