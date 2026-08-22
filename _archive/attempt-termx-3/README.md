# TermX

TermX is a source-level iOS/iPadOS terminal architecture based on the attached master plan. This repository implements the frozen Swift contracts, workspace path model, terminal engine interface, runtime service boundaries, Claude Code launcher, Linux service boundary, and a portable POSIX C execution core.

## Build status

The provided environment is Ubuntu and does not include Xcode or an Apple SDK, so an iOS archive cannot be compiled here. The repository is organized for Xcode 16+/Swift 5.10+ integration; the remaining device-specific work is linking SwiftTerm, CPython, nodejs-mobile, and Blink xcframeworks and completing the iOS picker delegate.

## Layout

The package layout follows `09-integration-contracts.md`. Each component has a `HANDOFF.md`, a SwiftPM manifest, and source code. The TermXCore C API is designed for a POSIX test harness and uses real file descriptors.

## Next steps on macOS

Open the root in Xcode, add the packages under `Packages/`, link the generated device/simulator xcframeworks under `Frameworks/`, add the third-party notices, and wire `UIDocumentPickerViewController` through the app coordinator.
