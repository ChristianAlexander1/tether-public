#if canImport(UIKit)
import Foundation
import SwiftTerm
import UIKit

/// Batches PTY output into ~60fps frames before feeding SwiftTerm.
final class TerminalOutputPump {
    private let lock = NSLock()
    private var pending = Data()
    private weak var terminalView: TerminalView?
    private var displayLink: CADisplayLink?
    private var maxFrameBytes = 256 * 1024
    var frameInterval: CFTimeInterval = 1.0 / 60.0
    private(set) var lastFrameDuration: CFTimeInterval = 0
    private(set) var framesRendered = 0

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
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
        pending.append(data)
        lock.unlock()
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
