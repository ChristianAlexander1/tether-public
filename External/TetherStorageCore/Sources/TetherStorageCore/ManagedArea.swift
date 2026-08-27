import Foundation

/// A stable identifier for a directory tree owned by the host application.
public struct ManagedAreaID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let linuxRootfs = ManagedAreaID(rawValue: "linux")
    public static let nodeHome = ManagedAreaID(rawValue: "node")
    public static let claudeInstall = ManagedAreaID(rawValue: "claude")
    public static let pythonPackages = ManagedAreaID(rawValue: "python")
    public static let caches = ManagedAreaID(rawValue: "caches")
}

/// Metadata for one app-container directory tree.
///
/// `relativePath` and every marker are deliberately relative to the injected
/// file system's container root. Catalog operations reject non-canonical or
/// escaping paths before they invoke that file system.
public struct ManagedArea: Sendable {
    public var id: ManagedAreaID
    public var displayName: String
    public var relativePath: String
    public var deletable: Bool
    public var requiresRebootstrapAfterDelete: Bool

    /// Files expected to exist below `relativePath`. Each marker is relative
    /// to this area, not to the app container root.
    public var expectedMarkers: [String] = []

    public init(
        id: ManagedAreaID,
        displayName: String,
        relativePath: String,
        deletable: Bool,
        requiresRebootstrapAfterDelete: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.deletable = deletable
        self.requiresRebootstrapAfterDelete = requiresRebootstrapAfterDelete
        self.expectedMarkers = []
    }

    /// Extended initializer that supplies integrity markers while preserving
    /// the frozen initializer above.
    public init(
        id: ManagedAreaID,
        displayName: String,
        relativePath: String,
        deletable: Bool,
        requiresRebootstrapAfterDelete: Bool,
        expectedMarkers: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.deletable = deletable
        self.requiresRebootstrapAfterDelete = requiresRebootstrapAfterDelete
        self.expectedMarkers = expectedMarkers
    }
}

/// A preflight description of a deletion. The initializer is additive to the
/// frozen property-based API and is useful for callers that stage a plan.
public struct DeletePlan: Equatable, Sendable {
    public var area: ManagedAreaID
    public var paths: [String]
    public var estimatedBytes: Int64
    public var blockedBy: [ActiveUseToken]
    public var postActions: [PostDeleteAction]

    public init(
        area: ManagedAreaID,
        paths: [String],
        estimatedBytes: Int64,
        blockedBy: [ActiveUseToken],
        postActions: [PostDeleteAction]
    ) {
        self.area = area
        self.paths = paths
        self.estimatedBytes = estimatedBytes
        self.blockedBy = blockedBy
        self.postActions = postActions
    }
}

public enum PostDeleteAction: Equatable, Sendable {
    case markNeedsBootstrap
    case invalidateRuntime(String)
    case none
}

/// A lease held by a live consumer of a managed area.
public struct ActiveUseToken: Hashable, Sendable {
    public let owner: String

    public init(owner: String) {
        self.owner = owner
    }
}

public struct IntegrityReport: Equatable, Sendable {
    public var area: ManagedAreaID
    public var present: Bool
    public var missingMarkers: [String]
    public var suspectPaths: [String]

    public init(
        area: ManagedAreaID,
        present: Bool,
        missingMarkers: [String],
        suspectPaths: [String]
    ) {
        self.area = area
        self.present = present
        self.missingMarkers = missingMarkers
        self.suspectPaths = suspectPaths
    }
}

public enum StorageError: Error, Equatable {
    case blocked([ActiveUseToken])
    case unknownArea
    case notDeletable
    case io(String)
}
