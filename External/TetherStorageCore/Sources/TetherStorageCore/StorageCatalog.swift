import Foundation

/// Coordinates app-owned storage areas, deletion plans, and active-use leases.
/// The catalog never accepts an absolute or traversing path for an operation.
public final class StorageCatalog {
    private let areasByID: [ManagedAreaID: ManagedArea]
    private let fileSystem: StorageFileSystem
    private let lock = NSLock()

    // Counts intentionally balance repeated lifecycle acquire/release calls.
    // A token is still reported only once while its count is nonzero.
    private var activeUseCounts: [ManagedAreaID: [ActiveUseToken: Int]] = [:]
    private var recordedNoOpReleases: [(ManagedAreaID, ActiveUseToken)] = []

    public init(areas: [ManagedArea], fileSystem: StorageFileSystem) {
        var indexed: [ManagedAreaID: ManagedArea] = [:]
        for area in areas where indexed[area.id] == nil {
            // Keeping the first definition makes duplicate input deterministic.
            indexed[area.id] = area
        }
        self.areasByID = indexed
        self.fileSystem = fileSystem
    }

    /// Acquires one balanced lease. Repeated acquisition of the same token does
    /// not duplicate it in blockers, but each acquisition needs a release.
    public func acquire(_ token: ActiveUseToken, on area: ManagedAreaID) {
        guard areasByID[area] != nil else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        var counts = activeUseCounts[area] ?? [:]
        let current = counts[token] ?? 0
        let (next, overflow) = current.addingReportingOverflow(1)
        counts[token] = overflow ? Int.max : next
        activeUseCounts[area] = counts
    }

    /// Releases one balanced lease. An unmatched release is retained as an
    /// internal no-op record and cannot remove another owner's lease.
    public func release(_ token: ActiveUseToken, from area: ManagedAreaID) {
        guard areasByID[area] != nil else {
            lock.lock()
            recordedNoOpReleases.append((area, token))
            lock.unlock()
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard var counts = activeUseCounts[area], let current = counts[token] else {
            recordedNoOpReleases.append((area, token))
            return
        }

        if current > 1 {
            counts[token] = current - 1
            activeUseCounts[area] = counts
        } else {
            counts.removeValue(forKey: token)
            if counts.isEmpty {
                activeUseCounts.removeValue(forKey: area)
            } else {
                activeUseCounts[area] = counts
            }
        }
    }

    public func plan(delete area: ManagedAreaID) throws -> DeletePlan {
        guard let managedArea = areasByID[area] else {
            throw StorageError.unknownArea
        }
        guard managedArea.deletable else {
            throw StorageError.notDeletable
        }
        guard let path = PathSupport.safeManagedRelativePath(managedArea.relativePath) else {
            throw StorageError.io("invalid managed area path: \(managedArea.relativePath)")
        }

        let blockers = currentBlockers(for: area)
        let actions = postDeleteActions(for: managedArea)

        guard fileSystem.exists(path) else {
            return DeletePlan(
                area: area,
                paths: [],
                estimatedBytes: 0,
                blockedBy: blockers,
                postActions: actions
            )
        }

        do {
            return DeletePlan(
                area: area,
                paths: [path],
                estimatedBytes: try fileSystem.sizeOfTree(path),
                blockedBy: blockers,
                postActions: actions
            )
        } catch {
            throw StorageError.io("sizeOfTree failed for '\(path)': \(String(describing: error))")
        }
    }

    /// Executes a preflight plan. The lease lock is held through deletion so a
    /// lifecycle acquisition cannot interleave after the guard check and while
    /// an area is being removed.
    public func execute(_ plan: DeletePlan) throws -> [PostDeleteAction] {
        guard let managedArea = areasByID[plan.area] else {
            throw StorageError.unknownArea
        }
        guard managedArea.deletable else {
            throw StorageError.notDeletable
        }
        guard let areaPath = PathSupport.safeManagedRelativePath(managedArea.relativePath) else {
            throw StorageError.io("invalid managed area path: \(managedArea.relativePath)")
        }
        for path in plan.paths where !PathSupport.path(path, isContainedIn: areaPath) {
            throw StorageError.io(
                "invalid delete plan path '\(path)'; successfully removed paths: []; remaining paths: \(plan.paths)"
            )
        }

        lock.lock()
        defer { lock.unlock() }

        let blockers = sortedBlockersLocked(for: plan.area)
        guard blockers.isEmpty else {
            throw StorageError.blocked(blockers)
        }

        var removed: [String] = []
        for (index, path) in plan.paths.enumerated() {
            do {
                try fileSystem.removeTree(path)
                removed.append(path)
            } catch {
                let remaining = Array(plan.paths[index...])
                let message = [
                    "removeTree failed for '\(path)': \(String(describing: error))",
                    "successfully removed paths: \(removed)",
                    "remaining paths: \(remaining)"
                ].joined(separator: "; ")
                throw StorageError.io(message)
            }
        }

        return plan.postActions
    }

    public func integrityReport(for area: ManagedAreaID) -> IntegrityReport {
        guard let managedArea = areasByID[area],
              let areaPath = PathSupport.safeManagedRelativePath(managedArea.relativePath) else {
            return IntegrityReport(
                area: area,
                present: false,
                missingMarkers: [],
                suspectPaths: []
            )
        }

        let present = fileSystem.exists(areaPath) && fileSystem.isDirectory(areaPath)
        let missingMarkers = managedArea.expectedMarkers.filter { marker in
            guard let markerPath = PathSupport.safeManagedRelativePath(marker) else {
                return true
            }
            return !fileSystem.exists(areaPath + "/" + markerPath)
        }

        let suspectPaths = present ? suspectSymlinkPaths(in: areaPath) : []
        return IntegrityReport(
            area: area,
            present: present,
            missingMarkers: missingMarkers,
            suspectPaths: suspectPaths
        )
    }

    private func postDeleteActions(for area: ManagedArea) -> [PostDeleteAction] {
        // This behavior is driven solely by per-area data, never by a known ID.
        if area.requiresRebootstrapAfterDelete {
            return [.markNeedsBootstrap]
        }
        return [.invalidateRuntime(area.id.rawValue)]
    }

    private func currentBlockers(for area: ManagedAreaID) -> [ActiveUseToken] {
        lock.lock()
        defer { lock.unlock() }
        return sortedBlockersLocked(for: area)
    }

    private func sortedBlockersLocked(for area: ManagedAreaID) -> [ActiveUseToken] {
        (activeUseCounts[area] ?? [:]).keys.sorted { lhs, rhs in
            lhs.owner < rhs.owner
        }
    }

    private func suspectSymlinkPaths(in areaPath: String) -> [String] {
        var pendingDirectories = [areaPath]
        var visitedDirectories = Set<String>()
        var suspects = Set<String>()

        while let directory = pendingDirectories.popLast() {
            guard visitedDirectories.insert(directory).inserted else {
                continue
            }
            guard fileSystem.isDirectory(directory) else {
                continue
            }
            guard let entries = try? fileSystem.list(directory) else {
                continue
            }

            for rawEntry in entries.sorted() {
                guard let entry = PathSupport.simpleEntry(rawEntry) else {
                    continue
                }
                let child = directory + "/" + entry

                do {
                    if let destination = try fileSystem.destinationOfSymlink(child) {
                        if symlinkDestinationEscapesContainer(destination, from: child),
                           let relative = PathSupport.relativePath(child, below: areaPath) {
                            suspects.insert(relative)
                        }
                        // Never recurse through a symlink, even one that is safe.
                        continue
                    }
                } catch {
                    // An unreadable link cannot be followed or safely classified.
                    continue
                }

                if fileSystem.isDirectory(child) {
                    pendingDirectories.append(child)
                }
            }
        }

        return suspects.sorted()
    }

    /// Determines whether a raw symlink target tries to climb above the
    /// injected container root. Absolute targets are outside that root because
    /// the protocol's namespace is intentionally relative.
    private func symlinkDestinationEscapesContainer(_ destination: String, from path: String) -> Bool {
        guard !destination.utf8.contains(0) else {
            return true
        }
        guard !destination.hasPrefix("/") else {
            return true
        }

        var components = PathSupport.canonicalPathComponents(path)
        guard !components.isEmpty else {
            return true
        }
        components.removeLast()

        for component in PathSupport.rawComponents(destination) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    return true
                }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return false
    }
}
