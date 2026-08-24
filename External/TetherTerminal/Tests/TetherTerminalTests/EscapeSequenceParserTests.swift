//
//  EscapeSequenceParserTests.swift
//  TetherTerminalTests
//
//  Tests for the streaming parser state machine (without screen state).
//

import XCTest
@testable import TetherTerminal

/// A delegate that records every callback so tests can assert on them.
final class RecordingDelegate: EscapeSequenceParserDelegate {
    var text: [String] = []
    var controls: [UInt8] = []
    var csis: [CSICommand] = []
    var oscs: [String] = []
    var escapes: [UInt8] = []
    var charsets: [UInt8] = []

    func parser(_ parser: EscapeSequenceParser, didReadText s: String) { text.append(s) }
    func parser(_ parser: EscapeSequenceParser, didReadControl byte: UInt8) { controls.append(byte) }
    func parser(_ parser: EscapeSequenceParser, didReadCSI command: CSICommand) { csis.append(command) }
    func parser(_ parser: EscapeSequenceParser, didReadOSC string: String) { oscs.append(string) }
    func parser(_ parser: EscapeSequenceParser, didReadEscape finalByte: UInt8) { escapes.append(finalByte) }
    func parser(_ parser: EscapeSequenceParser, didReadCharsetDesignation finalByte: UInt8) { charsets.append(finalByte) }

    var joinedText: String { text.joined() }
}

final class EscapeSequenceParserTests: XCTestCase {

    private func makeParser() -> (EscapeSequenceParser, RecordingDelegate) {
        let p = EscapeSequenceParser()
        let d = RecordingDelegate()
        p.delegate = d
        return (p, d)
    }

    // MARK: - Text

    func testPlainASCIITextIsDelivered() {
        let (p, d) = makeParser()
        p.feed("hello")
        p.flush()
        XCTAssertEqual(d.joinedText, "hello")
        XCTAssertTrue(d.csis.isEmpty)
    }

    func testMultipleFeedsConcatenateText() {
        let (p, d) = makeParser()
        p.feed("foo")
        p.feed("bar")
        p.feed("baz")
        p.flush()
        XCTAssertEqual(d.joinedText, "foobarbaz")
    }

    // MARK: - C0 controls

    func testLineFeedControl() {
        let (p, d) = makeParser()
        p.feed("ab\ncd")
        p.flush()
        XCTAssertEqual(d.joinedText, "abcd")
        XCTAssertEqual(d.controls, [0x0A])
    }

    func testCarriageReturnAndTabAndBackspace() {
        let (p, d) = makeParser()
        p.feed([0x0D, 0x09, 0x08]) // CR, HT, BS
        XCTAssertEqual(d.controls, [0x0D, 0x09, 0x08])
    }

    func testNULIsIgnoredAndDELIsIgnored() {
        let (p, d) = makeParser()
        p.feed([0x00, 0x41, 0x7F, 0x42]) // NUL A DEL B
        p.flush()
        XCTAssertEqual(d.joinedText, "AB")
        XCTAssertTrue(d.controls.isEmpty)
    }

    func testBELIsDeliveredAsControl() {
        let (p, d) = makeParser()
        p.feed([0x07])
        XCTAssertEqual(d.controls, [0x07])
    }

    // MARK: - CSI

    func testCursorUpCSI() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[5A")
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "A"))
        XCTAssertEqual(d.csis[0].numericParameters, [5])
        XCTAssertFalse(d.csis[0].isPrivate)
    }

    func testSGRColorCSIParameters() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[31;1m")
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "m"))
        XCTAssertEqual(d.csis[0].numericParameters, [31, 1])
    }

    func testEmptyCSIDefaultsNoParameters() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[H")
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "H"))
        XCTAssertTrue(d.csis[0].numericParameters.isEmpty)
    }

    func testPrivateDECSET2031IsMarkedPrivate() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[?2031h")
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertTrue(d.csis[0].isPrivate)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "h"))
        XCTAssertEqual(d.csis[0].numericParameters, [2031])
    }

    func testPrivateDECRST2031() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[?2031l")
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertTrue(d.csis[0].isPrivate)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "l"))
    }

    func testUnknownCSIFinalByteDoesNotCrash() {
        let (p, d) = makeParser()
        // Some random unknown CSI: ESC [ ? 9999 z
        p.feed("\u{1B}[?9999z")
        p.feed("\u{1B}[1234Q")
        p.flush()
        XCTAssertEqual(d.csis.count, 2)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "z"))
        XCTAssertEqual(d.csis[1].finalByte, UInt8(ascii: "Q"))
        // Parser is back on ground; following text still works.
        p.feed("ok")
        p.flush()
        XCTAssertEqual(d.joinedText, "ok")
    }

    // MARK: - Split sequences

    func testCSISplitAcrossTwoFeedsReassembles() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[31")
        p.feed("m")
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "m"))
        XCTAssertEqual(d.csis[0].numericParameters, [31])
    }

    func testEscapeAndBracketSplitAcrossFeeds() {
        let (p, d) = makeParser()
        p.feed([0x1B]) // ESC only
        p.feed("[H")   // [ H
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "H"))
    }

    func testTextAfterSplitSequenceStillParses() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[?2031")
        p.feed("h")
        p.feed("safe")
        p.flush()
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.joinedText, "safe")
    }

    // MARK: - Malformed / garbage safety

    func testGarbageAfterEscapeDoesNotCrash() {
        let (p, d) = makeParser()
        // ESC followed by random non-command bytes.
        p.feed([0x1B, 0x01, 0x02, 0x41, 0x42])
        p.flush()
        XCTAssertEqual(d.joinedText, "AB")
    }

    func testTruncatedSequenceAtEndDoesNotCrash() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[?2031") // never terminated
        p.flush()
        XCTAssertTrue(d.csis.isEmpty)
        // Recovers when fed more.
        p.feed("h")
        XCTAssertEqual(d.csis.count, 1)
    }

    func testLongRandomGarbageDoesNotCrash() {
        let (p, _) = makeParser()
        var rng = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)
        for _ in 0..<5000 {
            let byte = UInt8(rng.next() % 256)
            p.feed([byte])
        }
        p.flush()
        // If we get here without trapping, the parser is robust.
    }

    // MARK: - OSC

    func testOSCWindowTitleBELTerminated() {
        let (p, d) = makeParser()
        p.feed("\u{1B}]2;My Title\u{07}")
        XCTAssertEqual(d.oscs.count, 1)
        XCTAssertEqual(d.oscs[0], "2;My Title")
    }

    func testOSCWindowTitleSTTerminated() {
        let (p, d) = makeParser()
        p.feed("\u{1B}]0;hello\u{1B}\\")
        XCTAssertEqual(d.oscs.count, 1)
        XCTAssertEqual(d.oscs[0], "0;hello")
    }

    func testTextAfterOSCResumesCorrectly() {
        let (p, d) = makeParser()
        p.feed("\u{1B}]0;t\u{07}after")
        p.flush()
        XCTAssertEqual(d.oscs.count, 1)
        XCTAssertEqual(d.joinedText, "after")
    }

    // MARK: - Other escape forms

    func testTwoCharacterEscapesSavedAndRestoredCursor() {
        let (p, d) = makeParser()
        p.feed("\u{1B}7\u{1B}8")
        XCTAssertEqual(d.escapes, [UInt8(ascii: "7"), UInt8(ascii: "8")])
    }

    func testCharsetDesignationAccepted() {
        let (p, d) = makeParser()
        p.feed("\u{1B}(B")
        XCTAssertEqual(d.charsets, [UInt8(ascii: "B")])
    }

    func testHardResetEscape() {
        let (p, d) = makeParser()
        p.feed("\u{1B}c")
        XCTAssertEqual(d.escapes, [UInt8(ascii: "c")])
    }

    func testDCSIsSkippedSafely() {
        let (p, d) = makeParser()
        // DCS ... ST (ESC \)
        p.feed("\u{1B}Psome data\u{1B}\\")
        p.feed("back")
        p.flush()
        XCTAssertTrue(d.csis.isEmpty)
        XCTAssertTrue(d.oscs.isEmpty)
        XCTAssertEqual(d.joinedText, "back")
    }

    func testSingleByteC1CSIWorks() {
        let (p, d) = makeParser()
        p.feed([0x9B, 0x48]) // CSI H as C1
        XCTAssertEqual(d.csis.count, 1)
        XCTAssertEqual(d.csis[0].finalByte, UInt8(ascii: "H"))
    }

    // MARK: - UTF-8

    func testMultibyteUTF8InOneFeed() {
        let (p, d) = makeParser()
        p.feed("café ✓ 日本語")
        p.flush()
        XCTAssertEqual(d.joinedText, "café ✓ 日本語")
    }

    func testMultibyteUTF8SplitAcrossFeeds() {
        let (p, d) = makeParser()
        // "é" = 0xC3 0xA9. Split the two raw bytes across feeds.
        p.feed([0x63, 0x61, 0x66, 0xC3]) // "caf" + lead byte
        p.feed([0xA9])                   // continuation byte
        p.flush()
        XCTAssertEqual(d.joinedText, "café")
    }

    func testFourByteUTF8SplitAcrossFeeds() {
        let (p, d) = makeParser()
        // 🍞 = F0 9F 8D 9E
        let bytes: [UInt8] = [0xF0, 0x9F, 0x8D, 0x9E]
        p.feed(Array(bytes.prefix(1)))
        p.feed(Array(bytes.dropFirst(1).prefix(1)))
        p.feed(Array(bytes.dropFirst(2)))
        p.flush()
        XCTAssertEqual(d.joinedText, "🍞")
    }

    func testInvalidUTF8ProducesReplacementCharacterNoCrash() {
        let (p, d) = makeParser()
        // 0xFF is never valid UTF-8.
        p.feed([0x41, 0xFF, 0x42])
        p.flush()
        XCTAssertTrue(d.joinedText.contains("A"))
        XCTAssertTrue(d.joinedText.contains("B"))
        XCTAssertTrue(d.joinedText.contains("\u{FFFD}"))
    }

    // MARK: - CSICommand helpers

    func testCSICommandParameterDefault() {
        let cmd = CSICommand(finalByte: UInt8(ascii: "A"), parameters: "5")
        XCTAssertEqual(cmd.parameter(0, default: 1), 5)
        XCTAssertEqual(cmd.parameter(1, default: 9), 9)
    }

    func testCSICommandColonSubparameterSplit() {
        let cmd = CSICommand(finalByte: UInt8(ascii: "m"), parameters: "38:2:255:0:128")
        XCTAssertEqual(cmd.numericParameters, [38, 2, 255, 0, 128])
    }

    func testResetReturnsToGround() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[?2031") // partial
        p.reset()
        p.feed("X")
        p.flush()
        XCTAssertTrue(d.csis.isEmpty)
        XCTAssertEqual(d.joinedText, "X")
    }

    // MARK: - CAN / SUB abort sequences

    func testCANAbortsInProgressCSI() {
        let (p, d) = makeParser()
        p.feed("\u{1B}[31")  // partial SGR
        p.feed([0x18])       // CAN — aborts
        p.feed("m")          // now just text
        p.flush()
        XCTAssertTrue(d.csis.isEmpty)
        XCTAssertEqual(d.joinedText, "m")
    }

    func testSUBInGroundIsDeliveredAsControl() {
        let (p, d) = makeParser()
        p.feed([0x1A]) // SUB in ground -> control
        XCTAssertEqual(d.controls, [0x1A])
    }

    func testSUBAbortsInProgressEscape() {
        let (p, d) = makeParser()
        p.feed([0x1B, 0x5B, 0x33]) // ESC [ 3 (partial)
        p.feed([0x1A])             // SUB aborts
        p.feed("Z")
        p.flush()
        XCTAssertTrue(d.csis.isEmpty)
        XCTAssertEqual(d.joinedText, "Z")
    }

    // MARK: - UTF-8 / escape boundary robustness

    func testIncompleteUTF8LeadFollowedByESCFlushesReplacement() {
        let (p, d) = makeParser()
        p.feed([0x61, 0xC3]) // 'a' + dangling lead
        p.feed("\u{1B}c")    // ESC c (hard reset escape)
        p.flush()
        // The dangling lead must not be held across the escape boundary; it
        // becomes a replacement character, while the escape still fires.
        XCTAssertTrue(d.joinedText.contains("a"))
        XCTAssertTrue(d.joinedText.contains("\u{FFFD}"))
        XCTAssertEqual(d.escapes, [UInt8(ascii: "c")])
    }
}

/// Tiny deterministic RNG so the fuzz test is reproducible.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
