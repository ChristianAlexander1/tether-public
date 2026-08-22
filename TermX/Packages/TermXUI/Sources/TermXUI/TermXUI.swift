import Foundation
import SwiftUI
import Combine
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
                let notice = Data("\n[process exited with code \(code)]\n".utf8)
                self.outputQueue.async { self.deliverOutput(notice) }
                self.shutdownPTY()
            }
        }
        pid = startedPID
        isRunning = true
        return startedPID
    }

    public func send(_ data: Data) { outputQueue.async { [weak self] in self?.onInput?(data) } }
    public func send(_ text: String) { send(Data(text.utf8)) }

    public func resize(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        pty?.resize(cols: self.cols, rows: self.rows)
        if let pid { engine.signal(pid: pid, SIGWINCH) }
    }

    public func interrupt() { if let pid { engine.signal(pid: pid, SIGINT) } }
    public func terminate() {
        if let pid { engine.signal(pid: pid, SIGTERM) }
        isRunning = false
        shutdownPTY()
    }

    /// Stops the reader thread before closing the descriptors. Closing a pty master
    /// while a thread is blocked in read() wedges the caller, so the reader is asked to
    /// finish first and only then are the fds released.
    private func shutdownPTY() {
        readerLock.lock()
        readerShouldStop = true
        let semaphore = readerFinished
        readerLock.unlock()
        if let semaphore {
            _ = semaphore.wait(timeout: .now() + 1.0)
            readerLock.lock(); readerFinished = nil; readerLock.unlock()
        }
        pty?.close()
        pty = nil
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
        if let onOutput {
            onOutput(data)
        } else {
            pendingOutput.append(data)
            if pendingOutput.count > Self.pendingOutputCap {
                pendingOutput.removeFirst(pendingOutput.count - Self.pendingOutputCap)
            }
        }
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

                // Poll so the loop can observe the stop flag instead of blocking in
                // read() forever, which would make closing the pty hang the closer.
                var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
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
