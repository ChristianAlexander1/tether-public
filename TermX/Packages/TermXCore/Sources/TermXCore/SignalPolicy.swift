import Foundation

/// Process-wide signal policy for the in-process command engine.
///
/// Every TermX command runs inside the app process rather than as a child process, so a
/// signal that would normally kill just one command (SIGPIPE when the reader of a pipe
/// goes away — `ls | head` is enough to trigger it) would take the whole app down.
/// Ignoring it turns those writes into `EPIPE` returns, which the write loops handle.
public enum SignalPolicy {
    private static var installed = false
    private static let lock = NSLock()

    public static func installOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        signal(SIGPIPE, SIG_IGN)
    }
}
