# TermXUI

TermXUI is the SwiftUI/iOS terminal presentation layer for TermX. It is designed for iOS 16+, Swift 5.10+, and Xcode 16+, and is independent of the command engine through the frozen `TerminalEngine` protocol.

## Features

The package provides a real POSIX PTY owner for Darwin platforms, a SwiftTerm-backed xterm/VT100 terminal view, asynchronous input and output plumbing, resize-to-`SIGWINCH` forwarding, terminal link activation, theme palettes, and an iOS keyboard accessory bar with Esc, Tab, sticky Ctrl, Option, cursor keys, and shell punctuation controls.

## Usage

Inject a `TerminalEngine` implementation from TermXCore and create a session:

```swift
let session = TerminalSession(cwd: workspacePath, engine: coreEngine)
try session.start()

TerminalSessionView(session: session)
```

The application should retain the session for the lifetime of the terminal tab and call `terminate()` when the tab closes. Workspace paths must already be resolved by TermXFiles before constructing the session.

## Development

Open `Package.swift` in Xcode, select an iOS 16+ destination, and run `TermXUITests`. SwiftTerm is fetched from its MIT-licensed upstream repository. See `HANDOFF.md` and `NOTICES/SwiftTerm-MIT.txt` for integration and attribution details.
