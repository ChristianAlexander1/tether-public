import Foundation

#if canImport(TermXBlinkBridge)
import TermXBlinkBridge
#endif

/// Manifest-driven guest vs host exec dispatch (`GUEST-PLATFORM.md`, P5).
/// Default is always guest ELF; only manifest rows proxy to the host worker.
public struct GuestDispatchManifest: Codable, Equatable, Sendable {
    public struct HostRuntime: Codable, Equatable, Sendable {
        public let match: String
        public let name: String
        public let handler: String
    }

    public let `default`: String
    public let browserOpeners: [String]
    public let hostRuntimes: [HostRuntime]

    enum CodingKeys: String, CodingKey {
        case `default`
        case browserOpeners = "browser_openers"
        case hostRuntimes = "host_runtimes"
    }

    public init(
        default: String = "guest_elf",
        browserOpeners: [String],
        hostRuntimes: [HostRuntime]
    ) {
        self.default = `default`
        self.browserOpeners = browserOpeners
        self.hostRuntimes = hostRuntimes
    }

    /// Basenames that need busybox stubs under `/usr/local/bin` in the guest rootfs.
    public var stubBasenames: [String] {
        var names = Set(browserOpeners)
        for row in hostRuntimes where row.match == "basename" {
            names.insert(row.name)
        }
        return names.sorted()
    }

    public func isBrowserOpener(_ basename: String) -> Bool {
        browserOpeners.contains(basename)
    }

    public func hostHandler(for basename: String) -> String? {
        hostRuntimes.first { $0.match == "basename" && $0.name == basename }?.handler
    }

    public static func load(from data: Data) throws -> GuestDispatchManifest {
        try JSONDecoder().decode(GuestDispatchManifest.self, from: data)
    }

    public static func loadDefault() -> GuestDispatchManifest {
        if let url = Bundle.module.url(
            forResource: "tether_dispatch_manifest", withExtension: "json"
        ), let data = try? Data(contentsOf: url), let manifest = try? load(from: data) {
            return manifest
        }
        return GuestDispatchManifest(
            browserOpeners: ["open", "xdg-open"],
            hostRuntimes: [
                HostRuntime(match: "basename", name: "node", handler: "node-mobile"),
                HostRuntime(match: "basename", name: "npm", handler: "node-mobile"),
                HostRuntime(match: "basename", name: "npx", handler: "node-mobile"),
                HostRuntime(match: "basename", name: "claude", handler: "node-mobile"),
                HostRuntime(match: "basename", name: "wasm", handler: "wasm3"),
            ]
        )
    }

    /// Push manifest rows into the Blink bridge (iOS only; no-op in stub builds).
    public func installIntoBlinkBridge() {
#if canImport(TermXBlinkBridge)
        termx_blink_dispatch_reset()
        for name in stubBasenames {
            _ = name.withCString { termx_blink_dispatch_add($0) }
        }
#endif
    }
}
