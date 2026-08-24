import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Platform `open` / `xdg-open` for any guest or host process.
///
/// iOS has no `/usr/bin/open`. Any CLI that expects desktop openers gets the
/// same behavior:
/// - `http(s)://…` → system browser
/// - local file / directory → QuickLook / share sheet when a presenter exists,
///   otherwise the OS default handler as a best-effort fallback
public enum SystemOpen {
    /// Commands that mean “open this resource with the OS default handler”.
    public static let openerCommands: Set<String> = [
        "open", "xdg-open", "gnome-open", "kde-open",
        "sensible-browser", "wslview",
    ]

    /// Where the open request originated — guest Alpine localhost ≠ iOS localhost.
    public enum OpenOrigin: Equatable, Sendable {
        /// `xdg-open` from the Blink shell (python http.server, etc.).
        case guestLinux
        /// `open`/`xdg-open` from embedded Node (Claude OAuth callback listener).
        case hostRuntime
    }

    public enum URLKind: Equatable, Sendable {
        case guestLocalhost
        case hostLocalhost
        case oauthLogin
        case https
    }

    public enum Target: Equatable {
        case url(URL)
        case path(String)
    }

    public enum Result: Equatable {
        case opened
        case unsupported
        case failed(String)
    }

    public enum GuestFetchOutcome: Sendable {
        case success(body: Data, httpStatus: Int)
        case failure(String)
    }

    /// Fetches a page from guest 127.0.0.1 (curl inside Alpine). Set by the app shell.
    public static var guestLocalhostFetcher: (@Sendable (URL) async -> GuestFetchOutcome)?

    /// Optional application-provided debug hook. Structured diagnostics are
    /// always recorded independently by `SystemOpenDiagnostics`.
    public static var openLogger: (@Sendable (String) -> Void)?

    public static func log(_ message: String) {
        SystemOpenDiagnostics.shared.record(message)
        openLogger?(message)
    }

    /// Clean a URL supplied by a command (strip control characters and repair
    /// accidental double-encoding without depending on a particular service).
    public static func sanitizeURLString(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        while let last = s.last, ",.;)]}".contains(last) { s.removeLast() }
        guard var components = URLComponents(string: s) else { return URL(string: s) }
        if let query = components.percentEncodedQuery, query.contains("%25") {
            var decoded = query
            for _ in 0..<2 {
                if let once = decoded.removingPercentEncoding { decoded = once }
            }
            components.percentEncodedQuery = decoded.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            )
        }
        return components.url ?? URL(string: s)
    }

    /// Stable key for suppressing duplicate presentations of the same target.
    public static func openAttemptKey(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "state" })?.value
            ?? url.absoluteString
    }

    /// Resolve what `command` + `arguments` are asking to open.
    /// Returns `nil` when this is not an opener request (caller should spawn normally).
    public static func resolve(command: String, arguments: [String]) -> Target? {
        let base = (command as NSString).lastPathComponent.lowercased()

        if openerCommands.contains(base) {
            return target(fromArguments: arguments)
        }

        // `gio open <resource>`
        if base == "gio", arguments.first == "open" {
            return target(fromArguments: Array(arguments.dropFirst()))
        }

        let shells: Set = ["sh", "bash", "zsh", "dash"]
        if shells.contains(base), arguments.first == "-c", arguments.count >= 2 {
            return target(fromShellCommand: arguments[1])
        }
        return nil
    }

    /// Open a resolved target.
    @discardableResult
    public static func open(_ target: Target, origin: OpenOrigin = .guestLinux) -> Result {
        switch target {
        case .url(let url):
            return openURL(url, origin: origin)
        case .path(let path):
            return openPath(path)
        }
    }

    public static func classifyURL(_ url: URL, origin: OpenOrigin) -> URLKind {
        if isLoopback(url) {
            return origin == .guestLinux ? .guestLocalhost : .hostLocalhost
        }
        if isOAuthLoginURL(url) { return .oauthLogin }
        return .https
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    public static func isOAuthLoginURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("/oauth") || path.contains("/authorize")
            || path.contains("/signin") || path.contains("/login") {
            return true
        }
        let queryNames = Set(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.map { $0.name.lowercased() } ?? []
        )
        return queryNames.contains("client_id")
            && (queryNames.contains("redirect_uri") || queryNames.contains("response_type"))
    }

    /// Convenience: if `command`/`arguments` is an opener request, handle it and
    /// return true; otherwise return false so the caller can spawn normally.
    @discardableResult
    public static func handleIfOpener(command: String, arguments: [String]) -> Bool {
        guard let target = resolve(command: command, arguments: arguments) else {
            return false
        }
        return open(target) == .opened
    }

    // MARK: - Resolve helpers

    private static func target(fromArguments args: [String]) -> Target? {
        for arg in args {
            if arg.hasPrefix("-") { continue } // skip flags like `open -a Safari`
            if let url = URL(string: arg), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return .url(url)
            }
            if !arg.isEmpty {
                return .path(arg)
            }
        }
        return nil
    }

    private static func target(fromShellCommand command: String) -> Target? {
        let lowered = command.lowercased()
        let mentionsOpener = openerCommands.contains { name in
            lowered.contains(name)
        } || lowered.contains("gio open")
        guard mentionsOpener else { return nil }

        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#),
           let match = regex.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)
           ),
           let range = Range(match.range, in: command),
           let url = URL(string: String(command[range])) {
            return .url(url)
        }

        if let regex = try? NSRegularExpression(
            pattern: #"(?:open|xdg-open|gnome-open|kde-open|sensible-browser|wslview)\s+(?:'([^']+)'|"([^"]+)"|(\S+))"#
        ),
           let match = regex.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)
           ) {
            for i in 1...3 {
                if let r = Range(match.range(at: i), in: command), !r.isEmpty {
                    let value = String(command[r])
                    if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        return .url(url)
                    }
                    return .path(value)
                }
            }
        }
        return nil
    }

    // MARK: - Open helpers

    private static func openURL(_ url: URL, origin: OpenOrigin) -> Result {
#if os(iOS)
        let kind = classifyURL(url, origin: origin)
        let present = {
            _ = SystemBrowserPresenter.present(url: url, kind: kind)
        }
        // Never block the Node IPC thread on main.sync — Claude waits on spawn and
        // a deadlock here surfaces as "Browser didn't open?".
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
        return .opened
#elseif os(macOS)
        let ok = NSWorkspace.shared.open(url)
        return ok ? .opened : .failed("NSWorkspace.open failed")
#else
        return .failed("no system URL opener on this platform")
#endif
    }

    private static func openPath(_ path: String) -> Result {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return .failed("no such file: \(path)")
        }
        let url = URL(fileURLWithPath: expanded)

#if os(iOS)
        // Presentation is asynchronous just like URL opening. Waiting on a
        // semaphore here deadlocks when `open` is invoked from the main thread.
        Task { @MainActor in
                if let presenter = keyPresenter() {
                    QuickLookHelper.handleOpenCommand(path: expanded, from: presenter)
                } else {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
        }
        return .opened
#elseif os(macOS)
        let ok = NSWorkspace.shared.open(url)
        return ok ? .opened : .failed("NSWorkspace.open failed")
#else
        return .failed("no system path opener on this platform")
#endif
    }

#if os(iOS)
    @MainActor
    private static func keyPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
#endif
}
