# Track I1 — ios_system (Mac integrator only)

**You need:** Mac, Xcode, `~/Projects/tether` repo, ~2–4 hours.

## Goal
Native ARM64 `git`, `curl`, `ls`, etc. at full speed via [ios_system](https://github.com/holzschu/ios_system) BSD-3.

## Steps

1. Fork or vendor ios_system into `Vendor/ios_system/`
2. Build xcframework for iOS device + simulator (follow ios_system README)
3. Add binary target to `Packages/TermXCore/Package.swift` or `project.yml`
4. Register commands via `termx_register_command` / Swift registry
5. **Priority:** `git` (lg2 framework), `curl`, `scp`, `ssh` subset
6. Merge P12 `rg`/`fd`/`jq` static libs if available

## Wire git for Claude
Claude shim spawns `git` → must resolve to native lg2, not "command not found".

## Tests
```bash
(cd Packages/TermXCore && swift test)
# Simulator:
git --version
git init && git status
```

## Done when
- [ ] git clone/pull/commit works in picked folder
- [ ] Claude spawn trace shows git exit 0

## Open source
- [holzschu/ios_system](https://github.com/holzschu/ios_system) BSD-3
- [libgit2/libgit2](https://github.com/libgit2/libgit2) linking exception

## After I1
Proceed to [I2-blink-integration.md](I2-blink-integration.md)
