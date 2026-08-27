import Foundation

/// The host side of the protocol. The package itself never owns a socket, PTY,
/// termios, or a process — the integrator implements this protocol in terms of real
/// services. See HANDOFF.md for how each method maps onto termios/process APIs.
///
/// Methods signal failure by throwing a `JIPError` (which becomes
/// `{"ok":false,"code":…,"message":…}` in a `res`) or any other `Error` (which is
/// converted to `EINVAL`).
public protocol JIPHostDelegate: AnyObject {
    /// Provide the static handshake data (TTY fds + geometry + term strings).
    func handshake() -> JIPHandshake

    /// Query TTY state for `fd`. Throws `EPERM` for an fd that is not a TTY the host
    /// exposes, or `EINVAL` if the fd is not a TTY at all.
    func ttyGet(fd: Int32) throws -> (isTTY: Bool, isRaw: Bool, cols: Int, rows: Int)

    /// Set/clear raw mode on `fd`. Returns the previous raw state. Throws `EINVAL`
    /// if `fd` is not a TTY, `EPERM` if not permitted.
    func ttySetRawMode(fd: Int32, mode: Bool) throws -> Bool

    /// Spawn a child process. `argv[0]` is the command. `cwd` may be empty. `env`
    /// is a flat `NAME=VALUE` map. `stdio` entries are "pipe" | "inherit" | "ignore".
    /// `pty` selects a pseudo-terminal for the child's stdio. Returns the child pid.
    ///
    /// Throws `ENOENT` if `argv[0]` cannot be resolved, `EACCES`/`EPERM` on permission
    /// failures, `EAGAIN` if the pid table is exhausted.
    func spawnStart(argv: [String], cwd: String, env: [String: String],
                    stdio: [String], pty: Bool) throws -> Int32

    /// Feed bytes to the child's stdin. Returns the remaining server-side stdin
    /// capacity (bytes) — this is echoed as the `window` field of the `res`.
    func spawnStdin(pid: Int32, data: Data) throws -> Int

    /// Signal EOF on the child's stdin.
    func spawnStdinEnd(pid: Int32) throws

    /// Deliver a signal to the child. Throws `ESRCH` if the pid has exited.
    func spawnKill(pid: Int32, signal: String) throws

    /// Resize a pty-backed child. Throws `EINVAL` unless the child was spawned with
    /// `pty:true`.
    func spawnResize(pid: Int32, cols: Int, rows: Int) throws
}
