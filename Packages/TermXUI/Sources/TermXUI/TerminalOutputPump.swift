#if canImport(UIKit)
import Foundation
import SwiftTerm
import TetherVTEngine
import UIKit

/// Batches PTY output into ~60fps frames before feeding SwiftTerm.
///
/// Every byte first passes through `VTOutputPipeline`, which answers the
/// terminal queries SwiftTerm does not (colour scheme, XTGETTCAP, DECRQM) and
/// tracks the TUI modes a program has turned on. That tracking is what makes
/// `restoreAfterAbnormalExit()` possible: when a full-screen program dies
/// without cleaning up, we can synthesize the exact sequence it owed us.
final class TerminalOutputPump {
    private let lock = NSLock()
    private var pending = Data()
    private weak var terminalView: TerminalView?
    private let pipeline: VTOutputPipeline
    private let sendReply: (Data) -> Void
    private var displayLink: CADisplayLink?
    private var maxFrameBytes = 256 * 1024
    var frameInterval: CFTimeInterval = 1.0 / 60.0
    private(set) var lastFrameDuration: CFTimeInterval = 0
    private(set) var framesRendered = 0

    init(terminalView: TerminalView, isDark: Bool, sendReply: @escaping (Data) -> Void) {
        self.terminalView = terminalView
        self.sendReply = sendReply
        var identity = TerminalIdentity.xterm256Color
        identity.colorSchemeIsDark = isDark
        pipeline = VTOutputPipeline(identity: identity, policy: .conservativeDefault)
        pipeline.onUnsolicitedReply = sendReply
    }

    func updateColorScheme(isDark: Bool) {
        lock.lock()
        pipeline.identity.colorSchemeIsDark = isDark
        lock.unlock()
    }

    /// True while a program has left the terminal in a non-default mode
    /// (alternate screen, hidden cursor, mouse reporting, …).
    var terminalNeedsRestore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pipeline.trackerState.isClean
    }

    /// The sequence a program *should* have emitted before it died, so the
    /// terminal comes back usable. Empty when the terminal is already clean,
    /// which makes it safe to ask after a normal exit too.
    ///
    /// The caller feeds these bytes back through the session's normal output
    /// path rather than straight into the render queue. That costs one extra
    /// pass through the pipeline and buys two things: the restore lands in the
    /// transcript (so a scrollback snapshot taken later is not stuck inside a
    /// dead alternate screen), and the tracker observes the resets itself
    /// instead of relying on a separate bookkeeping reset.
    func pendingRestoreSequence() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return pipeline.restoreSequence()
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        flush()
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let result = pipeline.feed(data)
        pending.append(result.forward)
        lock.unlock()
        // Replies go out unlocked so a re-entrant writer cannot deadlock us.
        if !result.replies.isEmpty { sendReply(result.replies) }
        resumeDisplayLink()
    }

    private func resumeDisplayLink() {
        displayLink?.isPaused = false
    }

    func flush() {
        let chunk = drainPending(limit: Int.max)
        guard !chunk.isEmpty, let view = terminalView else { return }
        view.feed(byteArray: ArraySlice(chunk))
    }

    @objc private func tick() {
        let start = CFAbsoluteTimeGetCurrent()
        let chunk = drainPending(limit: maxFrameBytes)
        guard !chunk.isEmpty, let view = terminalView else {
            displayLink?.isPaused = true
            return
        }
        view.feed(byteArray: ArraySlice(chunk))
        framesRendered += 1
        lastFrameDuration = CFAbsoluteTimeGetCurrent() - start
    }

    private func drainPending(limit: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return Data() }
        if pending.count <= limit {
            let all = pending
            pending = Data()
            return all
        }
        let prefix = pending.prefix(limit)
        pending.removeFirst(prefix.count)
        return Data(prefix)
    }
}
#endif
