import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

// Security-scoped bookmark flags exist only on macOS; iOS bookmarks carry the scope implicitly.
#if os(macOS)
let workspaceBookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
let workspaceBookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
let workspaceBookmarkCreationOptions: URL.BookmarkCreationOptions = []
let workspaceBookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
#endif

// MARK: - Public workspace API types

public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let mountPath: String
    public init(id: UUID = UUID(), name: String, mountPath: String) { self.id = id; self.name = name; self.mountPath = mountPath }
}

public protocol WorkspaceProviding: AnyObject {
    func addWorkspace() async throws -> Workspace
    func restoreAll() -> [Workspace]
    func beginAccess(_ w: Workspace) throws -> String
    func endAccess(_ w: Workspace)
    func resolve(virtualPath: String) -> String?
}

public enum WorkspaceError: Error, Equatable {
    case invalidVirtualPath
    case missingBookmark
    case pickerUnavailable
    case accessDenied
    case iCloudDownloadFailed
    case bookmarkStale
}

// MARK: - Internal Bookmark Model

struct BookmarkRecord: Codable {
    let workspace: Workspace
    var data: Data
    var lastAccessed: Date
    var accessCount: Int

    init(workspace: Workspace, data: Data) {
        self.workspace = workspace
        self.data = data
        self.lastAccessed = Date()
        self.accessCount = 0
    }
}

// MARK: - WorkspaceStore

public final class WorkspaceStore: NSObject, WorkspaceProviding {
    private let defaults: UserDefaults
    private let key = "termx.workspace.bookmarks"
    private var records: [UUID: BookmarkRecord] = [:]
    private var transientRecordIDs: Set<UUID> = []
    private var activeCounts: [UUID: Int] = [:]
    private var realPaths: [UUID: String] = [:]
    private let lock = NSLock()
#if canImport(UIKit)
    private var continuation: CheckedContinuation<URL, Error>?
#endif

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        load()
    }

    // MARK: - Frozen API: restoreAll

    public func restoreAll() -> [Workspace] {
        lock.lock()
        defer { lock.unlock() }
        return records.values
            .map(\.workspace)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Frozen API: addWorkspace

    public func addWorkspace() async throws -> Workspace {
#if canImport(UIKit)
        // Picker delegate starts security-scoped access before returning the URL.
        let url = try await pickFolder()
        defer { url.stopAccessingSecurityScopedResource() }
        let data = try url.bookmarkData(
            options: workspaceBookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let name = url.lastPathComponent.isEmpty ? "Workspace" : url.lastPathComponent
        let workspace = Workspace(
            name: name,
            mountPath: "/workspaces/\(sanitize(name))"
        )
        lock.lock()
        records[workspace.id] = BookmarkRecord(workspace: workspace, data: data)
        lock.unlock()
        persist()
        return workspace
#else
        throw WorkspaceError.pickerUnavailable
#endif
    }

    // MARK: - Frozen API: beginAccess

    public func beginAccess(_ w: Workspace) throws -> String {
        lock.lock()
        guard var record = records[w.id] else {
            lock.unlock()
            throw WorkspaceError.missingBookmark
        }

        // If already accessed, increment count and return cached path
        if let count = activeCounts[w.id], count > 0, let path = realPaths[w.id] {
            activeCounts[w.id] = count + 1
            record.lastAccessed = Date()
            record.accessCount += 1
            records[w.id] = record
            lock.unlock()
            persist()
            return path
        }
        lock.unlock()

#if canImport(UIKit)
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: record.data,
                options: workspaceBookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw WorkspaceError.missingBookmark
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw WorkspaceError.accessDenied
        }

        // Existence must be checked after opening the security scope. Checking
        // an external Files/iCloud URL first can look like a missing folder even
        // when the bookmark is valid but the sandbox has not granted access yet.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            url.stopAccessingSecurityScopedResource()
            throw WorkspaceError.missingBookmark
        }

        // Refresh stale bookmark
        if stale {
            do {
                let newData = try url.bookmarkData(
                    options: workspaceBookmarkCreationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                lock.lock()
                record.data = newData
                records[w.id] = record
                lock.unlock()
            } catch {
                // Stale but still accessible — continue with old bookmark
            }
        }

        lock.lock()
        activeCounts[w.id, default: 0] += 1
        realPaths[w.id] = url.path
        record.lastAccessed = Date()
        record.accessCount += 1
        records[w.id] = record
        lock.unlock()
        persist()
        return url.path
#else
        throw WorkspaceError.pickerUnavailable
#endif
    }

    /// Whether the folder behind an *already accessed* workspace still exists
    /// and is reachable.
    ///
    /// A security-scoped bookmark can go stale while the app is suspended —
    /// the user deletes the folder in Files, or iCloud evicts it. Checking the
    /// resolved path is what lets the session report "workspace unavailable"
    /// instead of failing later with an unexplained I/O error.
    public func isStillAvailable(_ w: Workspace) -> Bool {
        lock.lock()
        let path = realPaths[w.id]
        lock.unlock()
        guard let path else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    // MARK: - Frozen API: endAccess

    public func endAccess(_ w: Workspace) {
        lock.lock()
        guard let count = activeCounts[w.id], count > 0 else {
            lock.unlock()
            return
        }
#if canImport(UIKit)
        if count == 1 {
            if let path = realPaths[w.id] {
                let url = URL(fileURLWithPath: path)
                url.stopAccessingSecurityScopedResource()
            }
            activeCounts.removeValue(forKey: w.id)
            realPaths.removeValue(forKey: w.id)
        } else {
            activeCounts[w.id] = count - 1
        }
#else
        if count == 1 {
            activeCounts.removeValue(forKey: w.id)
            realPaths.removeValue(forKey: w.id)
        } else {
            activeCounts[w.id] = count - 1
        }
#endif
        lock.unlock()
    }

    // MARK: - Frozen API: resolve

    public func resolve(virtualPath: String) -> String? {
        let parts = virtualPath.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "workspaces" else { return nil }
        let workspaceName = parts[1]

        lock.lock()
        let allWorkspaces = records.values.map(\.workspace)
        let matchedWorkspace = allWorkspaces.first { $0.mountPath == "/workspaces/\(workspaceName)" }
        guard let workspace = matchedWorkspace, let root = realPaths[workspace.id] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let relative = parts.dropFirst(2).joined(separator: "/")
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL

        // Traversal protection: candidate must be at or under root
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootURL.path + "/") else {
            return nil
        }

        return candidate.path
    }

    // MARK: - Extended API: removeWorkspace

    public func removeWorkspace(_ w: Workspace) {
        // End any active access first
        endAccess(w)

        lock.lock()
        records.removeValue(forKey: w.id)
        transientRecordIDs.remove(w.id)
        activeCounts.removeValue(forKey: w.id)
        realPaths.removeValue(forKey: w.id)
        lock.unlock()
        persist()
    }

    // MARK: - Extended API: recentWorkspaces (ordered by last access)

    public func recentWorkspaces() -> [Workspace] {
        lock.lock()
        defer { lock.unlock() }
        return records.values
            .sorted { $0.lastAccessed > $1.lastAccessed }
            .map(\.workspace)
    }

    // MARK: - Extended API: activeAccessCount (for leak detection)

    public func activeAccessCount(for w: Workspace) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCounts[w.id] ?? 0
    }

    // MARK: - Extended API: totalActiveAccessCount

    public var totalActiveAccessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCounts.values.reduce(0, +)
    }

    // MARK: - Extended API: iCloud eviction handling

    /// Downloads an iCloud-evicted file before access.
    /// Call this before opening any file that may be stored in iCloud Drive.
    public func downloadIfNeeded(at url: URL) async throws {
        let fm = FileManager.default
        let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

        if let status = resourceValues.ubiquitousItemDownloadingStatus,
           status != .current {
            try fm.startDownloadingUbiquitousItem(at: url)

            // Poll until downloaded (with timeout)
            let deadline = Date().addingTimeInterval(60) // 60s timeout
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                let updated = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if updated.ubiquitousItemDownloadingStatus == .current {
                    return
                }
            }
            throw WorkspaceError.iCloudDownloadFailed
        }
    }

    // MARK: - Extended API: refreshStaleBookmarks

    /// Returns workspaces whose bookmarks are stale and need user re-pick.
    public func staleWorkspaceIDs() -> [UUID] {
#if canImport(UIKit)
        lock.lock()
        let allRecords = Array(records.values)
        lock.unlock()

        var staleIDs: [UUID] = []
        for record in allRecords {
            var isStale = false
            do {
                _ = try URL(
                    resolvingBookmarkData: record.data,
                    options: workspaceBookmarkResolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                staleIDs.append(record.workspace.id)
                continue
            }
            if isStale {
                staleIDs.append(record.workspace.id)
            }
        }
        return staleIDs
#else
        return []
#endif
    }

    // MARK: - Internal utilities

    internal func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Unit test support (macOS CI; no security-scoped URLs)

    /// Registers a workspace backed by a normal directory for unit tests and
    /// DEBUG-only simulator automation (never used for user folders in release).
    public func registerLocalWorkspaceForTesting(
        _ workspace: Workspace,
        rootURL: URL,
        persisted: Bool = true
    ) throws {
        let data = try rootURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        lock.lock()
        records[workspace.id] = BookmarkRecord(workspace: workspace, data: data)
        if persisted {
            transientRecordIDs.remove(workspace.id)
        } else {
            transientRecordIDs.insert(workspace.id)
        }
        lock.unlock()
        persist()
    }

    /// Removes DEBUG/test registrations that point at the app's own local
    /// Documents directory. A real external folder with the same display name
    /// is preserved because the resolved bookmark target must match exactly.
    public func removeLocalWorkspaceRegistrations(rootURL: URL) {
        let target = rootURL.standardizedFileURL.path
        lock.lock()
        let snapshot = records
        lock.unlock()

        let matchingIDs = snapshot.compactMap { id, record -> UUID? in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.standardizedFileURL.path == target else { return nil }
            return id
        }
        guard !matchingIDs.isEmpty else { return }

        lock.lock()
        for id in matchingIDs {
            records.removeValue(forKey: id)
            transientRecordIDs.remove(id)
            activeCounts.removeValue(forKey: id)
            realPaths.removeValue(forKey: id)
        }
        lock.unlock()
        persist()
    }

    /// Activates access for a locally registered workspace (ref-count path only).
    public func beginLocalAccessForTesting(_ w: Workspace) throws -> String {
        lock.lock()
        guard var record = records[w.id] else {
            lock.unlock()
            throw WorkspaceError.missingBookmark
        }

        if let count = activeCounts[w.id], count > 0, let path = realPaths[w.id] {
            activeCounts[w.id] = count + 1
            record.lastAccessed = Date()
            record.accessCount += 1
            records[w.id] = record
            lock.unlock()
            persist()
            return path
        }
        lock.unlock()

        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: record.data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw WorkspaceError.missingBookmark
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.missingBookmark
        }

        lock.lock()
        activeCounts[w.id, default: 0] += 1
        realPaths[w.id] = url.standardizedFileURL.path
        record.lastAccessed = Date()
        record.accessCount += 1
        records[w.id] = record
        lock.unlock()
        persist()
        return url.standardizedFileURL.path
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([BookmarkRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: values.map { ($0.workspace.id, $0) })
    }

    private func persist() {
        lock.lock()
        let values = records.compactMap { id, record in
            transientRecordIDs.contains(id) ? nil : record
        }
        lock.unlock()
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: key)
        }
    }

#if canImport(UIKit)
    @MainActor
    private func pickFolder() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [UTType.folder],
                asCopy: false
            )
            picker.allowsMultipleSelection = false
            picker.delegate = self
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
                    ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.keyWindow?.rootViewController else {
                continuation.resume(throwing: WorkspaceError.pickerUnavailable)
                return
            }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(picker, animated: true)
        }
    }
#endif
}

// MARK: - UIDocumentPickerDelegate

#if canImport(UIKit)
extension WorkspaceStore: UIDocumentPickerDelegate {
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            continuation?.resume(throwing: WorkspaceError.pickerUnavailable)
            continuation = nil
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            continuation?.resume(throwing: WorkspaceError.accessDenied)
            continuation = nil
            return
        }
        continuation?.resume(returning: url)
        continuation = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
#endif
