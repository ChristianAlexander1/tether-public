import SwiftUI
import TermXClaude
import TetherStorageCore

/// Shows what Tether is keeping on disk and lets the user reclaim it.
/// Everything listed lives inside the app's own sandbox — the folders the user picked
/// are never touched here.
struct StorageView: View {
    @StateObject private var model = StorageModel()
    @State private var pendingDeletion: StorageEntry?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total used").font(.headline)
                    Spacer()
                    Text(model.isMeasuring && model.total == nil ? "…" : StorageModel.format(model.total ?? 0))
                        .font(.headline.monospacedDigit())
                }
            } footer: {
                Text("Storage used by things installed inside Tether. Your workspace folders are not included — those are your own files.")
            }

            Section("Installed") {
                ForEach(model.entries) { entry in
                    StorageRow(entry: entry) { pendingDeletion = entry }
                }
                if model.entries.isEmpty && !model.isMeasuring {
                    Text("Nothing installed yet").foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    model.clearAllCaches()
                } label: {
                    Label("Clear all caches", systemImage: "trash")
                }
                .disabled(model.cacheTotal == 0)
            } footer: {
                Text("Removes package-manager caches only (\(StorageModel.format(model.cacheTotal))). Installed packages stay.")
            }
        }
        .navigationTitle("Storage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.measure() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isMeasuring)
            }
        }
        .task { model.measure() }
        .refreshable { model.measure() }
        .alert("Unable to remove item", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) { model.clear(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.removalWarning)
        }
    }
}

private struct StorageRow: View {
    let entry: StorageEntry
    let onRequestClear: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(StorageModel.format(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if entry.isRemovable {
                Button(role: .destructive) { onRequestClear() } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct StorageEntry: Identifiable {
    let id: String
    let name: String
    let detail: String
    let path: String
    let bytes: Int64
    let isRemovable: Bool
    let isCache: Bool
    let removalWarning: String
}

@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var entries: [StorageEntry] = []
    @Published private(set) var total: Int64?
    @Published private(set) var isMeasuring = false
    @Published var errorMessage: String?

    var cacheTotal: Int64 { entries.filter(\.isCache).reduce(0) { $0 + $1.bytes } }

    private var home: String { NSHomeDirectory() }
    private var documents: String { home + "/Documents" }

    private struct Candidate {
        let id: String, name: String, detail: String, path: String
        let removable: Bool, cache: Bool, warning: String
    }

    private var candidates: [Candidate] {
        [
            Candidate(id: "claude", name: "Claude Code", detail: "globally installed CLI and runtime dependencies",
                      path: ClaudeInstallation.installRoot(home: documents), removable: true, cache: false,
                      warning: "Uninstalls Claude Code and its private runtime dependencies. Your workspace files and Claude settings are preserved; running claude later installs the current release again."),
            Candidate(id: "linux", name: "Linux packages", detail: "Alpine guest — apk add",
                      path: documents + "/linux", removable: true, cache: false,
                      warning: "Removes the Alpine Linux guest (apk packages, clear/reset helpers, and node/npm/claude launchers). Open a new terminal afterward — Tether re-downloads Alpine and restores launchers automatically."),
            Candidate(id: "python", name: "Python packages", detail: "globally installed with pip",
                      path: documents + "/python", removable: true, cache: false,
                      warning: "Removes every package installed with pip. Python itself stays."),
            Candidate(id: "node", name: "Node packages", detail: "globally installed with npm -g",
                      path: documents + "/node", removable: true, cache: false,
                      warning: "Removes globally installed npm packages. Node itself stays. Open a new terminal if npm commands look broken."),
            Candidate(id: "npm-cache", name: "npm cache", detail: "safe to delete",
                      path: documents + "/.npm", removable: true, cache: true,
                      warning: "Only cached downloads are removed; packages keep working."),
            Candidate(id: "pip-cache", name: "pip cache", detail: "safe to delete",
                      path: documents + "/.cache/pip", removable: true, cache: true,
                      warning: "Only cached downloads are removed; packages keep working."),
            Candidate(id: "temporary", name: "Temporary files", detail: "safe to delete",
                      path: NSTemporaryDirectory(), removable: true, cache: true,
                      warning: "Removes scratch files. Nothing installed is affected."),
        ]
    }

    private var remeasureQueued = false

    func measure() {
        // A measure requested mid-flight (the refresh right after a delete) used to
        // be dropped, leaving stale sizes on screen. Queue it instead.
        guard !isMeasuring else { remeasureQueued = true; return }
        remeasureQueued = false
        isMeasuring = true
        let list = candidates
        Task.detached(priority: .utility) {
            var found: [StorageEntry] = []
            var sum: Int64 = 0
            for c in list {
                let size = Self.directorySize(c.path)
                guard size > 0 else { continue }
                sum += size
                found.append(StorageEntry(id: c.id, name: c.name, detail: c.detail, path: c.path,
                                          bytes: size, isRemovable: c.removable,
                                          isCache: c.cache, removalWarning: c.warning))
            }
            let sorted = found.sorted { $0.bytes > $1.bytes }
            let measuredTotal = sum
            await MainActor.run {
                self.entries = sorted
                self.total = measuredTotal
                self.isMeasuring = false
                if self.remeasureQueued { self.measure() }
            }
        }
    }

    func clear(_ entry: StorageEntry) {
        defer { measure() }

        // Areas the catalog manages go through it, so a delete cannot pull the
        // rootfs out from under a running shell. Cache-style entries that only
        // need emptying (and iOS's temporary directory, which must keep
        // existing) stay on the direct path.
        guard let areaID = Self.managedAreaID(for: entry.id) else {
            do {
                try Self.remove(entry.path, preservingDirectory: entry.isCache)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        let catalog = TetherStorage.shared.catalog
        do {
            let plan = try catalog.plan(delete: areaID)
            guard plan.blockedBy.isEmpty else {
                errorMessage = Self.blockedMessage(entry: entry, owners: plan.blockedBy)
                return
            }
            // Claude keeps state outside its install root, so its uninstaller
            // runs first; the catalog then removes what remains.
            if entry.id == "claude" {
                try ClaudeInstallation.uninstall(home: documents)
            }
            let actions = try catalog.execute(plan)
            apply(actions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Post-delete actions the catalog reports, applied to the live services.
    /// `markNeedsBootstrap` replaces the bare notification post: it says what
    /// must happen rather than hoping an observer is listening.
    private func apply(_ actions: [PostDeleteAction]) {
        for action in actions {
            switch action {
            case .markNeedsBootstrap:
                NotificationCenter.default.post(name: .tetherLinuxRootfsRemoved, object: nil)
            case .invalidateRuntime, .none:
                break
            }
        }
    }

    private static func managedAreaID(for entryID: String) -> ManagedAreaID? {
        switch entryID {
        case "linux": return .linuxRootfs
        case "node": return .nodeHome
        case "claude": return .claudeInstall
        case "python": return .pythonPackages
        default: return nil
        }
    }

    private static func blockedMessage(entry: StorageEntry, owners: [ActiveUseToken]) -> String {
        let who = owners.map(\.owner).joined(separator: ", ")
        return """
        \(entry.name) is in use by an open terminal session and was not deleted.

        Close the workspace, then try again. (Held by: \(who))
        """
    }

    func clearAllCaches() {
        for entry in entries where entry.isCache {
            do {
                try Self.remove(entry.path, preservingDirectory: true)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        measure()
    }

    /// Deletes `path`. Cache directories are emptied rather than removed: iOS
    /// expects NSTemporaryDirectory() to keep existing, and deleting it makes
    /// every later write into it fail.
    nonisolated static func remove(_ path: String, preservingDirectory: Bool) throws {
        let fm = FileManager.default
        guard preservingDirectory else {
            try fm.removeItem(atPath: path)
            return
        }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            try fm.removeItem(atPath: (path as NSString).appendingPathComponent(name))
        }
    }

    /// Sums the allocated size of every file below `path`. Returns 0 when absent.
    nonisolated static func directorySize(_ path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return Int64((attrs?[.size] as? UInt64) ?? 0)
        }
        guard let e = fm.enumerator(at: URL(fileURLWithPath: path),
                                    includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                    options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

