# TermXLinux

TermXLinux is Tether's real Alpine-on-Blink execution lane. The app starts an
Alpine login shell by default, mounts the selected workspace at `/work`, and
executes downloaded guest ELFs through Blink rather than substituting host
implementations.

## Runtime layout

- `BlinkLinuxService` owns rootfs bootstrap, lifecycle and command execution.
- `LinuxPathMapper` confines `/workspaces` and `/work` mappings and rejects traversal and
  symlink escape.
- `EmbeddedBlinkRuntime` uses the real C bridge on iOS (Blink.xcframework) and on macOS when `TETHER_LINK_BLINK=1` links `Frameworks/.build/host/blink.a`. The iOS xcframework has no macOS slice; that flag is independent of the xcframework's presence. `termx_blink_run` restores host stdio after each one-shot guest so caller pipes can reach EOF.
- `HostBlinkRuntime` runs the built Blink CLI for macOS acceptance testing when the embedded bridge is not linked. It cannot VfsMount `/work` or `/workspaces`.
- `LinuxRootfsLayout` distinguishes an extracted Alpine tree (production `apk` path) from a fakefs store. Hostfs must not be pointed at `tetherfs.idx`.
- `tether_dispatch_manifest.json` is the only guest/host policy list. Its
  default is `guest_elf`; only platform runtimes and desktop opener capabilities
  listed there are dispatched to app services.
- Launcher entries are relative BusyBox symlinks, not copied or fabricated
  utility implementations. Existing user-installed commands are preserved.

## Upstream and rootfs

- Blink revision: `f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580` (ISC).
- Alpine minirootfs: the version and SHA-256 in `TermXLinux.swift`, downloaded
  from Alpine's CDN and verified before extraction.
- The writable extracted rootfs is used for `apk`; immutable TetherFakefs is not
  mounted in place of it.
- Notices live under `Frameworks/NOTICES`.

Build host Blink with:

```sh
./Frameworks/build-blink.sh
```

Run offline tests with:

```sh
swift test --package-path Packages/TermXLinux
```

Run real bootstrap/package tests with:

```sh
./scripts/validate.sh --network
```

The iOS linkage and full app graph are verified by:

```sh
./scripts/validate.sh --ios
```

## Development overrides

| Preferred variable | Legacy compatibility | Purpose |
|---|---|---|
| `TETHER_BLINK_BINARY` | `TERMX_BLINK_BINARY` | host Blink executable |
| `TETHER_BLINK_EMBED` | `TERMX_BLINK_EMBED` | prefer embedded bridge on macOS |
| `TETHER_LINK_BLINK` | `TERMX_LINK_BLINK` | link the built host static library in SwiftPM |
| `TETHER_BLINK_XCFRAMEWORK` | `TERMX_BLINK_XCFRAMEWORK` | override Blink xcframework location |

These are development overrides. Production iOS uses the packaged
`Blink.xcframework`; missing production linkage is an error, not an emulated
success path. Architectural constraints and device gates are maintained in
`docs/ENGINEERING-TARGETS.md` and `docs/DEVICE-PASS.md`.
