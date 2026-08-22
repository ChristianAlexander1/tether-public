import SwiftUI

/// Browses the folder the terminal is currently working in, so you can see what your
/// commands are creating without leaving the app.
struct WorkspaceFilesView: View {
    let rootPath: String
    let title: String

    @State private var path: String
    @State private var items: [FileItem] = []
    @State private var totalBytes: Int64 = 0
    @State private var loading = true

    init(rootPath: String, title: String) {
        self.rootPath = rootPath
        self.title = title
        _path = State(initialValue: rootPath)
    }

    var body: some View {
        List {
            if path != rootPath {
                Button {
                    path = (path as NSString).deletingLastPathComponent
                    load()
                } label: {
                    Label("..", systemImage: "arrow.turn.left.up")
                }
            }

            ForEach(items) { item in
                if item.isDirectory {
                    Button {
                        path = item.path
                        load()
                    } label: { row(item) }
                } else {
                    row(item)
                }
            }

            if items.isEmpty && !loading {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(displayPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("\(items.count) items · \(StorageModel.format(totalBytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .task { load() }
        .refreshable { load() }
    }

    private var displayPath: String {
        let name = (rootPath as NSString).lastPathComponent
        guard path != rootPath else { return name }
        return name + path.dropFirst(rootPath.count)
    }

    private func row(_ item: FileItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.modified, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.isDirectory {
                Text(StorageModel.format(item.bytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        loading = true
        let current = path
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: current)) ?? []
            var found: [FileItem] = []
            var sum: Int64 = 0
            for name in names {
                let full = (current as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                let attrs = try? fm.attributesOfItem(atPath: full)
                let size = Int64((attrs?[.size] as? UInt64) ?? 0)
                if !isDir.boolValue { sum += size }
                found.append(FileItem(name: name, path: full, isDirectory: isDir.boolValue,
                                      bytes: size,
                                      modified: (attrs?[.modificationDate] as? Date) ?? .distantPast))
            }
            // Folders first, then files, each alphabetically.
            let sorted = found.sorted {
                $0.isDirectory == $1.isDirectory
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.isDirectory
            }
            await MainActor.run {
                self.items = sorted
                self.totalBytes = sum
                self.loading = false
            }
        }
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let bytes: Int64
    let modified: Date
}
