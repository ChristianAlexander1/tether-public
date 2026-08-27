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

    /// Basenames that need executable launcher entries in the guest rootfs.
    public var launcherBasenames: [String] {
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
        return GuestDispatchManifest(browserOpeners: [], hostRuntimes: [])
    }

    /// Push manifest rows into the Blink bridge (iOS only; no-op in stub builds).
    public func installIntoBlinkBridge() {
#if canImport(TermXBlinkBridge)
        termx_blink_dispatch_reset()
        for name in launcherBasenames {
            _ = name.withCString { termx_blink_dispatch_add($0) }
        }
#endif
    }
}

enum GuestRuntimeLauncherInstaller {
    static func install(names: [String], rootfs: URL) throws {
        let fm = FileManager.default
        let busybox = rootfs.appendingPathComponent("bin/busybox").path
        guard fm.fileExists(atPath: busybox) else { return }
        let destinationDirectory = rootfs.appendingPathComponent("usr/local/bin", isDirectory: true)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for name in names {
            let destination = destinationDirectory.appendingPathComponent(name).path
            if (try? fm.attributesOfItem(atPath: destination)) != nil {
                // Migrate only the exact BusyBox copies installed by older
                // builds. Never replace a command installed by the user.
                guard fm.contentsEqual(atPath: busybox, andPath: destination) else { continue }
                try fm.removeItem(atPath: destination)
            }
            try fm.createSymbolicLink(
                atPath: destination,
                withDestinationPath: "../../../bin/busybox"
            )
        }
    }
}

/// Standard busybox applets commonly expected on a Linux terminal (clear, etc.).
/// Only adds a symlink when the applet is not already on PATH — same as `apk add` would.
enum GuestBusyboxApplets {
    static let applets = ["clear"]

    static func installMissing(in rootfs: URL) throws {
        let fm = FileManager.default
        let busybox = rootfs.appendingPathComponent("bin/busybox").path
        guard fm.fileExists(atPath: busybox) else { return }
        let destinationDirectory = rootfs.appendingPathComponent("usr/local/bin", isDirectory: true)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for name in applets {
            if LinuxFallback.guestCommandPath(name: name, rootfs: rootfs) != nil { continue }
            let destination = destinationDirectory.appendingPathComponent(name).path
            try fm.createSymbolicLink(
                atPath: destination,
                withDestinationPath: "../../../bin/busybox"
            )
        }
    }
}
