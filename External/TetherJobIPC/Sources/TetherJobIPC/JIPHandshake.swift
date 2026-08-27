import Foundation

/// Static TTY capabilities reported back to the client during the handshake.
public struct JIPHandshake: Equatable, Sendable {
    /// Which of the job's fds 0–2 are genuinely attached to a PTY.
    public var ttyFds: [Int32]
    /// Current terminal width in columns.
    public var cols: Int
    /// Current terminal height in rows.
    public var rows: Int
    /// TERM value, e.g. "xterm-256color".
    public var termName: String
    /// Color depth: "truecolor" | "256" | "16" | "none".
    public var colorTerm: String

    public init(ttyFds: [Int32], cols: Int, rows: Int, termName: String, colorTerm: String) {
        self.ttyFds = ttyFds
        self.cols = cols
        self.rows = rows
        self.termName = termName
        self.colorTerm = colorTerm
    }
}
