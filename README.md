# Tether

Tether is an iPhone and iPad developer terminal built around a real Alpine
Linux userland. A selected iOS folder is mounted at `/work`; commands installed
with `apk` remain guest ELF programs executed by Blink. Embedded CPython,
Node, and wasm3 provide iOS-safe runtime lanes where direct guest execution is
not viable.

The platform is generic by construction:

- guest execution is the default; installed package names are never added to
  a Swift allow-list;
- desktop opener commands share one URL/file-opening service;
- host runtime dispatch is data-driven by
  `tether_dispatch_manifest.json`;
- Node child processes share one command protocol instead of consumer-specific
  command branches;
- no fabricated `uname`, Git identity, editor, hostname, CPU, memory, or
  `process.platform` values are installed.

## Build and verify

```sh
./scripts/validate.sh --quick
./scripts/validate.sh --ios
```

Use `--network` for real Alpine download/package-install acceptance, or `--all`
for every automated gate. See [HOW-TO-RUN.md](HOW-TO-RUN.md) for simulator and
device commands.

The native frameworks are available under `Frameworks/` in this workspace.
They are generated artifacts and are intentionally ignored by Git; their
reproducible build scripts and notices live beside them.

## Repository map

| Path | Purpose |
|---|---|
| `App/` | SwiftUI app, runtime integration, UI tests |
| `Packages/TermXUI` | SwiftTerm renderer, PTY transport, keyboard and diagnostics |
| `Packages/TermXCore` | Host command engine and real-fd shell bridge |
| `Packages/TermXFiles` | Workspaces, bookmarks, browser/file presentation |
| `Packages/TermXPython` | Embedded CPython |
| `Packages/TermXNode` | Embedded Node and generic child-process protocol |
| `Packages/TermXClaude` | Claude Code installation/runtime adapter |
| `Packages/TermXLinux` | Alpine bootstrap, Blink execution, mounts and manifest dispatch |
| `External/` | Standalone command, shell, terminal, WASM and JS protocol packages |
| `Vendor/` | Clean-room filesystem/offload libraries, Linux harness, native-tool builds, RISC-V study |
| `Frameworks/` | Reproducible native framework builds and local artifacts |
| `docs/` | Architecture, validation, release and user documentation |

The shipped name is Tether. Some established Swift/C module and ABI names still
use the earlier `TermX` prefix; compatibility names are read only where removing
them would break existing installations or build automation.

Start with [the architecture](docs/ARCHITECTURE.md), [current evidence](STATUS-AND-REWORK.md),
and [the user guide](docs/USER-GUIDE.md).
