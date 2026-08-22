# TermX

TermX is a native iOS/iPadOS terminal architecture organized into independent Swift packages. The repository now contains the UI, command-engine, workspace, Python, Node, Claude, Linux-compatibility, and composition layers described by the supplied plan.

## Repository map

| Area | Location | Responsibility |
|---|---|---|
| App shell | `App/` | SwiftUI scene, workspace selection, session presentation |
| Terminal UI | `Packages/TermXUI` | SwiftTerm bridge, PTY, themes, keyboard accessory |
| Core | `Packages/TermXCore` | Lexer, command registry, jobs, fallback dispatch |
| Files | `Packages/TermXFiles` | Security-scoped bookmark storage and path resolution |
| Python | `Packages/TermXPython` | CPython service contract and registry metadata |
| Node | `Packages/TermXNode` | Node service contract and child-process shim source |
| Claude | `Packages/TermXClaude` | Install, login, and authenticated Claude Code launch flow |
| Linux | `Packages/TermXLinux` | Blink/Alpine guest contract, bootstrap state, path mapping |
| Integration | `App/IntegrationSource` | Runtime graph and fallback wiring |

## Build requirements

Open the repository on macOS with Xcode 16 or later. Add the local packages to an iOS application target with an iOS 16 deployment target, add the C/C++ xcframeworks for CPython, nodejs-mobile, Blink, and the command engine under `Frameworks/`, and configure the application target to include `App/TermXApp.swift`. The root `Package.swift` validates package composition and integration-source compilation independently of the Xcode application target.

The runtime packages intentionally do not download executable native code. The application must ship signed native frameworks in `Frameworks/`; interpreted scripts and user-requested guest packages remain in the sandbox. Claude Code’s npm package is installed by the user under their own agreement and is not redistributed.

## Current status

The package graph and integration contracts are implemented. The external native runtime binaries, Alpine rootfs, Xcode project metadata, physical-device tests, and real Anthropic login flow require macOS/device credentials and must be supplied during the release build. See `docs/COMPLETENESS.md` for the exact boundary.
