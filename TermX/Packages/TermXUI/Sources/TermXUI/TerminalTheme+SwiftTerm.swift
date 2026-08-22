#if canImport(UIKit)
import SwiftUI
import SwiftTerm
import UIKit
import CoreText

extension TerminalTheme {
    func apply(to view: TerminalView, palette: TerminalPalette, font: TerminalFont, fontSize: CGFloat) {
        palette.applyBaseColors(to: view)
        view.installColors(ansiColors)
        font.apply(to: view, size: fontSize)
    }

    fileprivate var ansiColors: [SwiftTerm.Color] {
        switch self {
        case .midnight: return Self.midnightANSI
        case .solarized: return Self.solarizedANSI
        case .dracula: return Self.draculaANSI
        case .paper: return Self.paperANSI
        }
    }

    private static let midnightANSI: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x1a, green8: 0x1b, blue8: 0x26), SwiftTerm.Color(red8: 0xff, green8: 0x55, blue8: 0x55),
        SwiftTerm.Color(red8: 0x50, green8: 0xfa, blue8: 0x7b), SwiftTerm.Color(red8: 0xff, green8: 0xb8, blue8: 0x6c),
        SwiftTerm.Color(red8: 0x5c, green8: 0xbc, blue8: 0xff), SwiftTerm.Color(red8: 0xbd, green8: 0x93, blue8: 0xf9),
        SwiftTerm.Color(red8: 0x8b, green8: 0xe9, blue8: 0xfd), SwiftTerm.Color(red8: 0xbb, green8: 0xbb, blue8: 0xbb),
        SwiftTerm.Color(red8: 0x44, green8: 0x44, blue8: 0x44), SwiftTerm.Color(red8: 0xff, green8: 0x55, blue8: 0x55),
        SwiftTerm.Color(red8: 0x50, green8: 0xfa, blue8: 0x7b), SwiftTerm.Color(red8: 0xff, green8: 0xb8, blue8: 0x6c),
        SwiftTerm.Color(red8: 0x5c, green8: 0xbc, blue8: 0xff), SwiftTerm.Color(red8: 0xbd, green8: 0x93, blue8: 0xf9),
        SwiftTerm.Color(red8: 0x8b, green8: 0xe9, blue8: 0xfd), SwiftTerm.Color(red8: 0xff, green8: 0xff, blue8: 0xff)
    ]

    private static let solarizedANSI: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x07, green8: 0x36, blue8: 0x42), SwiftTerm.Color(red8: 0xdc, green8: 0x32, blue8: 0x2f),
        SwiftTerm.Color(red8: 0x85, green8: 0x99, blue8: 0x00), SwiftTerm.Color(red8: 0xb5, green8: 0x89, blue8: 0x00),
        SwiftTerm.Color(red8: 0x26, green8: 0x8b, blue8: 0xd2), SwiftTerm.Color(red8: 0xd3, green8: 0x36, blue8: 0x82),
        SwiftTerm.Color(red8: 0x2a, green8: 0xa1, blue8: 0x98), SwiftTerm.Color(red8: 0x83, green8: 0x94, blue8: 0x96),
        SwiftTerm.Color(red8: 0x00, green8: 0x2b, blue8: 0x36), SwiftTerm.Color(red8: 0xcb, green8: 0x4b, blue8: 0x16),
        SwiftTerm.Color(red8: 0x58, green8: 0x6e, blue8: 0x75), SwiftTerm.Color(red8: 0x65, green8: 0x7b, blue8: 0x83),
        SwiftTerm.Color(red8: 0x83, green8: 0x94, blue8: 0x96), SwiftTerm.Color(red8: 0x6c, green8: 0x71, blue8: 0xc4),
        SwiftTerm.Color(red8: 0x93, green8: 0xa1, blue8: 0xa1), SwiftTerm.Color(red8: 0xfd, green8: 0xf6, blue8: 0xe3)
    ]

    private static let draculaANSI: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x21, green8: 0x22, blue8: 0x2c), SwiftTerm.Color(red8: 0xff, green8: 0x55, blue8: 0x55),
        SwiftTerm.Color(red8: 0x50, green8: 0xfa, blue8: 0x7b), SwiftTerm.Color(red8: 0xff, green8: 0xb8, blue8: 0x6c),
        SwiftTerm.Color(red8: 0xbd, green8: 0x93, blue8: 0xf9), SwiftTerm.Color(red8: 0xff, green8: 0x79, blue8: 0xc6),
        SwiftTerm.Color(red8: 0x8b, green8: 0xe9, blue8: 0xfd), SwiftTerm.Color(red8: 0xf8, green8: 0xf8, blue8: 0xf2),
        SwiftTerm.Color(red8: 0x44, green8: 0x47, blue8: 0x5a), SwiftTerm.Color(red8: 0xff, green8: 0x55, blue8: 0x55),
        SwiftTerm.Color(red8: 0x50, green8: 0xfa, blue8: 0x7b), SwiftTerm.Color(red8: 0xff, green8: 0xb8, blue8: 0x6c),
        SwiftTerm.Color(red8: 0xbd, green8: 0x93, blue8: 0xf9), SwiftTerm.Color(red8: 0xff, green8: 0x79, blue8: 0xc6),
        SwiftTerm.Color(red8: 0x8b, green8: 0xe9, blue8: 0xfd), SwiftTerm.Color(red8: 0xff, green8: 0xff, blue8: 0xff)
    ]

    private static let paperANSI: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0xee, green8: 0xee, blue8: 0xec), SwiftTerm.Color(red8: 0xcc, green8: 0x00, blue8: 0x00),
        SwiftTerm.Color(red8: 0x4e, green8: 0x9a, blue8: 0x06), SwiftTerm.Color(red8: 0xc4, green8: 0xa0, blue8: 0x00),
        SwiftTerm.Color(red8: 0x34, green8: 0x65, blue8: 0xa4), SwiftTerm.Color(red8: 0x75, green8: 0x50, blue8: 0x7b),
        SwiftTerm.Color(red8: 0x06, green8: 0x98, blue8: 0x9a), SwiftTerm.Color(red8: 0x2e, green8: 0x34, blue8: 0x36),
        SwiftTerm.Color(red8: 0xd3, green8: 0xd7, blue8: 0xcf), SwiftTerm.Color(red8: 0xef, green8: 0x29, blue8: 0x29),
        SwiftTerm.Color(red8: 0x8a, green8: 0xe2, blue8: 0x34), SwiftTerm.Color(red8: 0xfc, green8: 0xe9, blue8: 0x4f),
        SwiftTerm.Color(red8: 0x72, green8: 0x9f, blue8: 0xcf), SwiftTerm.Color(red8: 0xad, green8: 0x7f, blue8: 0xa8),
        SwiftTerm.Color(red8: 0x34, green8: 0xe2, blue8: 0xe2), SwiftTerm.Color(red8: 0x00, green8: 0x00, blue8: 0x00)
    ]
}

extension TerminalPalette {
    func applyBaseColors(to view: TerminalView) {
        view.nativeBackgroundColor = UIColor(background)
        view.nativeForegroundColor = UIColor(foreground)
        view.caretColor = UIColor(cursor)
        view.selectedTextBackgroundColor = UIColor(selection)
    }
}

extension TerminalFont {
    func apply(to view: TerminalView, size: CGFloat) {
        let normal = uiFont(size: size)
        let bold = boldUIFont(size: size)
        let italic: UIFont
        if let italicDescriptor = normal.fontDescriptor.withSymbolicTraits([.traitItalic]) {
            italic = UIFont(descriptor: italicDescriptor, size: size)
        } else {
            italic = normal
        }
        let boldItalic: UIFont
        if let boldItalicDescriptor = normal.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
            boldItalic = UIFont(descriptor: boldItalicDescriptor, size: size)
        } else {
            boldItalic = bold
        }
        view.setFonts(normal: normal, bold: bold, italic: italic, boldItalic: boldItalic)
    }
}
#endif
