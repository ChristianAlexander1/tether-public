# TermXLinux Handoff (C6)

## Implemented Surface

TermXLinux delivers the Linux guest runtime described in `docs/06-linux-emulation.md` and `docs/09-integration-contracts.md` §2.1 / §3 (C6).

| Deliverable | Status | Location |
|---|---|---|
| Blink iOS build script + host static lib | ✅ Script + macOS host build | `TermX/Frameworks/build-blink.sh` |
| Blink embedding bridge (ISC) | ✅ C API | `Sources/TermXBlinkBridge/` |
| Alpine minirootfs bootstrap (CDN) | ✅ User-initiated download | `AlpineBootstrap` in `TermXLinux.swift` |
| `/workspaces` path mapping | ✅ `LinuxPathMapper` + `termx_blink_mount` | `TermXLinux.swift`, bridge |
| `termx_register_fallback` integration | ✅ `LinuxFallback.register` | `TermXLinux.swift` |
| `registry.json` | ✅ | `Sources/TermXLinux/Resources/registry.json` |
| C6 acceptance tests | ✅ See below | `Tests/TermXLinux/C6AcceptanceTests.swift` |

### Upstream

- **Blink** @ `f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580` (ISC) — https://github.com/jart/blink
- **Alpine minirootfs** `3.20.3-x86_64` from `dl-cdn.alpinelinux.org` (user-downloaded; not bundled)
- License notice: `TermX/Frameworks/NOTICES/Blink-ISC.txt`

## Architecture

```
BlinkLinuxService
  ├─ AlpineBootstrap          # CDN download + tar extract + resolv.conf
  ├─ LinuxPathMapper          # /workspaces ↔ host path resolution
  ├─ LinuxFallback            # CommandRegistry fallback + linux cmd routing
  └─ LinuxRuntimeFactory
       ├─ HostBlinkRuntime    # macOS: blink CLI subprocess (-jm -C rootfs)
       └─ EmbeddedBlinkRuntime  # iOS/in-process: termx_blink_* + blink.a
```

**Interpreter mode:** Blink runs with `-j` (no JIT) and `-m` (no linear memory) — required for iOS.

**Frozen API preserved:** `LinuxGuestRuntime`, `BlinkLinuxService.run` / `runSync`, `registryEntry`, path validation via `mapHostPath`.

## Build

### 1. Host Blink (macOS acceptance tests + bridge link)

```sh
brew install make   # GNU make 4+
cd TermX/Frameworks
./build-blink.sh
```

Outputs:
- `Frameworks/.build/blink-src/o/rel/blink/blink` — host CLI
- `Frameworks/.build/blink/host/blink.a` — static library
- `Frameworks/include/blink/` — headers
- `Frameworks/Blink.xcframework` — when Xcode iOS cross-compile succeeds

### 2. Embedded bridge (optional, for `/workspaces` VfsMount + iOS)

```sh
TERMX_LINK_BLINK=1 swift build -c release \
  --package-path TermX/Packages/TermXLinux
```

### 3. SwiftPM tests (host subprocess path — default)

```sh
cd TermX/Packages/TermXLinux
swift test
```

## Acceptance Test Results (2026-08-22, macOS arm64)

```
Test Suite 'All tests' passed
 Executed 8 tests, with 2 skipped and 0 failures

C6AcceptanceTests:
  ✅ testC6BootstrapAndBusyBoxSelfTest     — Alpine CDN bootstrap; busybox --list (>100 applets); busybox echo
  ✅ testC6ApkAddPackages                 — apk add python3 figlet gcc make; python3 print; figlet
  ✅ testC6GuestPipeline                   — ls /bin | wc -l
  ⏭ testC6WorkspacesMapping              — SKIPPED: requires TERMX_BLINK_EMBED=1 (VfsMount bind)
  ⏭ testC6BunHelloWorld                   — SKIPPED: bun musl needs libstdc++/libunwind (see Blockers)

LinuxTests:
  ✅ testInitialStateAndPathMapping
  ✅ testRegistryManifest
  ✅ testAlpineCDNURL
```

### Manual verification (host blink CLI)

```sh
BLINK=TermX/Frameworks/.build/blink-src/o/rel/blink/blink
ROOT=/tmp/alpine-rootfs   # bootstrapped via AlpineBootstrap or tar extract
$BLINK -jm -C "$ROOT" /bin/sh -c 'ls /bin | wc -l'   # → 82
$BLINK -jm -C "$ROOT" /sbin/apk add --no-cache python3 figlet gcc make
$BLINK -jm -C "$ROOT" /usr/bin/python3 -c 'print(2+2)'  # → 4
$BLINK -jm -C "$ROOT" /usr/bin/figlet test              # → ASCII art
```

## Integration

```swift
import TermXCore
import TermXLinux

let linux = BlinkLinuxService()
try await linux.bootstrap()
LinuxFallback.register(into: core.registry, service: linux)
```

`TermXIntegration.swift` already wires `core.registry.registerFallback` → `linux.runSync`.

## registry.json

```json
{ "name": "linux", "kind": "linux", "entry": "BlinkLinuxService", "framework": "TermXLinux" }
```

## Known Limitations & Blockers

1. **Blink.xcframework (T3, 2026-08-22):** ✅ Built by `Frameworks/build-blink.sh` (iOS shims for
   `clock_settime` / `fdatasync` / `sys/random.h`). SPM links `BlinkBinary` on iOS; first
   `linux` auto-bootstraps Alpine. Simulator verified: `busybox echo hi` → `hi`.

2. **Embedded bridge runtime stability:** `exit()` override + `longjmp` in `termx_blink_bridge.c`
   needs soak testing on physical device.

3. **`/workspaces` VfsMount:** Host SPM tests still skip (`TERMX_BLINK_EMBED=1`); iOS embedded
   path mounts via `termx_blink_mount`.

4. **bun hello-world (C6):** Musl bun still needs `libstdc++` in the guest — skipped in tests.

5. **DNS in guest:** Bootstrap writes `etc/resolv.conf` with public DNS — required for `apk`.

6. **No GPL guest binaries bundled** — Alpine packages are user-downloaded at runtime.
## Environment Variables

| Variable | Purpose |
|---|---|
| `TERMX_BLINK_BINARY` | Override path to host `blink` CLI |
| `TERMX_BLINK_EMBED` | `1` = prefer embedded runtime |
| `TERMX_LINK_BLINK` | `1` = link `blink.a` in SPM (Package.swift) |
| `TERMX_BLINK_XCFRAMEWORK` | Override xcframework path for iOS |

## Files Added/Modified

```
TermX/Packages/TermXLinux/
  Package.swift
  HANDOFF.md
  Sources/TermXBlinkBridge/{include/termx_blink_bridge.h, termx_blink_bridge.c, termx_blink_stub.c}
  Sources/TermXLinux/{TermXLinux.swift, LinuxRuntime.swift, Resources/registry.json}
  Tests/TermXLinux/{LinuxTests.swift, C6AcceptanceTests.swift}
TermX/Frameworks/
  build-blink.sh
  NOTICES/Blink-ISC.txt
```
