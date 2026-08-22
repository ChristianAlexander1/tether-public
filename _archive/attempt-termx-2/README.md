# TermX

TermX is a SwiftUI iOS/iPadOS developer terminal organized around user-selected workspaces. The repository implements the application shell, command engine, workspace provider, terminal UI, runtime service contracts, Claude launcher, Linux-lane capability surface, tests, and licensing records described in the supplied specifications.

## Repository layout

| Path | Purpose |
|---|---|
| `App/` | SwiftUI application entry point, workspace navigation, importer, settings, and terminal screen |
| `Packages/TermXCore` | Shell parser, command registry, built-ins, job/process contract, environment defaults, tests, C header |
| `Packages/TermXFiles` | Workspace model, persistence, security-scoped access, virtual-path resolution |
| `Packages/TermXUI` | Dark terminal UI with history, command execution, output rendering, and tabs-ready session model |
| `Packages/TermXPython` | Python runtime service contract and launcher |
| `Packages/TermXNode` | Node service contract and launcher |
| `Packages/TermXClaude` | Claude Code launcher through the Node service |
| `Packages/TermXLinux` | Linux compatibility-lane state and bootstrap contract |
| `NOTICES/` | Dependency notices and licensing policy |
| `docs/` | Supplied master plan, shell specification, licensing policy, and integration contracts |

## Build in Xcode

Create an iOS App project named `TermX`, set the deployment target to iOS 16.0, and add `App/TermXApp.swift` to the application target. Add the local Swift packages under `Packages/` using **File → Add Package Dependencies → Add Local**, then link `TermXCore`, `TermXFiles`, and `TermXUI` to the app target. Add the runtime packages when their embedded runtime frameworks are available. The source intentionally reports unavailable capabilities rather than silently pretending that a missing native framework is installed.

The full native runtime lanes require the corresponding signed xcframework artifacts to be added under `Frameworks/`: CPython iOS, nodejs-mobile, SwiftTerm or an equivalent terminal renderer, wasm3/WASI, and Blink plus a vetted rootfs. These are binary integration inputs, not code placeholders; the service APIs and app wiring are already defined so they can be attached without changing the frozen contracts.

## Current behavior

The app opens with a workspace sidebar. The folder importer persists workspace metadata, maintains security-scoped access counts, resolves `/workspaces/<name>/...` paths safely, and launches a dark terminal. The shell supports quoting, semicolon-separated commands, environment defaults, built-ins including `echo`, `pwd`, `cd`, `ls`, `cat`, `mkdir`, `touch`, `rm`, `env`, `clear`, `help`, and output redirection with `>`. The runtime services expose asynchronous launch and interruption contracts, while iOS-safe builds return a clear unavailable status until the corresponding embedded runtime is attached.

## Validation

The sandbox used to prepare this repository does not contain Xcode or a Swift compiler, so simulator compilation cannot be performed here. Run `swift test` for `Packages/TermXCore` and the workspace tests on macOS/Xcode 16, then run the device acceptance suite from `docs/09-integration-contracts.md`. The project has no GPL dependency bundled in the source tree.

## License posture

TermX application code is proprietary unless otherwise stated. Third-party components must remain within the permissive license policy in `docs/07-appstore-licensing.md`; every newly attached dependency must add its complete notice to `NOTICES/` before distribution.
