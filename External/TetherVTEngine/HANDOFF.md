# Handoff

Entry point is `VTOutputPipeline(identity:policy:)`. Call `feed(Data)` synchronously; write `forward` to SwiftTerm and `replies` to the PTY. Inspect `trackerState` and call `restoreSequence()` during teardown. Lower-level users can use `VTStreamTokenizer`, `TUIStateTracker`, and `VTQueryResponder` independently.

Sequences are capped at 64 KiB. An overlong OSC/DCS/escape is flushed as raw text (including its introducer and all bytes), preserving losslessness while avoiding unbounded allocation. The public frozen token enum cannot retain terminator metadata, so normal OSC/DCS serialization uses ST.

```swift
let pipe = VTOutputPipeline(identity: .xterm256Color, policy: .conservativeDefault)
func onPTYBytes(_ bytes: Data) {
    let result = pipe.feed(bytes)
    renderer.write(result.forward)
    pty.write(result.replies)
}
func tearDown() { pty.write(pipe.restoreSequence()) }
```
