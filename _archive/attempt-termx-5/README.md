# TermX

TermX is a native iOS/iPadOS terminal workspace app. This repository implements the walking skeleton described in the supplied master plan: a SwiftUI app shell, persisted workspace abstraction, virtual-path safety, an in-process command engine, and a terminal-style UI.

## Requirements

The intended build environment is Xcode 16 or newer with Swift 5.10 and an iOS 16 deployment target. The sandbox cannot compile iOS frameworks because it does not include Xcode, so device and simulator validation must be completed on macOS.

## Repository layout

| Path | Purpose |
|---|---|
| `App/` | SwiftUI application target source |
| `Packages/TermXCore/` | Command engine and frozen execution interfaces |
| `Packages/TermXFiles/` | Workspace persistence and virtual path resolution |
| `Packages/TermXUI/` | Terminal session UI |
| `Packages/TermXClaude/` | Reserved package for Claude Code bridge |
| `Packages/TermXPython`, `TermXNode`, `TermXLinux` | Reserved runtime packages for later runtime integration |
| `NOTICES/` | Third-party license notices |

## Xcode setup

Create an iOS App project named `TermX`, add `App/TermXApp.swift` to the application target, and add the three Swift packages under `Packages/` as local package dependencies. Set the deployment target to iOS 16.0. The current implementation uses a deterministic Documents workspace entry point until a `UIDocumentPickerViewController` coordinator is wired into `WorkspaceStore.addWorkspace()`.

## Implemented behavior

The app opens a Documents workspace, displays a terminal-themed SwiftUI screen, accepts commands, executes registered in-process commands asynchronously, reports exit codes, and rejects invalid working directories. Workspace mappings are persisted through `UserDefaults`, and virtual paths are constrained to the registered workspace root to prevent path traversal.

## Roadmap from the supplied specification

The next integration increments are the real PTY-backed shell and native command registry, security-scoped document picker and bookmarks, SwiftTerm rendering, CPython and Node runtime xcframeworks, the Claude Code shim, and the optional Blink compatibility lane. Those pieces require upstream source builds and Xcode/macOS device validation.
