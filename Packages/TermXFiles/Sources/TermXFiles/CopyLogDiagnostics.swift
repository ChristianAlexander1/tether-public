import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Aggregates diagnostic sections for the toolbar **Copy log** button.
public final class CopyLogDiagnostics: @unchecked Sendable {
    public static let formatVersion = 3
    public static let shared = CopyLogDiagnostics()

    public typealias SectionProvider = @Sendable () -> String

    private struct Section {
        let name: String
        let provider: SectionProvider
    }

    private let lock = NSLock()
    private var sections: [Section] = []

    private init() {}

    public func registerSection(_ name: String, provider: @escaping SectionProvider) {
        lock.lock()
        defer { lock.unlock() }
        sections.removeAll { $0.name == name }
        sections.append(Section(name: name, provider: provider))
    }

    public static let browserChecklist = """
    Claude login expects (in Browser/open debug below):
      1. claude.openStub: yes (npm `open` package stub)
      2. which open -> /usr/bin/open OR node spawn open / spawn url-in-args
      3. open oauthLogin https://claude.com/…
      4. in-app Safari presented for claude.com
      Fallback: auto-open Claude OAuth when URL prints in terminal
    If step 1–3 missing but auto-open runs, complete login in Safari and paste the code.
    """

    public func diagnosticHeader(sessionLines: String) -> String {
        lock.lock()
        let registered = sections
        lock.unlock()

        var out = """
        === Tether diagnostic log ===
        format: \(Self.formatVersion)
        generated: \(ISO8601DateFormatter().string(from: Date()))

        """
        for section in registered {
            out += "=== \(section.name) ===\n"
            out += section.provider().trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n\n"
        }

        let openLog = SystemOpenDiagnostics.shared.snapshot()
        out += "=== Browser / open debug ===\n"
        if openLog.hasPrefix("(no browser") {
            out += Self.browserChecklist + "\n"
        }
        out += openLog + "\n\n"

        out += "=== Terminal output ===\n"
        out += sessionLines.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n\n=== end ===\n"
        return out
    }

    public static func appAndDeviceSnapshot() -> String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let id = bundle.bundleIdentifier ?? "?"
        var lines = [
            "bundle: \(id)",
            "version: \(short) (build \(build))",
        ]
        #if os(iOS)
        lines.append("device: \(UIDevice.current.model)")
        lines.append("ios: \(UIDevice.current.systemVersion)")
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"], !sim.isEmpty {
            lines.append("simulator: \(sim)")
        }
        #elseif os(macOS)
        lines.append("platform: macOS")
        #endif
        #if DEBUG
        lines.append("configuration: DEBUG")
        #else
        lines.append("configuration: RELEASE")
        #endif
        return lines.joined(separator: "\n")
    }
}
