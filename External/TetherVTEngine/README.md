# TetherVTEngine
A Foundation-only incremental VT stream tokenizer, TUI mode tracker, query responder, and output pipeline for Swift 5.9.

The library deliberately does not render a terminal or answer grid-dependent queries. Feed PTY output to `VTOutputPipeline.feed`; send `forward` to the renderer and `replies` back to the PTY.
