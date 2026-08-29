import Foundation
import TermXFiles
import TetherJobControl
import TetherJobIPC

/// The stdio wiring a host job actually received, discovered from the real
/// descriptors rather than declared by an environment flag.
///
/// This type is the replacement for `TETHER_INTERACTIVE`. The old shim answered
/// `isTTY` for *every* fd whenever that flag was `1`, which is why a piped
/// `claude | tee log` still believed stdout was a terminal and why full-screen
/// programs rendered against a guessed 80×24. Here each fd is tested with
/// `isatty(2)` on the descriptor the job was actually given, and the geometry
/// comes from `TIOCGWINSZ` on whichever of those is a terminal.
struct NodeJobStdio {
    let stdinFD: Int32
    let stdoutFD: Int32
    let stderrFD: Int32
    /// True when job stdin is a PTY. Live bytes are pumped over TJIP/2;
    /// the slave is never dup2'd onto Node's fd 0.
    let stdinBound: Bool

    /// Which of the *child-visible* fds 0/1/2 are attached to a PTY.
    var ttyFds: [Int32] {
        var fds: [Int32] = []
        if stdinBound, stdinFD >= 0, isatty(stdinFD) != 0 { fds.append(0) }
        if stdoutFD >= 0, isatty(stdoutFD) != 0 { fds.append(1) }
        if stderrFD >= 0, isatty(stderrFD) != 0 { fds.append(2) }
        return fds
    }

    /// The descriptor to ask for window size: whichever real fd is a terminal.
    var geometrySourceFD: Int32 {
        for fd in [stdoutFD, stdinFD, stderrFD] where fd >= 0 && isatty(fd) != 0 {
            return fd
        }
        return -1
    }

    /// Map a child-visible fd (0/1/2) back to the descriptor the host holds.
    func hostFD(forChildFD fd: Int32) -> Int32? {
        switch fd {
        case 0: return stdinBound ? stdinFD : nil
        case 1: return stdoutFD >= 0 ? stdoutFD : nil
        case 2: return stderrFD >= 0 ? stderrFD : nil
        default: return nil
        }
    }
}

/// Implements the host half of TJIP/2 against this app's real services:
/// `PtyTermios` for the terminal domain and the spawn executor (via
/// `NodeJobSpawnRunner`) for the process domain.
///
/// Every call arrives on the connection's serial queue, per the package's
/// documented discipline, so no locking is needed here.
final class NodeJobHost: JIPHostDelegate {
    private let stdio: NodeJobStdio
    private let env: [String: String]
    private let runner: NodeJobSpawnRunner

    init(stdio: NodeJobStdio, env: [String: String], runner: NodeJobSpawnRunner) {
        self.stdio = stdio
        self.env = env
        self.runner = runner
    }

    // MARK: - Handshake

    func handshake() -> JIPHandshake {
        let size = PtyTermios.windowSize(fd: stdio.geometrySourceFD)
        return JIPHandshake(
            ttyFds: stdio.ttyFds,
            cols: size?.cols ?? 0,
            rows: size?.rows ?? 0,
            termName: env["TERM"] ?? "xterm-256color",
            colorTerm: Self.colorTerm(env: env, hasTTY: !stdio.ttyFds.isEmpty)
        )
    }

    /// SwiftTerm renders 24-bit colour, so a PTY-backed job is told the truth.
    /// A job with no terminal at all gets "none" — that is what makes
    /// `node -p 'process.stdout.getColorDepth()' | cat` report 1 instead of 24.
    static func colorTerm(env: [String: String], hasTTY: Bool) -> String {
        guard hasTTY else { return "none" }
        if let declared = env["COLORTERM"], !declared.isEmpty {
            return declared == "24bit" ? "truecolor" : declared
        }
        let term = env["TERM"] ?? ""
        if term == "dumb" || term.isEmpty { return "none" }
        if term.contains("256") { return "256" }
        return "16"
    }

    // MARK: - TTY domain

    func ttyGet(fd: Int32) throws -> (isTTY: Bool, isRaw: Bool, cols: Int, rows: Int) {
        guard let hostFD = stdio.hostFD(forChildFD: fd), isatty(hostFD) != 0 else {
            return (isTTY: false, isRaw: false, cols: 0, rows: 0)
        }
        let size = PtyTermios.windowSize(fd: hostFD)
        return (
            isTTY: true,
            isRaw: PtyTermios.isRawMode(fd: hostFD),
            cols: size?.cols ?? 0,
            rows: size?.rows ?? 0
        )
    }

    func ttySetRawMode(fd: Int32, mode: Bool) throws -> Bool {
        guard let hostFD = stdio.hostFD(forChildFD: fd), isatty(hostFD) != 0 else {
            throw JIPError(code: JIPErrorCode.einval, message: "fd \(fd) is not a terminal")
        }
        let previous = PtyTermios.isRawMode(fd: hostFD)
        guard PtyTermios.setRawMode(fd: hostFD, enabled: mode) else {
            throw JIPError(code: JIPErrorCode.eperm, message: "tcsetattr failed on fd \(fd)")
        }
        return previous
    }

    // MARK: - Spawn domain

    func spawnStart(argv: [String], cwd: String, env: [String: String],
                    stdio requestedStdio: [String], pty: Bool) throws -> Int32 {
        try runner.start(argv: argv, cwd: cwd, env: env, stdio: requestedStdio, pty: pty)
    }

    func spawnStdin(pid: Int32, data: Data) throws -> Int {
        try runner.writeStdin(pid: pid, data: data)
    }

    func spawnStdinEnd(pid: Int32) throws {
        try runner.endStdin(pid: pid)
    }

    func spawnKill(pid: Int32, signal: String) throws {
        try runner.kill(pid: pid, signal: signal)
    }

    func spawnResize(pid: Int32, cols: Int, rows: Int) throws {
        try runner.resize(pid: pid, cols: cols, rows: rows)
    }
}
