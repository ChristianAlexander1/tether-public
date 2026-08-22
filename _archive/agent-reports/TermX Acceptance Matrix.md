# TermX Acceptance Matrix

This document maps the supplied integration contract to the current repository. A check is marked **source-complete** only when the repository contains the implementation and a test or deterministic review path. A check is marked **platform-required** when it needs Xcode, an iOS SDK, native xcframework builds, a physical device, or user credentials.

| Contract area | Repository implementation | Validation |
|---|---|---|
| Workspace model and virtual paths | `TermXFiles` | Unit test covers nested paths and traversal rejection |
| Folder picker | `DocumentWorkspaceProvider` | Platform-required: run on iOS and verify Files-provider access |
| Shell tokenization and built-ins | `TermXCore` | Unit tests plus simulator test suite required |
| Pipes and output redirection | `TermXCore.execute` | Simulator test required for filesystem and stream behavior |
| PTY shell and terminal rendering | Integration point only | Platform-required; requires SwiftTerm and a native PTY implementation |
| Python runtime | `PythonService` contract | Platform-required; requires CPython iOS framework |
| Node runtime | `NodeService` contract | Platform-required; requires embedded Node runtime |
| Claude launcher | `ClaudeLauncher` | Unit test covers install/run state machine; real flow requires Node and Anthropic login |
| Linux-compatible environment | `LinuxService` contract | Platform-required; requires Blink and user-provided rootfs |
| App Store compliance | Info.plist and privacy manifest | Platform-required: archive, sign, inspect, and submit review metadata |

## macOS validation commands

Open `TermX.xcodeproj` in Xcode 16 or newer. Add the local Swift packages under `Packages/` to the app target, select an iOS 16+ simulator, and run the package tests. Then run the device checklist: select a Files-provider folder, relaunch and restore it, open and edit a file, run the shell smoke suite, install Python and Node runtime assets, authenticate Claude Code with the user’s own account, interrupt a running task, and inspect memory and file-descriptor behavior during a 30-minute session.

The Linux environment used to prepare this repository has no Xcode, Swift compiler, iOS SDK, simulator, Apple signing identity, or device connection. Those checks cannot honestly be marked green here.
