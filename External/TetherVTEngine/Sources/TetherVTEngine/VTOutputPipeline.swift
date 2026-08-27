import Foundation

public final class VTOutputPipeline {
    private let responder: VTQueryResponder
    private let tracker = TUIStateTracker()
    private let trackerTokenizer = VTStreamTokenizer()

    public init(identity: TerminalIdentity, policy: ResponsePolicy) {
        responder = VTQueryResponder(identity: identity, policy: policy)
    }

    /// Theme flips assign through to the responder, which emits a colour-scheme
    /// report via `onUnsolicitedReply` when a program has 2031 reporting on.
    public var identity: TerminalIdentity {
        get { responder.identity }
        set { responder.identity = newValue }
    }

    /// Replies produced outside a `feed` call (currently colour-scheme change
    /// reports). The integrator writes these back to the PTY.
    public var onUnsolicitedReply: ((Data) -> Void)? {
        get { responder.onUnsolicitedReply }
        set { responder.onUnsolicitedReply = newValue }
    }

    public func feed(_ bytes: Data) -> (forward: Data, replies: Data) {
        let x = responder.process(bytes)
        for q in trackerTokenizer.feed(x.forward) { tracker.observe(q) }
        return x
    }

    public var trackerState: TUIModeState { tracker.state }

    public func restoreSequence() -> Data { tracker.restoreSequence() }

    /// Drop accumulated TUI mode state. Called after a restore sequence has
    /// been synthesized so the next job starts from a clean terminal.
    public func resetTracker() { tracker.reset() }
}
