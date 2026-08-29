import Foundation

/// One command the host can execute on the guest's behalf.
public struct HostCommand: Equatable, Sendable {
    /// The basename the guest shell resolves, e.g. `npm` or `cowsay`.
    public let name: String
    /// Which host lane runs it, from the dispatch manifest's vocabulary
    /// (`node-mobile`, `wasm3`, or the opener lane).
    public let handler: String
    /// For a CLI *discovered* in a runtime's global bin directory, the real
    /// script the runtime must execute. `nil` for a packaged runtime, which
    /// the lane knows how to start on its own.
    public let entryPath: String?

    public init(name: String, handler: String, entryPath: String? = nil) {
        self.name = name
        self.handler = handler
        self.entryPath = entryPath
    }
}

/// The set of commands the host can run — **discovered, not declared**.
///
/// The dispatch manifest names the packaged runtimes (`node`, `npm`, `npx`,
/// `wasm`) and the opener commands. It cannot name everything else, because
/// everything else is whatever the user has installed:
/// `npm install -g <anything>` drops a new executable into the Node global bin
/// directory, and that command has to become runnable from the guest shell
/// with no code change and no manifest edit.
///
/// Before this existed, the runnable set was exactly the manifest's fixed
/// list. `npm install -g cowsay` succeeded, `~/node/bin/cowsay` appeared, and
/// `cowsay` still reported `not found` — because no launcher was created, the
/// guest exec hook never proxied the name, and the host dispatcher had no case
/// for it. `claude` worked only because it was one of the hardcoded names.
public final class HostCommandRegistry {
    /// A directory to scan, and the lane that runs what is found in it.
    public struct DiscoverySource: Equatable, Sendable {
        public let directory: URL
        public let handler: String

        public init(directory: URL, handler: String) {
            self.directory = directory
            self.handler = handler
        }
    }

    private let manifest: GuestDispatchManifest
    private var sources: [DiscoverySource]
    private let lock = NSLock()
    private var discovered: [String: HostCommand] = [:]

    public init(manifest: GuestDispatchManifest, sources: [DiscoverySource] = []) {
        self.manifest = manifest
        self.sources = sources
    }

    /// Replace the directories that are scanned. The app supplies these from
    /// the runtime homes it owns; no command name is involved.
    public func setDiscoverySources(_ sources: [DiscoverySource]) {
        lock.lock()
        self.sources = sources
        lock.unlock()
        refresh()
    }

    /// Re-scan the discovery directories.
    ///
    /// Called at shell start and again whenever a host job finishes, because a
    /// job may have been the `npm install -g` that created the command the
    /// user is about to type. Returns `true` when the command set actually
    /// changed, so callers can skip the expensive follow-up work (writing
    /// launcher symlinks, rebuilding the guest dispatch table) on the common
    /// case where nothing was installed.
    @discardableResult
    public func refresh() -> Bool {
        lock.lock()
        let currentSources = sources
        lock.unlock()

        var found: [String: HostCommand] = [:]
        let fm = FileManager.default
        for source in currentSources {
            guard let entries = try? fm.contentsOfDirectory(
                at: source.directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard !name.isEmpty, !name.hasPrefix(".") else { continue }
                // A global bin entry is normally a symlink into the package's
                // own directory. Resolve it so the lane executes the real
                // script rather than a link the guest cannot follow.
                let resolved = entry.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                // A packaged runtime always wins: the manifest's own row for
                // `npm` must not be shadowed by a stray file of that name.
                guard manifest.hostHandler(for: name) == nil,
                      !manifest.isBrowserOpener(name) else { continue }
                found[name] = HostCommand(
                    name: name, handler: source.handler, entryPath: resolved.path
                )
            }
        }

        lock.lock()
        let changed = found != discovered
        discovered = found
        lock.unlock()
        return changed
    }

    /// Look up how to run a command, or `nil` when the host does not own it
    /// (the guest ELF default then applies).
    public func command(named name: String) -> HostCommand? {
        if manifest.isBrowserOpener(name) {
            return HostCommand(name: name, handler: HostCommandHandler.opener)
        }
        if let handler = manifest.hostHandler(for: name) {
            return HostCommand(name: name, handler: handler)
        }
        lock.lock()
        defer { lock.unlock() }
        return discovered[name]
    }

    /// Every basename that needs a guest launcher and a dispatch-table entry:
    /// the manifest's packaged names plus everything discovered on disk.
    public var launcherNames: [String] {
        lock.lock()
        let discoveredNames = discovered.keys
        lock.unlock()
        return Array(Set(manifest.launcherBasenames).union(discoveredNames)).sorted()
    }

    /// Snapshot of the discovered commands, for diagnostics.
    public var discoveredCommands: [HostCommand] {
        lock.lock()
        defer { lock.unlock() }
        return Array(discovered.values).sorted { $0.name < $1.name }
    }
}

/// Handler identifiers used by the manifest and the registry. `opener` is not
/// a manifest row — browser openers are their own list — so it is named here
/// to keep the dispatcher a single switch over handlers.
public enum HostCommandHandler {
    public static let opener = "opener"
    public static let nodeMobile = "node-mobile"
    public static let pythonEmbedded = "python-embedded"
    public static let wasm3 = "wasm3"
    /// The packaged CLI that owns its own installer and auth state. It is a
    /// distinct lane rather than a name the dispatcher compares against, so
    /// program-name policy stays in the manifest.
    public static let claudeCode = "claude-code"
}
