import SwiftUI

/// Shows what Tether is keeping on disk and lets the user reclaim it.
/// Everything listed lives inside the app's own sandbox — the folders the user picked
/// are never touched here.
struct StorageView: View {
    @StateObject private var model = StorageModel()

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
                    StorageRow(entry: entry) { model.clear(entry) }
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
    }
}

private struct StorageRow: View {
    let entry: StorageEntry
    let onClear: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(StorageModel.format(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if entry.isRemovable {
                Button(role: .destructive) { confirming = true } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .confirmationDialog("Delete \(entry.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.removalWarning)
        }
    }
}

struct StorageEntry: Identifiable {
    let id = UUID()
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

    var cacheTotal: Int64 { entries.filter(\.isCache).reduce(0) { $0 + $1.bytes } }

    private var home: String { NSHomeDirectory() }
    private var documents: String { home + "/Documents" }

    private struct Candidate {
        let name: String, detail: String, path: String
        let removable: Bool, cache: Bool, warning: String
    }

    private var candidates: [Candidate] {
        [
            Candidate(name: "Linux packages", detail: "Alpine guest — apk add",
                      path: documents + "/linux", removable: true, cache: false,
                      warning: "Removes every package installed with apk, including git. Tether re-downloads a fresh Alpine base the next time you use the linux command."),
            Candidate(name: "Python packages", detail: "installed with pip",
                      path: home + "/python", removable: true, cache: false,
                      warning: "Removes every package installed with pip. Python itself stays."),
            Candidate(name: "Node packages", detail: "installed with npm -g",
                      path: home + "/node", removable: true, cache: false,
                      warning: "Removes globally installed npm packages. Node itself stays."),
            Candidate(name: "npm cache", detail: "safe to delete",
                      path: home + "/.npm", removable: true, cache: true,
                      warning: "Only cached downloads are removed; packages keep working."),
            Candidate(name: "pip cache", detail: "safe to delete",
                      path: home + "/.cache/pip", removable: true, cache: true,
                      warning: "Only cached downloads are removed; packages keep working."),
            Candidate(name: "Temporary files", detail: "safe to delete",
                      path: NSTemporaryDirectory(), removable: true, cache: true,
                      warning: "Removes scratch files. Nothing installed is affected."),
        ]
    }

    func measure() {
        guard !isMeasuring else { return }
        isMeasuring = true
        let list = candidates
        Task.detached(priority: .utility) {
            var found: [StorageEntry] = []
            var sum: Int64 = 0
            for c in list {
                let size = Self.directorySize(c.path)
                guard size > 0 else { continue }
                sum += size
                found.append(StorageEntry(name: c.name, detail: c.detail, path: c.path,
                                          bytes: size, isRemovable: c.removable,
                                          isCache: c.cache, removalWarning: c.warning))
            }
            let sorted = found.sorted { $0.bytes > $1.bytes }
            await MainActor.run {
                self.entries = sorted
                self.total = sum
                self.isMeasuring = false
            }
        }
    }

    func clear(_ entry: StorageEntry) {
        try? FileManager.default.removeItem(atPath: entry.path)
        measure()
    }

    func clearAllCaches() {
        for entry in entries where entry.isCache {
            try? FileManager.default.removeItem(atPath: entry.path)
        }
        measure()
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
