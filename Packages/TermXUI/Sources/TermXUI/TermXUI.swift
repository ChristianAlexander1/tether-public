import Foundation
import SwiftUI
import Combine
import TermXFiles
#if canImport(Darwin)
import Darwin
#endif

/// The engine boundary used by the UI package. The production implementation is supplied by TermXCore.
public protocol TerminalEngine: AnyObject {
    func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32
    func signal(pid: Int32, _ sig: Int32)
}

public enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case midnight
    case solarized
    case dracula
    case paper

    public var id: String { rawValue }

    var isDark: Bool { self != .paper }

    public var palette: TerminalPalette {
        switch self {
        case .midnight:
            return TerminalPalette(background: Color(red: 0.055, green: 0.063, blue: 0.086), foreground: Color(red: 0.88, green: 0.90, blue: 0.95), cursor: .white, selection: Color.white.opacity(0.20), accent: Color(red: 0.36, green: 0.72, blue: 1.0))
        case .solarized:
            return TerminalPalette(background: Color(red: 0.0, green: 0.168, blue: 0.212), foreground: Color(red: 0.514, green: 0.580, blue: 0.588), cursor: Color(red: 0.992, green: 0.965, blue: 0.890), selection: Color(red: 0.10, green: 0.30, blue: 0.34), accent: Color(red: 0.149, green: 0.545, blue: 0.824))
        case .dracula:
            return TerminalPalette(background: Color(red: 0.11, green: 0.10, blue: 0.16), foreground: Color(red: 0.93, green: 0.93, blue: 0.95), cursor: Color(red: 1.0, green: 0.47, blue: 0.77), selection: Color(red: 0.28, green: 0.25, blue: 0.38), accent: Color(red: 0.55, green: 0.91, blue: 0.99))
        case .paper:
            return TerminalPalette(background: Color(red: 0.97, green: 0.96, blue: 0.92), foreground: Color(red: 0.13, green: 0.15, blue: 0.17), cursor: .black, selection: Color.black.opacity(0.14), accent: Color(red: 0.10, green: 0.35, blue: 0.68))
        }
    }
}

public struct TerminalPalette {
    public let background: Color
    public let foreground: Color
    public let cursor: Color
    public let selection: Color
    public let accent: Color

    public init(background: Color, foreground: Color, cursor: Color, selection: Color, accent: Color) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.accent = accent
    }
}

public enum TerminalKey: String, CaseIterable, Sendable {
    case escape = "\u{1B}"
    case tab = "\t"
    case left = "\u{1B}[D"
    case up = "\u{1B}[A"
    case down = "\u{1B}[B"
    case right = "\u{1B}[C"
    case tilde = "~"
    case slash = "/"
    case dash = "-"

    public var bytes: Data { Data(rawValue.utf8) }

    /// Encodes a control character such as Ctrl-C (`0x03`).
    public static func control(_ character: Character) -> Data {
        guard let scalar = character.unicodeScalars.first, scalar.isASCII else { return Data() }
        return Data([UInt8(scalar.value & 0x1F)])
    }

    public static var ctrlC: Data { control("c") }
}

public final class TerminalSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let cwd: String
    public let environment: [String: String]
    @Published public private(set) var pid: Int32?
    @Published public private(set) var isRunning = false
    @Published public private(set) var cols = 80
    @Published public private(set) var rows = 24

    private let engine: TerminalEngine
    private var pty: PtyPair?
    private let outputQueue = DispatchQueue(label: "com.termx.session.output", qos: .userInitiated)
    private var onInput: ((Data) -> Void)?
    private var onOutput: ((Data) -> Void)?
    private let readerLock = NSLock()
    private var readerShouldStop = false
    private var readerFinished: DispatchSemaphore?

    /// Supplies the reset sequence a program owed the terminal when it left it
    /// in a TUI mode (alternate screen, hidden cursor, mouse reporting). Wired
    /// by the view layer to the output pipeline's mode tracker; it returns no
    /// bytes when the terminal is already clean, so it is safe to ask on every
    /// exit rather than guessing which ones were abnormal.
    public var terminalRestoreProvider: (() -> Data)?

    /// Ask for a repair sequence and, if there is one, deliver it through the
    /// normal output path so it is both rendered and recorded.
    private func restoreTerminalIfNeeded() {
        guard let restore = terminalRestoreProvider?(), !restore.isEmpty else { return }
        outputQueue.async { [weak self] in self?.deliverOutput(restore) }
    }

    /// Fired on the main queue when the guest shell exits, with its code.
    /// The lifecycle state machine turns this into `.shellExited`.
    public var onShellExited: ((Int32) -> Void)?

    public init(cwd: String, environment: [String: String] = TerminalSession.defaultEnvironment(), engine: TerminalEngine, onInput: ((Data) -> Void)? = nil, onOutput: ((Data) -> Void)? = nil) {
        self.cwd = cwd
        self.environment = environment
        self.engine = engine
        self.onInput = onInput
        self.onOutput = onOutput
    }

    public static func defaultEnvironment(home: String = NSHomeDirectory()) -> [String: String] {
        ["HOME": home, "PATH": "/bin:\(home)/wasm/bin:\(home)/node/bin:\(home)/python/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
    }

    @discardableResult
    public func start() throws -> Int32 {
        let pair = try PtyPair(cols: cols, rows: rows)
        pty = pair
        do {
            let startedPID = try start(ptySlave: pair.slave)
            startPTYIO(master: pair.master)
            return startedPID
        } catch {
            pair.close()
            pty = nil
            throw error
        }
    }

    @discardableResult
    public func start(ptySlave: Int32) throws -> Int32 {
        guard !isRunning else { throw TerminalSessionError.alreadyRunning }
        let startedPID = try engine.startShell(cwd: cwd, env: environment, ptySlave: ptySlave) { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.pid = nil
                // Repair first, so the exit notice lands on the primary screen
                // instead of a dead alternate buffer.
                self.restoreTerminalIfNeeded()
                let notice = Data("\n[process exited with code \(code)]\n".utf8)
                self.outputQueue.async { self.deliverOutput(notice) }
                self.onShellExited?(code)
                self.shutdownPTY()
            }
        }
        pid = startedPID
        isRunning = true
        return startedPID
    }

    public func send(_ data: Data) {
        // Real terminals only forward keystrokes (including ^C) to the PTY.
        // Programs handle single vs double Ctrl-C and emit their own teardown
        // sequences (e.g. CSI ?1049l). Do not host-force-kill on repeated ^C.
        mirrorInputLog(data)
        outputQueue.async { [weak self] in
            self?.onInput?(data)
        }
    }

    /// Records keystrokes heading into the PTY when `TETHER_PTY_LOG=1`.
    /// Output-side logging alone cannot answer "did the key reach the
    /// program?", which is the first question for any stuck-input report.
    private func mirrorInputLog(_ data: Data) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["TETHER_PTY_LOG"] == "1" else { return }
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent(".tether-input.log")
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        // The line-discipline state at the moment the key was sent. A program
        // in raw mode receives 0x03 as a byte; in cooked mode the kernel
        // echoes "^C" and raises SIGINT instead. This is what distinguishes
        // "the key never arrived" from "the program was not in raw mode".
        var mode = "termios=?"
        if let master = pty?.master, master >= 0 {
            var t = termios()
            if tcgetattr(master, &t) == 0 {
                let icanon = (t.c_lflag & tcflag_t(ICANON)) != 0
                let echo = (t.c_lflag & tcflag_t(ECHO)) != 0
                let isig = (t.c_lflag & tcflag_t(ISIG)) != 0
                mode = "ICANON=\(icanon ? 1 : 0) ECHO=\(echo ? 1 : 0) ISIG=\(isig ? 1 : 0)"
            }
        }
        let line = "\(Date().timeIntervalSince1970) in: \(hex) [\(mode)]\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        #endif
    }
    public func send(_ text: String) { send(Data(text.utf8)) }

    /// Notified after every geometry change so host-proxied jobs — which do
    /// not sit under the guest's controlling terminal and therefore never see
    /// the kernel's SIGWINCH — can be told the new size.
    public var onResize: ((Int, Int) -> Void)?

    public func resize(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        pty?.resize(cols: self.cols, rows: self.rows)
        if let pid { engine.signal(pid: pid, SIGWINCH) }
        onResize?(self.cols, self.rows)
    }

    /// Called when a host-proxied job (one run through `hostExec` rather than
    /// as a guest process) finishes. The shell itself is still alive, so no
    /// exit notice is emitted — but the job may have died mid-TUI and left the
    /// terminal wedged, which is exactly what a real multiplexer repairs here.
    public func hostJobFinished(code: Int32) {
        if Thread.isMainThread {
            restoreTerminalIfNeeded()
        } else {
            DispatchQueue.main.async { [weak self] in self?.restoreTerminalIfNeeded() }
        }
    }

    public func interrupt() { if let pid { engine.signal(pid: pid, SIGINT) } }
    public func terminate() {
        if let pid { engine.signal(pid: pid, SIGTERM) }
        isRunning = false
        pid = nil
        shutdownPTY()
    }

    // MARK: - Ordered teardown steps
    //
    // `terminate()` bundles signal + close for callers that just want the
    // session gone. The lifecycle state machine needs the steps separately so
    // it can enforce the ordering that matters: the reader must stop before the
    // PTY descriptor is closed, because closing a descriptor a thread is
    // blocked reading can crash the process.

    /// Send the named signal to the guest shell without tearing anything down.
    public func signalShell(_ name: String) {
        guard let pid else { return }
        switch name {
        case "SIGINT": engine.signal(pid: pid, SIGINT)
        case "SIGKILL": engine.signal(pid: pid, SIGKILL)
        case "SIGHUP": engine.signal(pid: pid, SIGHUP)
        default: engine.signal(pid: pid, SIGTERM)
        }
    }

    /// Wait up to `graceMillis` for the engine to report exit, then continue
    /// regardless. Never blocks longer than the grace period.
    public func waitForEngineExit(graceMillis: Int) {
        let deadline = Date().addingTimeInterval(Double(max(0, graceMillis)) / 1000)
        while isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        isRunning = false
        pid = nil
    }

    /// Signal the PTY reader to stop and wait briefly for it to finish.
    public func stopOutputPumpForTeardown() {
        readerLock.lock()
        readerShouldStop = true
        let semaphore = readerFinished
        readerLock.unlock()
        if let semaphore {
            _ = semaphore.wait(timeout: .now() + 0.5)
        }
    }

    /// Close the PTY. Only legal after `stopOutputPumpForTeardown()`.
    public func closePTYAfterReaderStops() {
        readerLock.lock()
        let pair = pty
        pty = nil
        readerFinished = nil
        readerLock.unlock()
        pair?.close()
    }

    // MARK: - Test transcript (temporary — remove after debugging)

    /// Rolling capture of everything written to the PTY (banner, typed echo, stdout/stderr,
    /// errors). Used by the temporary “Copy log” button so a session can be pasted into chat.
    private var transcript = Data()
    private static let transcriptCap = 2 * 1024 * 1024

    private func appendTranscript(_ data: Data) {
        guard !data.isEmpty else { return }
        transcript.append(data)
        if transcript.count > Self.transcriptCap {
            transcript.removeFirst(transcript.count - Self.transcriptCap)
        }
    }

    /// Snapshot for clipboard: full diagnostic bundle + ANSI-stripped terminal text.
    public func copyableTranscript() -> String {
        var sessionMeta = """
        cwd: \(cwd)
        cols×rows: \(cols)×\(rows)
        running: \(isRunning)
        """
        if let pid { sessionMeta += "\npid: \(pid)" }

        let body: String = outputQueue.sync {
            String(data: transcript, encoding: .utf8)
                ?? String(decoding: transcript, as: UTF8.self)
        }
        let plain = Self.stripANSI(body)
        return CopyLogDiagnostics.shared.diagnosticHeader(sessionLines: sessionMeta + "\n---\n" + plain)
    }

    /// Test-only: inject bytes as if the PTY produced them.
    public func appendTranscriptForTesting(_ data: Data) {
        outputQueue.sync { appendTranscript(data) }
    }

    /// The tail of everything the PTY has produced, for a scrollback snapshot.
    /// Recent output is what matters on restore, so the head is dropped.
    public func recentOutputTail(maxBytes: Int) -> Data {
        outputQueue.sync {
            guard transcript.count > maxBytes else { return transcript }
            return transcript.suffix(maxBytes)
        }
    }

    /// Render bytes into the terminal as if the shell had produced them,
    /// without recording them in the transcript. Used to replay a restored
    /// scrollback snapshot; replaying into the transcript would make the next
    /// snapshot contain a copy of the previous one.
    public func renderWithoutRecording(_ data: Data) {
        guard !data.isEmpty else { return }
        outputQueue.async { [weak self] in
            self?.onOutput?(data)
        }
    }

    private static func stripANSI(_ text: String) -> String {
        // CSI / OSC / simple ESC sequences — keep plain text for pasting into chat.
        let patterns = [
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}\\][^\u{0007}]*(\u{0007}|\u{001B}\\\\)",
            "\u{001B}[()][0-9A-Za-z]",
            "\u{001B}.",
        ]
        var result = text
        for pattern in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: []) {
                result = re.stringByReplacingMatches(
                    in: result, options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result
    }

    /// Stops the reader thread before closing the descriptors. Never blocks the caller
    /// (Close workspace runs on the main thread); the reader exits within one poll window.
    private func shutdownPTY() {
        readerLock.lock()
        readerShouldStop = true
        let semaphore = readerFinished
        let pair = pty
        pty = nil
        readerLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let semaphore {
                _ = semaphore.wait(timeout: .now() + 0.5)
            }
            pair?.close()
            self?.readerLock.lock()
            self?.readerFinished = nil
            self?.readerLock.unlock()
        }
    }

    public func attachOutputHandler(_ handler: @escaping (Data) -> Void) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.onOutput = handler
            if !self.pendingOutput.isEmpty {
                let buffered = self.pendingOutput
                self.pendingOutput.removeAll()
                handler(buffered)
            }
        }
    }

    /// Output produced before a handler attaches (e.g. the shell banner written while the
    /// view is still appearing) is buffered here and flushed on attach.
    private var pendingOutput = Data()
    private static let pendingOutputCap = 512 * 1024

    private func deliverOutput(_ data: Data) {
        appendTranscript(data)
        Self.mirrorPtyLog(data)
        if let onOutput {
            onOutput(data)
        } else {
            pendingOutput.append(data)
            if pendingOutput.count > Self.pendingOutputCap {
                pendingOutput.removeFirst(pendingOutput.count - Self.pendingOutputCap)
            }
        }
    }

    /// DEBUG/test: TETHER_PTY_LOG=1 mirrors PTY bytes to Documents/.tether-pty.log
    /// so Simulator harnesses can inspect interactive Claude login without redirects.
    private static func mirrorPtyLog(_ data: Data) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TETHER_PTY_LOG"] ?? environment["TERMX_PTY_LOG"]) == "1",
              !data.isEmpty else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(".tether-pty.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        #endif
    }

    /// Pastes UTF-8 text into the PTY as if the user pasted from the clipboard.
    public func paste(_ text: String) {
        let data = Data(text.utf8)
        let chunkSize = 1024
        if data.count <= chunkSize {
            send(data)
            return
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            send(data.subdata(in: offset..<end))
            offset = end
        }
    }

#if canImport(Darwin)
    private func startPTYIO(master: Int32) {
        readerLock.lock()
        readerShouldStop = false
        let finished = DispatchSemaphore(value: 0)
        readerFinished = finished
        readerLock.unlock()

        onInput = { [weak self] data in
            guard let self else { return }
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var remaining = data.count
                var offset = 0
                while remaining > 0 {
                    self.readerLock.lock()
                    let stopped = self.readerShouldStop
                    self.readerLock.unlock()
                    if stopped { return }

                    let written = Darwin.write(master, baseAddress.advanced(by: offset), remaining)
                    if written > 0 {
                        offset += written
                        remaining -= written
                        continue
                    }
                    // EINTR/EAGAIN are transient; anything else (EIO once the slave is
                    // gone) is permanent — give up instead of spinning forever.
                    if written < 0 && (errno == EINTR || errno == EAGAIN) {
                        usleep(2000)
                        continue
                    }
                    return
                }
            }
        }

        DispatchQueue(label: "com.termx.session.pty-reader", qos: .userInitiated).async { [weak self] in
            var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
            defer { finished.signal() }
            while true {
                guard let self else { return }
                self.readerLock.lock()
                let stopped = self.readerShouldStop
                self.readerLock.unlock()
                if stopped { return }

                // Poll so the loop can observe the stop flag. 200 ms keeps idle CPU low
                // while still feeling responsive once output arrives.
                var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 200)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                if pfd.revents & Int16(POLLNVAL) != 0 { return }

                let count = Darwin.read(master, &readBuffer, readBuffer.count)
                if count > 0 {
                    let chunk = Data(readBuffer[0..<count])
                    self.outputQueue.async { self.deliverOutput(chunk) }
                    continue
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                return  // EOF or permanent error: the pty is finished.
            }
        }
    }
#endif
}


public enum TerminalSessionError: Error, Equatable { case alreadyRunning }

#if !canImport(Darwin)
private let SIGINT: Int32 = 2
private let SIGTERM: Int32 = 15
private let SIGWINCH: Int32 = 28
#endif
