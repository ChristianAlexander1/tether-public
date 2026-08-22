# Tether Full Build Scope

The supplied archive contains the master plan, C1 terminal UI specification, App Store licensing policy, and frozen integration contracts. The master plan references six additional component specifications that were not included: C2 shell core, C3 filesystem, C4 runtimes, C5 Claude integration, C6 Linux emulation, and C8 roadmap.

This build reconstructs the missing components from the frozen signatures and acceptance tests in `09-integration-contracts.md`. It provides a native Swift package for each component, shared contract types, an iOS SwiftUI application shell, resource manifests, licensing notices, and integration-test scaffolding. Native runtime binaries, the Blink/Alpine rootfs, Claude Code’s proprietary npm package, and Xcode-generated project metadata remain external build inputs and are intentionally not redistributed.
