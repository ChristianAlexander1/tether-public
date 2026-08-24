# Tether integration status

Last verified integration pass: **2026-08-24**.

## Working product path

- Alpine login shell under Blink is the default terminal.
- The selected iOS workspace is confined and mounted at `/work`.
- Real `apk add` installs and executes Alpine packages; package names are not
  host-proxied.
- Embedded CPython and Node execute through packaged frameworks.
- Arbitrary wasm32-wasi modules execute through the integrated wasm3 service.
- `open`, `xdg-open`, `gio open`, and related desktop openers use one generic
  in-app browser/file service.
- Host runtime selection is loaded from a JSON manifest; guest ELF is the
  default decision.

## P1–P12 integration

| Track | Repository role |
|---|---|
| P1 commands | `External/TetherCommands`; registered by TermXCore |
| P2 shell | `External/TetherShellLang`; standalone suite + TermXCore conformance gate |
| P3 Node shim | `External/tether-shim`; synchronized product implementation in TermXNode |
| P4 fakefs | `Vendor/TetherFakefs`; real pack/read/CRC suite, retained for a writable-overlay design |
| P5 offload | `Vendor/TetherNativeOffload`; C registry verified beside production manifest dispatch |
| P6 WASM | `External/TetherWasm`; wired into app command dispatch |
| P7 Linux harness | `Vendor/tether-linux-harness`; 42 real Linux fixtures |
| P8 RISC-V | `Vendor/TetherRiscv`; evidence-based alternate-engine study, not selected runtime |
| P9 terminal | `External/TetherTerminal`; standalone suite + cross-parser UI conformance gate |
| P10 spawn fixtures | `External/tether-spawn-fixtures`; generic protocol replay tests |
| P11 docs | merged into canonical files under `docs/` |
| P12 native tools | `Vendor/TetherNativeTools`; real upstream iOS build scripts only |

The transfer-time root folders and old 48-test `termx-shim` copy are gone. P2
does not replace the production real-fd shell with its deliberately in-memory
filesystem, and P9 does not double-parse bytes ahead of SwiftTerm; both are used
as conformance oracles without changing runtime semantics.

## Verified evidence from this pass

- Simulator arm64 build, install and launch succeeded on iPhone 17 Pro.
- Simulator command proofs: real `uname`, redirected Node output `42`, WASI
  output `hello`, and generic `xdg-open https://example.com` without killing the shell.
- Real Blink/Alpine acceptance installed Python, figlet, GCC, make and Git.
- TetherFakefs: 6/6 CTest cases pass on macOS, including corruption detection.
- TetherNativeOffload: strict C11/Werror tests pass.
- Node OS APIs now report native data; fabricated platform/CPU/memory/user data
  and the forced `process.platform` override were removed.
- Forced Git identity/editor, fake uname/hostname scripts, hostname environment,
  startup process killing, and Claude-only browser fallbacks were removed.

Run `./scripts/validate.sh --quick` for the current aggregate counts rather than
copying a test total into documentation that will immediately become stale.

## Release gates not represented by a unit test

- Complete the physical-device checklist on every supported iOS version.
- Complete a real account-backed Claude login and edit/commit workflow.
- Review App Store signing, privacy, framework notices and export declarations.

Known architectural boundaries and their concrete remedies are kept in
[docs/LIMITATIONS.md](docs/LIMITATIONS.md); they are not implemented as
per-program exceptions.
