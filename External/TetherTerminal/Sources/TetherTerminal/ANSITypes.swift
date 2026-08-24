//
//  ANSITypes.swift
//  TetherTerminal
//
//  Value types used by the escape parser and terminal state.
//

import Foundation

/// A fully-decoded CSI (Control Sequence Introducer) command.
///
/// A CSI sequence has the form `ESC [ <parameter-bytes> <intermediate-bytes> <final-byte>`.
/// When the sequence begins with `?` (e.g. `ESC [ ? 2031 h`) it is a *private* / DEC
/// sequence and `isPrivate` is `true`.
public struct CSICommand: Equatable {
    /// Final byte that terminates the CSI (e.g. `m` for SGR, `H` for cursor position).
    public let finalByte: UInt8
    /// Raw parameter bytes, e.g. `"31;1"`. May be empty.
    public let parameters: String
    /// Raw intermediate bytes (0x20...0x2F), rarely used.
    public let intermediates: String
    /// True if the sequence started with `?` (DEC private mode).
    public let isPrivate: Bool

    public init(finalByte: UInt8,
                parameters: String = "",
                intermediates: String = "",
                isPrivate: Bool = false) {
        self.finalByte = finalByte
        self.parameters = parameters
        self.intermediates = intermediates
        self.isPrivate = isPrivate
    }

    /// Numeric parameters split on `;` (and `:`). Missing or non-numeric entries
    /// default to `0`.
    public var numericParameters: [Int] {
        guard !parameters.isEmpty else { return [] }
        // Separators are 0x3B (;) and 0x3A (:) per the VT standard.
        let parts = parameters.split(whereSeparator: { $0 == ";" || $0 == ":" })
        return parts.map { Int($0) ?? 0 }
    }

    /// Returns the parameter at `index`, or `defaultValue` if absent.
    public func parameter(_ index: Int, default defaultValue: Int = 0) -> Int {
        let nums = numericParameters
        guard index < nums.count else { return defaultValue }
        return nums[index]
    }
}

/// Select Graphic Rendition attribute set applied to cells.
public struct SGRAttributes: Equatable {
    public var foreground: AnsiColor? = nil
    public var background: AnsiColor? = nil
    public var bold: Bool = false
    public var faint: Bool = false
    public var italic: Bool = false
    public var underline: Bool = false
    public var blink: Bool = false
    public var inverse: Bool = false
    public var hidden: Bool = false
    public var strikethrough: Bool = false

    public init() {}
}

/// An ANSI/xterm color value.
public enum AnsiColor: Equatable {
    /// Standard 16-color palette index (0...15).
    case palette(Int)
    /// 256-color palette index (0...255).
    case indexed(Int)
    /// 24-bit RGB color.
    case rgb(red: Int, green: Int, blue: Int)

    /// The 8 low standard colors.
    public static let black = AnsiColor.palette(0)
    public static let red = AnsiColor.palette(1)
    public static let green = AnsiColor.palette(2)
    public static let yellow = AnsiColor.palette(3)
    public static let blue = AnsiColor.palette(4)
    public static let magenta = AnsiColor.palette(5)
    public static let cyan = AnsiColor.palette(6)
    public static let white = AnsiColor.palette(7)
    public static let defaultColor = AnsiColor.palette(9) // sentinel: default fg/bg
}

/// A zero-based cursor position on the screen.
public struct CursorPosition: Equatable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// A single screen cell: a character plus its graphic rendition.
public struct Cell: Equatable {
    public var character: Character = " "
    public var attributes: SGRAttributes = SGRAttributes()

    public init() {}
    public init(character: Character, attributes: SGRAttributes) {
        self.character = character
        self.attributes = attributes
    }
}

/// Mouse button / wheel event delivered through the parser delegate.
public struct MouseEvent: Equatable {
    public enum Kind: Equatable { case press, release, motion, wheelUp, wheelDown }
    public var kind: Kind
    public var column: Int
    public var row: Int
    public var button: Int

    public init(kind: Kind, column: Int, row: Int, button: Int) {
        self.kind = kind
        self.column = column
        self.row = row
        self.button = button
    }
}
