//
//  EscapeSequenceParser.swift
//  TetherTerminal
//
//  A streaming VT100/xterm escape-sequence parser.
//
//  Design goals:
//    • Never crash on malformed / unknown sequences (the original "smashed CLI
//      text" / "Unhandled DECSET 2031" bug).
//    • Correctly reassemble sequences that are split across multiple `feed` calls.
//    • Correctly decode UTF-8 text that is split across multiple `feed` calls.
//    • Modeled on the Paul Williams / VT500-series state machine, simplified.
//

import Foundation

/// Delegate that receives decoded text and escape commands.
///
/// Every method has a default empty implementation so conformers only handle the
/// events they care about — unknown sequences simply become a no-op.
public protocol EscapeSequenceParserDelegate: AnyObject {
    /// A run of plain (already UTF-8 decoded) text was received.
    func parser(_ parser: EscapeSequenceParser, didReadText text: String)
    /// A C0/C1 single-byte control (e.g. `\n`, `\r`, `\t`, BEL) was received.
    func parser(_ parser: EscapeSequenceParser, didReadControl byte: UInt8)
    /// A complete CSI command was decoded.
    func parser(_ parser: EscapeSequenceParser, didReadCSI command: CSICommand)
    /// An OSC (operating system command) string was decoded, e.g. window title.
    func parser(_ parser: EscapeSequenceParser, didReadOSC string: String)
    /// A two-character escape sequence (e.g. `ESC 7` / `ESC 8`) was decoded.
    func parser(_ parser: EscapeSequenceParser, didReadEscape finalByte: UInt8)
    /// A character set designation sequence (e.g. `ESC ( B`) was decoded.
    func parser(_ parser: EscapeSequenceParser, didReadCharsetDesignation finalByte: UInt8)
}

public extension EscapeSequenceParserDelegate {
    func parser(_ parser: EscapeSequenceParser, didReadText text: String) {}
    func parser(_ parser: EscapeSequenceParser, didReadControl byte: UInt8) {}
    func parser(_ parser: EscapeSequenceParser, didReadCSI command: CSICommand) {}
    func parser(_ parser: EscapeSequenceParser, didReadOSC string: String) {}
    func parser(_ parser: EscapeSequenceParser, didReadEscape finalByte: UInt8) {}
    func parser(_ parser: EscapeSequenceParser, didReadCharsetDesignation finalByte: UInt8) {}
}

/// Streaming VT100/xterm parser.
///
/// Feed bytes incrementally with `feed(_:)`. The parser retains all state between
/// calls, so an escape sequence or UTF-8 character split across two writes is
/// reassembled transparently.
public final class EscapeSequenceParser {

    /// Internal states of the parser state machine.
    private enum State {
        case ground
        case escape
        case csiEntry
        case csiParam
        case csiIntermediate
        case osc
        case oscStringEsc        // ESC seen inside OSC, awaiting '\' (ST)
        case charsetDesignation  // ESC followed by ( ) * + , - . /
        case dcs                 // device control string — collected and discarded safely
        case dcsStringEsc        // ESC seen inside DCS, awaiting '\' (ST)
    }

    public weak var delegate: EscapeSequenceParserDelegate?

    private var state: State = .ground

    // CSI assembly.
    private var csiParams: [UInt8] = []
    private var csiIntermediates: [UInt8] = []
    private var csiPrivateMarker: UInt8? = nil // '?' or '>' or '<' or '='

    // OSC assembly.
    private var oscBuffer: [UInt8] = []

    // DCS assembly.
    private var dcsBuffer: [UInt8] = []

    // Pending text bytes for UTF-8 decoding. Text is flushed whenever a control
    // character or escape is seen, so we never mix them with a multibyte sequence.
    private var textBuffer: [UInt8] = []

    public init() {}

    // MARK: - Public feeding

    /// Feed a chunk of raw bytes into the parser.
    public func feed(_ bytes: [UInt8]) {
        for byte in bytes {
            process(byte)
        }
    }

    /// Feed a raw `Data` object.
    public func feed(_ data: Data) {
        for byte in data { process(byte) }
    }

    /// Feed a Swift string (encoded as UTF-8).
    public func feed(_ string: String) {
        for byte in string.utf8 { process(byte) }
    }

    /// Flush any buffered text. Call when the stream goes idle if you need the
    /// final chunk of text delivered immediately.
    public func flush() {
        flushText(force: true)
    }

    /// Reset the parser to ground state, discarding any partial sequence.
    public func reset() {
        state = .ground
        csiParams.removeAll(keepingCapacity: true)
        csiIntermediates.removeAll(keepingCapacity: true)
        csiPrivateMarker = nil
        oscBuffer.removeAll(keepingCapacity: true)
        dcsBuffer.removeAll(keepingCapacity: true)
        textBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Core state machine

    private func process(_ byte: UInt8) {
        // C0 control characters (0x00...0x1F) are handled specially. NUL is
        // ignored, CAN/SUB abort in-progress sequences, ESC begins an escape,
        // BEL is a bell (and an OSC terminator), and the remainder (BS, HT, LF,
        // VT, FF, CR, etc.) are delivered as controls and terminate sequences.
        if byte <= 0x1F {
            switch byte {
            case 0x1B: // ESC
                // Inside an OSC/DCS string, ESC may begin ST ("ESC \").
                switch state {
                case .osc:
                    state = .oscStringEsc
                    return
                case .dcs:
                    state = .dcsStringEsc
                    return
                default:
                    break
                }
                // ESC starts a new escape sequence; flush buffered text.
                // Force-flush so a truncated multibyte lead at the boundary is
                // emitted as a replacement char instead of being held forever.
                flushText(force: true)
                beginEscape()
                return
            case 0x07: // BEL
                // BEL terminates an OSC string; otherwise it's an audible bell.
                if state == .osc {
                    finishOSC()
                    return
                }
                flushText(force: true)
                delegate?.parser(self, didReadControl: byte)
                return
            case 0x00: // NUL — ignored everywhere.
                return
            case 0x18: // CAN — cancel an in-progress escape/CSI/OSC/DCS.
                if state != .ground { state = .ground }
                return
            case 0x1A: // SUB — same as CAN, but treated as a control in ground.
                if state != .ground { state = .ground; return }
                flushText()
                delegate?.parser(self, didReadControl: byte)
                return
            default:
                // BS, HT, LF, VT, FF, CR, and other C0 controls.
                // Within OSC/DCS these are just string content.
                if state == .osc {
                    oscBuffer.append(byte)
                    return
                }
                if state == .dcs {
                    dcsBuffer.append(byte)
                    return
                }
                flushText(force: true)
                handleControl(byte)
                // A control character terminates any in-progress escape/CSI.
                if state != .ground { state = .ground }
                return
            }
        }

            // DEL (0x7F) is ignored everywhere.
            if byte == 0x7F { return }

            // Dispatch based on current state.
            switch state {
            case .ground:
                handleGround(byte)
            case .escape:
                handleEscape(byte)
            case .csiEntry:
                handleCSIEntry(byte)
            case .csiParam:
                handleCSIParam(byte)
            case .csiIntermediate:
                handleCSIIntermediate(byte)
            case .osc:
                handleOSC(byte)
            case .charsetDesignation:
                // The byte after the intermediate (e.g. 'B' in "ESC ( B") finalizes.
                delegate?.parser(self, didReadCharsetDesignation: byte)
                state = .ground
            case .dcs:
                // DCS content ends with ST (ESC \\) or CAN/SUB.
                dcsBuffer.append(byte)
            case .oscStringEsc:
                // ESC inside OSC: '\' ends the string (ST), anything else aborts.
                if byte == 0x5C { finishOSC() } else { state = .ground }
            case .dcsStringEsc:
                // ESC inside DCS: '\' ends DCS, content is ignored.
                if byte == 0x5C {
                    dcsBuffer.removeAll(keepingCapacity: true)
                    state = .ground
                } else {
                    state = .ground
                }
            }
    }

    // MARK: Ground — text and C1 controls

    private func handleGround(_ byte: UInt8) {
        // C1 control characters (0x80...0x9F): in modern terminals these are
        // treated as UTF-8 continuation / lead bytes, so only a few classic C1
        // controls are honored (most real-world streams are 8-bit clean UTF-8).
        if byte == 0x9B {
            // CSI as a single C1 byte — equivalent to ESC [.
            flushText(force: true)
            beginCSI()
            return
        }
        if byte == 0x9D {
            flushText(force: true)
            state = .osc
            oscBuffer.removeAll(keepingCapacity: true)
            return
        }
        // Otherwise treat as a printable / UTF-8 byte.
        textBuffer.append(byte)
        // If this byte completes a valid UTF-8 sequence, flush proactively so
        // short writes are delivered promptly; incomplete leading bytes stay
        // buffered awaiting continuation.
        tryFlushCompleteUTF8()
    }

    private func handleControl(_ byte: UInt8) {
        switch byte {
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            delegate?.parser(self, didReadControl: 0x0A)
        case 0x0D: // CR
            delegate?.parser(self, didReadControl: 0x0D)
        case 0x08: // BS
            delegate?.parser(self, didReadControl: 0x08)
        case 0x09: // TAB
            delegate?.parser(self, didReadControl: 0x09)
        default:
            delegate?.parser(self, didReadControl: byte)
        }
    }

    // MARK: Escape

    private func beginEscape() {
        state = .escape
        csiParams.removeAll(keepingCapacity: true)
        csiIntermediates.removeAll(keepingCapacity: true)
        csiPrivateMarker = nil
    }

    private func handleEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // '[' — CSI
            beginCSI()
        case 0x5D: // ']' — OSC
            state = .osc
            oscBuffer.removeAll(keepingCapacity: true)
        case 0x50: // 'P' — DCS
            state = .dcs
            dcsBuffer.removeAll(keepingCapacity: true)
        case 0x58, 0x5E, 0x5F: // SOS / PM / APC — skip until ST
            state = .dcs // reuse safe-skip buffer
        case 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F:
            // Character set designation intermediate: "( ) * + , - . /".
            // The final byte (e.g. 'B' in "ESC ( B") arrives next.
            state = .charsetDesignation
        case 0x20...0x2F:
            // Other intermediates — collect; final byte next (simplified).
            csiIntermediates.append(byte)
            state = .csiIntermediate // reuse; harmless for two-char escapes
        case 0x30...0x7E:
            // A simple two-character escape (e.g. ESC 7 / ESC 8 / ESC c).
            delegate?.parser(self, didReadEscape: byte)
            state = .ground
        default:
            // Unknown escape: ignore safely.
            state = .ground
        }
    }

    // MARK: CSI

    private func beginCSI() {
        state = .csiEntry
        csiParams.removeAll(keepingCapacity: true)
        csiIntermediates.removeAll(keepingCapacity: true)
        csiPrivateMarker = nil
    }

    private func handleCSIEntry(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // digits
            csiParams.append(byte)
            state = .csiParam
        case 0x3B: // ';'
            csiParams.append(byte)
            state = .csiParam
        case 0x3A: // ':' (subparameter separator)
            csiParams.append(byte)
            state = .csiParam
        case 0x3C, 0x3D, 0x3E, 0x3F: // < = > ? private marker
            csiPrivateMarker = byte
            state = .csiParam
        case 0x20...0x2F: // intermediates
            csiIntermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E: // final byte
            emitCSI(finalByte: byte)
        default:
            // Anything else is malformed; abandon the sequence safely.
            state = .ground
        }
    }

    private func handleCSIParam(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39, 0x3B, 0x3A:
            csiParams.append(byte)
        case 0x20...0x2F:
            csiIntermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E:
            emitCSI(finalByte: byte)
        default:
            state = .ground
        }
    }

    private func handleCSIIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20...0x2F:
            csiIntermediates.append(byte)
        case 0x40...0x7E:
            emitCSI(finalByte: byte)
        default:
            state = .ground
        }
    }

    private func emitCSI(finalByte: UInt8) {
        let command = CSICommand(
            finalByte: finalByte,
            parameters: String(bytes: csiParams, encoding: .ascii) ?? "",
            intermediates: String(bytes: csiIntermediates, encoding: .ascii) ?? "",
            isPrivate: csiPrivateMarker == 0x3F
        )
        delegate?.parser(self, didReadCSI: command)
        state = .ground
    }

    // MARK: OSC

    private func handleOSC(_ byte: UInt8) {
        // OSC terminates on BEL (0x07) or ST (ESC \). The outer loop intercepts
        // ESC; when we receive it we set a flag so the next '\' ends the OSC.
        if byte == 0x07 {
            finishOSC()
            return
        }
        oscBuffer.append(byte)
    }

    private func finishOSC() {
        let str = String(bytes: oscBuffer, encoding: .utf8)
            ?? String(bytes: oscBuffer, encoding: .isoLatin1)
            ?? ""
        delegate?.parser(self, didReadOSC: str)
        oscBuffer.removeAll(keepingCapacity: true)
        state = .ground
    }

    // MARK: UTF-8 text buffering

    /// Flush buffered text. When `force` is true, invalid/incomplete bytes are
    /// replaced with the Unicode replacement character so no data is lost and
    /// the parser never traps.
    private func flushText(force: Bool = false) {
        guard !textBuffer.isEmpty else { return }
        if force {
            let str = String(bytes: textBuffer, encoding: .utf8)
                ?? String(decoding: textBuffer, as: UTF8.self)
            textBuffer.removeAll(keepingCapacity: true)
            if !str.isEmpty {
                delegate?.parser(self, didReadText: str)
            }
        } else {
            // Opportunistic: flush only complete UTF-8 prefixes, leaving any
            // trailing incomplete multibyte sequence buffered.
            tryFlushCompleteUTF8()
        }
    }

    /// Flushes the longest valid UTF-8 prefix of `textBuffer`, leaving any
    /// incomplete trailing multibyte sequence in place.
    private func tryFlushCompleteUTF8() {
        guard !textBuffer.isEmpty else { return }
        var index = textBuffer.startIndex
        while index < textBuffer.endIndex {
            let first = textBuffer[index]
            let expected: Int
            switch first {
            case 0x00...0x7F: expected = 1
            case 0xC0...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF7: expected = 4
            default:
                // Invalid lead byte (continuation byte or 0xF8+). Emit what we
                // have up to here, then emit replacement for this byte.
                flushPrefix(upTo: index)
                delegate?.parser(self, didReadText: "\u{FFFD}")
                textBuffer.removeFirst()
                index = textBuffer.startIndex
                continue
            }
            let remaining = textBuffer.endIndex - index
            if remaining < expected {
                // Incomplete sequence at the tail — wait for more bytes.
                break
            }
            // Validate continuation bytes.
            var valid = true
            for i in 1..<expected {
                let b = textBuffer[index + i]
                if b < 0x80 || b > 0xBF { valid = false; break }
            }
            if !valid {
                flushPrefix(upTo: index)
                delegate?.parser(self, didReadText: "\u{FFFD}")
                textBuffer.removeFirst()
                index = textBuffer.startIndex
                continue
            }
            index += expected
        }
        flushPrefix(upTo: index)
    }

    private func flushPrefix(upTo index: Int) {
        guard index > textBuffer.startIndex else { return }
        let prefix = Array(textBuffer[textBuffer.startIndex..<index])
        textBuffer.removeFirst(index - textBuffer.startIndex)
        if let str = String(bytes: prefix, encoding: .utf8), !str.isEmpty {
            delegate?.parser(self, didReadText: str)
        }
    }
}
