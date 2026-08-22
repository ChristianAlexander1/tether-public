# Tether Full-Build Audit

The repository now contains the full planned component graph and a native SwiftUI app shell. The Swift package layer is implemented for C1 through C6, with frozen interfaces preserved across the components. However, the master plan’s phrase “full build” also requires native runtime binaries, a real Xcode application target, and device validation. Those release-critical artifacts cannot be produced or tested in this Linux environment.

| Area | Repository status | Release status |
|---|---|---|
| C1 TermXUI | SwiftTerm bridge, PTY owner, input/output routing, resize signaling, themes, keyboard accessory, tests | Needs Xcode/Simulator validation; fonts and full ANSI palette remain polish items |
| C2 TermXCore | Lexer, registry, job table, built-in dispatch, fallback contract | Command breadth and PTY-backed command execution require the native command engine implementation |
| C3 TermXFiles | Bookmark persistence, folder picker, security-scoped access counting, safe path resolution | Requires manual device verification for iCloud eviction and relaunch persistence |
| C4a TermXPython | Runtime protocol, registry metadata, interrupt contract | CPython iOS xcframework must be linked under `Frameworks/` |
| C4b TermXNode | Node service protocol, serialized queue, shim source, registry metadata | nodejs-mobile xcframework and complete native child-process binding must be linked |
| C5 TermXClaude | Install/login/run orchestration and authentication state | Real Claude Code npm install, login, TUI, and API credential flow require Node runtime and user credentials |
| C6 TermXLinux | Guest state, bootstrap directory, path mapping, registry metadata | Blink xcframework, Alpine rootfs verification, and guest package execution must be integrated |
| App shell | SwiftUI workspace selection and terminal presentation source | A generated `.xcodeproj`, signed frameworks, entitlements, and macOS build are still required |
| Integration | Root `Package.swift`, composition registry, notices, metadata, and docs | End-to-end simulator/device and TestFlight validation remain pending |

The implementation is therefore **source-complete at the architecture and package-contract level, but not release-complete**. It would be misleading to claim a shippable TermX binary until the external native frameworks are linked and the acceptance suite passes on Xcode, Simulator, and a physical iPhone/iPad.
