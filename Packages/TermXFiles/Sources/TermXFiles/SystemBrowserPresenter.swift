#if os(iOS)
import SafariServices
import UIKit

/// Presents URLs inside the Tether app (Simulator/device), not on the Mac desktop.
enum SystemBrowserPresenter {
    private static var safariController: SFSafariViewController?
    private static var lastPresentedKey: String?
    private static var lastPresentedAt: Date?

    static func present(url: URL, kind: SystemOpen.URLKind) -> SystemOpen.Result {
        let normalized = SystemOpen.sanitizeURLString(url.absoluteString) ?? url
        let dedupeKey = SystemOpen.openAttemptKey(normalized)
        if let last = lastPresentedKey, last == dedupeKey,
           let at = lastPresentedAt, Date().timeIntervalSince(at) < 15 {
            SystemOpen.log("skip duplicate browser present for \(normalized.host ?? "url")")
            return .opened
        }
        lastPresentedKey = dedupeKey
        lastPresentedAt = Date()

        SystemOpen.log("open \(kind) \(normalized.absoluteString.prefix(120))")
        switch kind {
        case .guestLocalhost:
            return presentInAppSafari(normalized)
        case .hostLocalhost, .https, .oauthLogin:
            return presentInAppSafari(normalized)
        }
    }

    private static func presentInAppSafari(_ url: URL) -> SystemOpen.Result {
        guard let anchor = modalAnchor() else {
            SystemOpen.log("no view controller — falling back to UIApplication.shared.open")
            return fallbackExternal(url)
        }
        dismissTransientBrowsers(anchoredAt: anchor)
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .pageSheet
        safariController = safari
        anchor.present(safari, animated: true) {
            SystemOpen.log("in-app Safari presented for \(url.host ?? url.absoluteString)")
        }
        return .opened
    }

    /// Root view controller — never present from SFSafariViewController (crashes).
    private static func modalAnchor() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        return window?.rootViewController
    }

    private static func dismissTransientBrowsers(anchoredAt anchor: UIViewController) {
        safariController = nil
        if anchor.presentedViewController != nil {
            anchor.dismiss(animated: false)
        }
    }

    private static func fallbackExternal(_ url: URL) -> SystemOpen.Result {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return .opened
    }
}
#endif
