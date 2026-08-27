import Foundation
import TetherStorageCore

/// The app's storage model: the five managed areas, the catalog over them, and
/// the leases live sessions hold.
///
/// Storage used to delete directories straight out of the view and post a
/// notification afterwards. Nothing stopped a delete from removing the rootfs
/// a running shell was executing out of. Deletion now goes through
/// `StorageCatalog`, which refuses to delete an area a session has leased and
/// reports which owner is holding it.
public final class TetherStorage {
    /// Shared instance: the storage screen and the terminal sessions must see
    /// the same lease table or the guard is meaningless.
    public static let shared = TetherStorage()

    public let catalog: StorageCatalog
    private let containerRoot: URL

    public init(containerRoot: URL? = nil) {
        let home = containerRoot ?? URL(fileURLWithPath: NSHomeDirectory())
        self.containerRoot = home
        let fileSystem = AppContainerFileSystem(containerURL: home)
        self.catalog = StorageCatalog(areas: Self.managedAreas, fileSystem: fileSystem)
    }

    /// The areas Tether manages inside its own container. The user's picked
    /// workspace folders are deliberately absent: they are not ours to delete.
    public static let managedAreas: [ManagedArea] = [
        ManagedArea(
            id: .linuxRootfs,
            displayName: "Linux packages",
            relativePath: "Documents/linux",
            deletable: true,
            requiresRebootstrapAfterDelete: true,
            // Presence of the bootstrap marker *and* a real userland: the
            // marker alone was not enough, since a half-deleted rootfs kept it.
            expectedMarkers: [".tether-bootstrapped", "bin/busybox"]
        ),
        ManagedArea(
            id: .nodeHome,
            displayName: "Node packages",
            relativePath: "Documents/node",
            deletable: true,
            requiresRebootstrapAfterDelete: false
        ),
        ManagedArea(
            id: .claudeInstall,
            displayName: "Claude Code",
            relativePath: "Documents/claude",
            deletable: true,
            requiresRebootstrapAfterDelete: false
        ),
        ManagedArea(
            id: .pythonPackages,
            displayName: "Python packages",
            relativePath: "Documents/python",
            deletable: true,
            requiresRebootstrapAfterDelete: false
        ),
        ManagedArea(
            id: .caches,
            displayName: "Caches",
            relativePath: "Documents/.npm",
            deletable: true,
            requiresRebootstrapAfterDelete: false
        ),
    ]

    /// Lease an area for a live session. Balanced by `endSessionUse`.
    public func beginSessionUse(_ area: ManagedAreaID, owner: String) {
        catalog.acquire(ActiveUseToken(owner: owner), on: area)
    }

    public func endSessionUse(_ area: ManagedAreaID, owner: String) {
        catalog.release(ActiveUseToken(owner: owner), from: area)
    }
}
