import Foundation
import TetherJobIPC

/// A scriptable, in-memory `JIPHostDelegate` used by the test target.
///
/// It exposes canned results and optional per-method override closures so tests can
/// drive every code path: successful tty/spawn ops, `JIPError` throws, `EINVAL`
/// conversions, window values, and so on. Every invocation is recorded in `calls` so
/// tests can assert on which delegate methods were reached (or not reached).
public final class FakeHostDelegate: JIPHostDelegate {

    // MARK: Recording

    /// Human-readable log of the delegate calls made so far.
    public var calls: [String] = []
    public func resetCalls() { calls.removeAll() }

    private func record(_ name: String, _ args: [String: String] = [:]) {
        let joined = args.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        calls.append(joined.isEmpty ? name : "\(name)(\(joined))")
    }

    // MARK: Handshake

    public var handshakeValue = JIPHandshake(
        ttyFds: [0, 1, 2], cols: 80, rows: 24,
        termName: "xterm-256color", colorTerm: "truecolor"
    )

    public func handshake() -> JIPHandshake {
        record("handshake")
        return handshakeValue
    }

    // MARK: tty

    public typealias TtyWindow = (isTTY: Bool, isRaw: Bool, cols: Int, rows: Int)
    public var ttyGetResult: TtyWindow = (isTTY: true, isRaw: false, cols: 80, rows: 24)
    public var ttyGetThrows: JIPError?
    /// Full override (return value or throw) for `ttyGet`.
    public var ttyGetOverride: ((Int32) throws -> TtyWindow)?

    public var ttySetRawModeResult = false
    public var ttySetRawModeThrows: JIPError?
    /// Full override for `ttySetRawMode`.
    public var ttySetRawModeOverride: ((Int32, Bool) throws -> Bool)?

    public func ttyGet(fd: Int32) throws -> TtyWindow {
        record("ttyGet", ["fd": "\(fd)"])
        if let override = ttyGetOverride { return try override(fd) }
        if let e = ttyGetThrows { throw e }
        return ttyGetResult
    }

    public func ttySetRawMode(fd: Int32, mode: Bool) throws -> Bool {
        record("ttySetRawMode", ["fd": "\(fd)", "mode": "\(mode)"])
        if let override = ttySetRawModeOverride { return try override(fd, mode) }
        if let e = ttySetRawModeThrows { throw e }
        return ttySetRawModeResult
    }

    // MARK: spawn

    public var spawnStartPid: Int32 = 42
    public var spawnStartThrows: JIPError?
    /// Full override for `spawnStart`.
    public var spawnStartOverride: (([String], String, [String: String], [String], Bool) throws -> Int32)?

    public var spawnStdinWindow = 65_536
    public var spawnStdinThrows: JIPError?
    /// Full override for `spawnStdin` (return value or throw).
    public var spawnStdinOverride: ((Int32, Data) throws -> Int)?

    public var spawnStdinEndThrows: JIPError?
    public var spawnKillThrows: JIPError?
    public var spawnResizeThrows: JIPError?

    public func spawnStart(argv: [String], cwd: String, env: [String: String],
                           stdio: [String], pty: Bool) throws -> Int32 {
        record("spawnStart",
               ["argv": argv.joined(separator: " "), "cwd": cwd,
                "env": env.count.description, "stdio": stdio.joined(separator: "|"),
                "pty": "\(pty)"])
        if let override = spawnStartOverride { return try override(argv, cwd, env, stdio, pty) }
        if let e = spawnStartThrows { throw e }
        return spawnStartPid
    }

    public func spawnStdin(pid: Int32, data: Data) throws -> Int {
        record("spawnStdin", ["pid": "\(pid)", "bytes": "\(data.count)"])
        if let override = spawnStdinOverride { return try override(pid, data) }
        if let e = spawnStdinThrows { throw e }
        return spawnStdinWindow
    }

    public func spawnStdinEnd(pid: Int32) throws {
        record("spawnStdinEnd", ["pid": "\(pid)"])
        if let e = spawnStdinEndThrows { throw e }
    }

    public func spawnKill(pid: Int32, signal: String) throws {
        record("spawnKill", ["pid": "\(pid)", "signal": signal])
        if let e = spawnKillThrows { throw e }
    }

    public func spawnResize(pid: Int32, cols: Int, rows: Int) throws {
        record("spawnResize", ["pid": "\(pid)", "cols": "\(cols)", "rows": "\(rows)"])
        if let e = spawnResizeThrows { throw e }
    }
}
