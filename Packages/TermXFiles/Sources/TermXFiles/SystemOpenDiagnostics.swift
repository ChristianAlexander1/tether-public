import Foundation

/// Ring buffer of browser/open events — included in the Copy log button output.
public final class SystemOpenDiagnostics: @unchecked Sendable {
    public static let shared = SystemOpenDiagnostics()

    private let lock = NSLock()
    private var lines: [String] = []
    private let cap = 100

    private init() {}

    public func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)"
        lines.append(line)
        if lines.count > cap {
            lines.removeFirst(lines.count - cap)
        }
        Self.persistLine(line)
    }

    /// Survives app termination — read from Documents/.tether-browser-open.log.
    private static func persistLine(_ line: String) {
        #if os(iOS)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = docs?.appendingPathComponent(".tether-browser-open.log") else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url)
        }
        #endif
    }

    public func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        if lines.isEmpty {
            return "(no browser/open events recorded yet — try xdg-open https://example.com)"
        }
        return lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}
