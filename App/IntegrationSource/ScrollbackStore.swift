import Foundation
import TetherSessionCore

/// Persists one `ScrollbackSnapshot` per workspace inside the app container,
/// so a session's recent output survives a force-quit.
///
/// Every read path is failure-tolerant on purpose: a snapshot is a convenience,
/// never a correctness requirement. A truncated, corrupt, or version-mismatched
/// file is discarded and the session starts clean rather than failing to open.
public final class ScrollbackStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("scrollback", isDirectory: true)
        }
    }

    private func url(for workspaceID: String) -> URL {
        // Workspace ids are UUIDs, but confine the name anyway: a path
        // separator here would write outside the container.
        let safe = workspaceID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        return directory.appendingPathComponent("\(safe).snapshot")
    }

    /// Persist a snapshot, replacing any previous one for this workspace.
    public func save(_ snapshot: ScrollbackSnapshot, for workspaceID: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try snapshot.serialized().write(to: url(for: workspaceID), options: .atomic)
        } catch {
            // A failed snapshot must never affect the session.
        }
    }

    /// Load and immediately consume the snapshot: a restore is a one-shot, so a
    /// stale file cannot be replayed onto every future session.
    public func take(for workspaceID: String) -> ScrollbackSnapshot? {
        let path = url(for: workspaceID)
        defer { try? fileManager.removeItem(at: path) }
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? ScrollbackSnapshot.deserialize(data)
    }

    public func discard(for workspaceID: String) {
        try? fileManager.removeItem(at: url(for: workspaceID))
    }
}
