# Tether integration status

Last verified integration pass: **2026-08-27** (lifecycle and runtime stabilization).

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
| P3 Node shim | `External/tether-shim-v2`; synchronized product implementation in TermXNode |
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

## Rework-plan integration (docs/rework-plan/)

All seven agent deliverables are in `External/` and integrated per
`90-INTEGRATION-GLUE.md`. Each ships its own `HANDOFF.md` and standalone suite,
which `./scripts/validate.sh --quick` now runs.

| Step | Component | State |
|---|---|---|
| 1 | `TetherVTEngine` | **Default.** Replaced `TerminalProtocolAdapter` in the output path; adapter tests ported as a byte-level oracle and the adapter deleted. Adds crash restore: a program that dies mid-TUI gets its reset sequence synthesized. |
| 2 | `TetherJobIPC` + `tether-shim-v2` | **Default.** TJIP/2 is the only lane: live stdin (`tty.stdin`), per-fd `isTTY`, real PTY geometry, colour depth 24. v1 (`NodeSocketServer`, `NodeSpawnBridge`, v1 shim) is deleted. |
| 3 | `TetherJobControl` | **Default.** `JobTable` issues job ids and routes signals; `VirtualChildPID` and the no-op `signal()` are gone from the v2 lane. |
| 4 | `TetherSessionCore` | **Default.** One state machine per session drives bootstrap, suspend/resume, rootfs removal, and ordered teardown; scrollback snapshots persist across a force-quit. |
| 5 | `TetherStorageCore` | **Default.** Storage deletes go through `StorageCatalog` with live-session leases; `LinuxPathMapper` delegates confinement to `ConfinedPathResolver`. |
| 6 | `tether-bun-compat` | **Default.** `bun-shim.js` is a thin layer over the library; its hardcoded opener list is gone and `Bun.which` performs a real PATH scan. |

Program-name policy now lives in exactly one file. `SystemOpen.openerCommands`
and the Claude launcher's opener are both configured from
`tether_dispatch_manifest.json` at startup instead of keeping their own copies.

### Simulator evidence for the TJIP/2 lane (2026-08-25, iPhone 17 Pro)

Captured from the PTY mirror with `TETHER_IPC_V2=1`:

- `node -e '…[process.stdin.isTTY, process.stdout.isTTY, process.stderr.isTTY]'`
  → `[true,true,true]`, derived from the handshake rather than an env flag.
- `process.stdout.columns/rows` → **48×34**, the real PTY geometry (the old lane
  defaulted to 80×24 and smashed a narrow phone terminal).
- `process.stdout.getColorDepth()` → **24** (was hardcoded to 8).
- Piped stdout (`… | cat`) → `[true,null]`: stdin still interactive, stdout
  correctly not a TTY. This is the `claude | tee log` case.
- A job that entered the alternate screen, hid the cursor and enabled mouse
  reporting, then exited non-zero without cleaning up, produced exactly
  `ESC[?1000l ESC[?2004l ESC[?1049l ESC[0m ESC[?25h` and returned a clean prompt.

One defect was found during this pass and is **fixed**: guest shell pipelines
segfaulted the forked child on exit because the embedded `exit()` interposition
longjmp'd from the child into the parent's jmp_buf. Fork children now `_exit`,
and exec in a fork child copies `isfork` onto the new machine.

## Verified evidence from this pass

- Simulator arm64 build, install and launch succeeded on iPhone 17 Pro.
- Startup now has one lifecycle owner. The app no longer starts a shell and
  then separately asks the state machine to bootstrap and start another one;
  only real operation completions produce lifecycle success events.
- Rootfs leases now cover bootstrap as well as the live shell, and bootstrap
  failures release both the lease and workspace scope before a retry.
- Node's persistent bootstrap no longer calls a removed debug logger at job
  completion. A simulator smoke run completed a Linux pipeline, printed `42`
  from Node, executed the following shell command, and returned to the prompt.
- Claude's extracted Bun graph no longer sends Markdown/text prompt assets to
  Node's JavaScript compiler. Its loader hook is also reinstalled after each
  persistent Node job restores `Module._load`, preventing one failed launch
  from poisoning later commands. The regression runs two launcher jobs in one
  process; the installed simulator app printed Claude `2.1.247` twice, ran the
  following marker, and returned to a usable prompt.
- Claude authentication now uses the supported `claude auth login` command.
  TJIP/2 publishes its native-loader link so the launcher can synchronize the
  active `child_process` shim into ESM built-ins, and its `ChildProcess`
  implements the standard chainable `ref()`/`unref()` contract. A rebuilt-app
  smoke test reached Claude's real authorization page in Tether's in-app Safari
  view; no credentials were entered and account-backed completion remains a
  physical-device release gate.
- Saved scrollback replay is distinct from live TUI mode repair, buffers until
  the renderer attaches, and is not duplicated into the next snapshot.
- Simulator command proofs: real `uname`, redirected Node output `42`, WASI
  output `hello`, and generic `xdg-open https://example.com` without killing the shell.
- Real Blink/Alpine acceptance installed Python, figlet, GCC, make and Git.
- TetherFakefs: 7/7 CTest cases pass on macOS, including overlay copy-up, whiteout, readdir, rename, and corruption detection.
- TetherNativeOffload: strict C11/Werror tests pass.
- Node OS APIs now report native data; fabricated platform/CPU/memory/user data
  and the forced `process.platform` override were removed.
- Forced Git identity/editor, fake uname/hostname scripts, hostname environment,
  startup process killing, and Claude-only browser fallbacks were removed.
- Developer debug residue was removed: agent logging blocks with hardcoded
  `/Users/...` paths in `TerminalOutputPump`, `NodeSpawnBridge` and
  `bootstrap.js`, including HTTP POSTs of runtime data to a localhost ingest
  endpoint. `validate.sh` now fails if any of it returns.
- `TetherJobControl` arrived red (its test file did not compile, and 11 cases
  failed once it did). Four miswired test setups and two source defects were
  fixed; it is 31/31 green.
- The VT engine emitted `CSI <mode> l` to disable mouse reporting. Those are DEC
  *private* modes and need `CSI ? <mode> l`, so a crashed TUI kept spraying
  mouse escapes at the shell. Fixed, with the restore order asserted on device.

Run `./scripts/validate.sh --quick` for the current aggregate counts rather than
copying a test total into documentation that will immediately become stale.

## Release gates not represented by a unit test

- Complete the physical-device checklist on every supported iOS version.
- Complete a real account-backed Claude login and edit/commit workflow.
- Review App Store signing, privacy, framework notices and export declarations.

Open engineering targets and their concrete build plans are kept in
[docs/ENGINEERING-TARGETS.md](docs/ENGINEERING-TARGETS.md); they are not
implemented as per-program exceptions.
