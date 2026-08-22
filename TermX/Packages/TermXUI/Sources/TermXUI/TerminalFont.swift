import Foundation
#if canImport(UIKit)
import UIKit
import CoreText
#endif

/// Bundled SIL-OFL monospace fonts shipped with TermXUI.
public enum TerminalFont: String, CaseIterable, Identifiable, Sendable {
    case jetBrainsMono
    case systemMono

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .jetBrainsMono: return "JetBrains Mono"
        case .systemMono: return "System Mono"
        }
    }

#if canImport(UIKit)
    public func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .jetBrainsMono:
            if let regular = loadBundledFont(named: "JetBrainsMono-Regular", size: size) {
                return regular
            }
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .systemMono:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    public func boldUIFont(size: CGFloat) -> UIFont {
        switch self {
        case .jetBrainsMono:
            if let bold = loadBundledFont(named: "JetBrainsMono-Bold", size: size) {
                return bold
            }
            return UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        case .systemMono:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
    }

    private func loadBundledFont(named name: String, size: CGFloat) -> UIFont? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ttf")
            ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
            return nil
        }
        guard let dataProvider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(dataProvider),
              let postScriptName = cgFont.postScriptName as String? else {
            return nil
        }
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) == false {
            registrationError?.release()
        }
        return UIFont(name: postScriptName, size: size)
    }
#endif
}
