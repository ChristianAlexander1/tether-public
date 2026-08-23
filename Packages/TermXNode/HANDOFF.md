# TermXNode Handoff (C4b)

## Implemented

| Item | Status |
|---|---|
| Frozen `NodeService` protocol | ✅ unchanged |
| `EmbeddedNodeService` serialized job queue | ✅ `DispatchQueue` single-flight |
| `interrupt()` → SIGINT to running job | ✅ host runtime; iOS forwards to NodeMobile thread |
| stdio/tty bridge | ✅ fd redirect + `TERMX_INTERACTIVE` → shim `tty.isatty` |
| `@termx/shim` preload package | ✅ Delivered shim from `External/termx-shim` + `ensure-ipc.mjs` |
| Spawn IPC → TermXCore | ✅ `RegistrySpawnExecutor` + `NodeSpawnBridge` (Unix socket on host, fd IPC on iOS) |
| `registry.json` (`node`, `npm`) | ✅ `Sources/TermXNode/Resources/registry.json` |
| `NodeMobile.xcframework` | ✅ `Vendor/NodeMobile.xcframework` + `NodeMobileBridge` (`termx_node_launch`) |

## Build scripts

```bash
# Fetch official nodejs-mobile iOS xcframework (MIT, ~49MB download)
./TermX/Frameworks/build-nodejs-mobile.sh

# Run acceptance tests (macOS host Node + shim; records termx_spawn via test double)
cd TermX/Packages/TermXNode && swift test
```

Outputs:
- `TermX/Frameworks/NodeMobile.xcframework` (ios-arm64 + ios-arm64_x86_64-simulator)
- `TermX/Frameworks/include/node` (headers)

Upstream: **nodejs-mobile v18.20.4** — https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4

## Test results (2026-08-22, macOS arm64, after T1/T8)

```
Test Suite 'NodeTests' passed — 9 tests, 0 failures
  testNodeEvalPrintsTwo                              PASS
  testShimRoutesPostinstallThroughSpawnRecorder      PASS
  testInterruptReturnsNonZero                        PASS
  (+ registry/shim metadata/os/tty/queue tests)      PASS
```

External `termx-shim`: **48 pass** (`cd TermX/External/termx-shim && npm test`)

### docs/09 §3 C4b checklist

| Acceptance test | Result |
|---|---|
| `node -e 'console.log(1+1)'` | ✅ PASS |
| `npm init -y && npm i chalk lodash express` + require | ⏳ manual (needs network + `$HOME/node` layout on device) |
| Shim proof: postinstall shell script → `termx_spawn` recorder | ✅ PASS (`testShimRoutesPostinstallThroughSpawnRecorder`) |
| SIGINT interrupts spin loop | ✅ PASS |

## Architecture notes

- **Host (macOS tests / dev):** `HostNodeRuntime` spawns system Node with `--import ensure-ipc.mjs --require @termx/shim`; IPC via Unix domain socket (`TERMX_IPC_SOCKET`).
- **iOS production:** `NodeMobileRuntime` calls `termx_node_launch()` once on an 8 MiB-stack thread with `bootstrap.js` + shim preload. Jobs posted on `TERMX_JOB_FD`; spawn IPC uses `TERMX_IPC_SOCKET` per job.
- **`@termx/shim` location:** bundled at `Bundle.module/shim/` → `index.js`, loaded via `NODE_OPTIONS`.

## Known limitations / integrator follow-ups

1. **npm e2e on iOS Simulator/device** not run here — requires `xcodebuild` app run + network. Host tests prove shim + spawn routing; embedded engine wiring is in `NodeMobileRuntime`.
2. **Native Node addon / node-gyp** unsupported (v1 scope).
3. **NodeMobile SPM slice:** iOS-only binary target; macOS `swift test` uses `HostNodeRuntime` fallback.
4. **Socket path length:** IPC socket uses `/tmp/termx-<uuid>.sock` (macOS `sun_path` limit).

## License

nodejs-mobile / Node.js — MIT. See `TermX/NOTICES/nodejs-mobile-MIT.txt`.
