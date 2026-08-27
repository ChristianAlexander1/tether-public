# Agent brief F — `TetherStorageCore` (managed storage catalog + path confinement)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`TetherStorageCore`**, a pure-Swift package that models an iOS
terminal app's storage safely:

1. **`StorageCatalog`** — a registry of "managed areas" inside the app's
   container (Linux rootfs, global Node home, Claude install, Python
   packages, caches) with size accounting, **delete plans** (what would be
   removed, how many bytes, what must happen afterwards), and — critically —
   **active-use guards** so a live terminal session blocks deletion of the
   rootfs it is executing from.
2. **`ConfinedPathResolver`** — pure path-confinement logic that decides
   whether a guest-requested path stays inside a confinement root, resolving
   `..` components and symlinks, rejecting escape at any ancestor.

Context: the host app is an iOS terminal that runs an emulated Alpine Linux
rootfs from `Documents/linux`, plus separately managed tool installs. Today a
Storage screen deletes directories directly and posts a notification;
whether anything is using the directory is implicit. Deleting the rootfs
under a running shell must become **impossible by construction**. The user's
own workspace (a folder they picked in the Files app) is *never* a managed
area — the catalog only ever touches app-container paths, which is enforced
by the design below (relative paths only, resolved against one injected
container root).

## Ground rules

- Swift 5.9+ package: `// swift-tools-version:5.9`, platforms
  `.macOS(.v13), .iOS(.v16)`.
- **Foundation only**; `swift build` / `swift test` must pass on Linux Swift.
- Zero dependencies; offline, deterministic tests.
- All filesystem access goes through the injected `StorageFileSystem`
  protocol. You ship `InMemoryStorageFileSystem`; the integrator ships the
  real one. **No `FileManager` anywhere in the core target.**
- Never crash on hostile input (paths with `..`, symlink cycles, missing
  areas): every case has defined behavior and a test.

## Public API contract (FROZEN — implement exactly; you may add, never change)

```swift
public struct ManagedAreaID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String; public init(rawValue: String)
    public static let linuxRootfs: ManagedAreaID     // "linux"
    public static let nodeHome: ManagedAreaID        // "node"
    public static let claudeInstall: ManagedAreaID   // "claude"
    public static let pythonPackages: ManagedAreaID  // "python"
    public static let caches: ManagedAreaID          // "caches"
}

public struct ManagedArea: Sendable {
    public var id: ManagedAreaID
    public var displayName: String
    public var relativePath: String            // relative to the container root
    public var deletable: Bool
    public var requiresRebootstrapAfterDelete: Bool
    public init(id: ManagedAreaID, displayName: String, relativePath: String,
                deletable: Bool, requiresRebootstrapAfterDelete: Bool)
}

public protocol StorageFileSystem: AnyObject {
    func exists(_ relativePath: String) -> Bool
    func isDirectory(_ relativePath: String) -> Bool
    func sizeOfTree(_ relativePath: String) throws -> Int64
    func removeTree(_ relativePath: String) throws
    func list(_ relativePath: String) throws -> [String]
    func destinationOfSymlink(_ relativePath: String) throws -> String?
}
public final class InMemoryStorageFileSystem: StorageFileSystem {
    public init()
    // Seeding helpers for tests — design your own, e.g.:
    public func addFile(_ relativePath: String, size: Int64)
    public func addDirectory(_ relativePath: String)
    public func addSymlink(_ relativePath: String, destination: String)
}

public struct DeletePlan: Equatable, Sendable {
    public var area: ManagedAreaID
    public var paths: [String]
    public var estimatedBytes: Int64
    public var blockedBy: [ActiveUseToken]
    public var postActions: [PostDeleteAction]
}
public enum PostDeleteAction: Equatable, Sendable {
    case markNeedsBootstrap, invalidateRuntime(String), none
}
public struct ActiveUseToken: Hashable, Sendable {
    public let owner: String
    public init(owner: String)
}

public final class StorageCatalog {
    public init(areas: [ManagedArea], fileSystem: StorageFileSystem)
    public func acquire(_ token: ActiveUseToken, on area: ManagedAreaID)
    public func release(_ token: ActiveUseToken, from area: ManagedAreaID)
    public func plan(delete area: ManagedAreaID) throws -> DeletePlan
    public func execute(_ plan: DeletePlan) throws -> [PostDeleteAction]
    public func integrityReport(for area: ManagedAreaID) -> IntegrityReport
}
public struct IntegrityReport: Equatable, Sendable {
    public var area: ManagedAreaID
    public var present: Bool
    public var missingMarkers: [String]
    public var suspectPaths: [String]
}
public enum StorageError: Error, Equatable {
    case blocked([ActiveUseToken]), unknownArea, notDeletable, io(String)
}

public struct ConfinedPathResolver {
    public init(confinementRoot: String, fileSystem: StorageFileSystem)
    public func resolve(_ guestPath: String) -> Result<String, ConfinementViolation>
}
public enum ConfinementViolation: Error, Equatable {
    case dotDotEscape, symlinkEscape(via: String), absoluteOutsideRoot, emptyPath
}
```

## Behavior specification

### Catalog

- `plan(delete:)`:
  - unknown area → throw `.unknownArea`; `deletable == false` → throw
    `.notDeletable`.
  - `paths` = the area's `relativePath` (single tree). `estimatedBytes` from
    `sizeOfTree`; if the tree is absent, a valid plan with 0 bytes and empty
    paths (deleting nothing is fine).
  - `blockedBy` = current tokens held on the area (sorted by owner for
    determinism).
  - `postActions`: `.markNeedsBootstrap` when
    `requiresRebootstrapAfterDelete`, else `.invalidateRuntime(id.rawValue)`
    for tool areas — encode this rule as data on `ManagedArea`, not a switch
    over known IDs (no hardcoding of specific area names in logic).
- `execute(_:)`:
  - Re-checks guards at execution time (tokens may have been acquired since
    planning) → throw `.blocked(tokens)` if any. This is the invariant that
    makes deleting a live rootfs impossible.
  - Calls `removeTree` for each path; an underlying error → `.io(message)`
    with **no partial-state lie**: report which paths were removed in the
    error message.
  - Returns the plan's `postActions` on success.
- Tokens: `acquire` is idempotent per (token, area); `release` of a token
  never acquired is a recorded no-op. Multiple owners can hold tokens on one
  area simultaneously.
- `integrityReport`: `present` = tree exists and is a directory;
  `missingMarkers` = expected marker files absent (markers are supplied per
  area via an optional extension you design — e.g. an
  `expectedMarkers: [String]` property with default `[]`; keep the frozen
  init working by providing a secondary init or var);
  `suspectPaths` = entries in the area that are symlinks pointing outside
  the container root (uses `destinationOfSymlink`).

### ConfinedPathResolver

- Input `guestPath` may be absolute (`/work/src/../etc`) or relative.
- Normalize: split on `/`, process `.` and `..` lexically **but** verify
  every intermediate prefix against the filesystem for symlinks: if any
  ancestor component is a symlink, resolve its destination first and require
  the resolved form to remain under `confinementRoot`; a symlink whose
  destination leaves the root → `.symlinkEscape(via: <that path>)`.
- `..` that would climb above the confinement root at any point (even if a
  later component climbs back) → `.dotDotEscape`.
- Absolute path not under the root → `.absoluteOutsideRoot`; empty or
  whitespace-only → `.emptyPath`.
- Success returns the normalized path **relative to the confinement root**
  with no `.`/`..` components and forward slashes.
- Symlink cycles (a→b→a) must terminate with `.symlinkEscape` or a bounded
  failure after 40 hops — never an infinite loop.

## Edge cases you MUST handle (each needs a test)

1. Delete plan for rootfs while a session token is held → plan lists
   `blockedBy`; `execute` throws `.blocked`; after `release`, a fresh plan
   executes and returns `[.markNeedsBootstrap]`.
2. Token acquired **between** `plan` and `execute` → execute still throws
   `.blocked` (guards re-checked at execution).
3. Deleting an area whose tree doesn't exist → succeeds trivially, post
   actions still returned (the caller may still need to re-validate).
4. `removeTree` throws halfway (script the fake to fail on the 2nd path of a
   multi-path plan you construct) → `.io` error message names removed and
   remaining paths.
5. Idempotent acquire: same token twice, one release → still blocked; second
   release → unblocked.
6. Two different owners on one area → both listed, sorted by owner.
7. Integrity: rootfs present but marker file missing → report lists it;
   an internal symlink pointing to `../../outside` → listed in
   `suspectPaths`.
8. Resolver: `/work/a/../b` → ok `b` (relative to root when root is
   `/work`); `/work/../etc/passwd` → `.dotDotEscape`; `/etc/passwd` →
   `.absoluteOutsideRoot`; `""` and `"   "` → `.emptyPath`.
9. Resolver symlinks: `link → /outside` at depth 3 → `.symlinkEscape(via:)`
   names the link; `link → inside/dir` → resolves through it; cycle a↔b →
   bounded failure.
10. Resolver with root `"/"`-adjacent oddities: root `"/data/app"` and guest
    path `"/data/appendix"` must NOT pass (prefix-string confusion — compare
    by path components, not string prefix).
11. Unicode and spaces in every path component → all logic byte-clean.
12. `sizeOfTree` overflow sanity: seed files summing past Int32 → Int64 math
    correct.

## Test plan (minimum)

- `CatalogPlanTests`, `CatalogGuardTests`, `CatalogExecuteTests`,
  `IntegrityTests`, `ResolverLexicalTests`, `ResolverSymlinkTests`,
  `InMemoryFSTests` (the fake itself is spec'd: nested trees, symlinks,
  listing).
- Target ≥ 100 assertions.

## Acceptance checklist

- [ ] `swift build` / `swift test` pass, zero warnings, Linux Swift 5.9+.
- [ ] Public API matches the frozen contract exactly.
- [ ] All 12 edge cases have named tests.
- [ ] `FileManager` appears nowhere in `Sources/`.
- [ ] No area-name switches in logic (grep shows no `"linux"` literal outside
      the `ManagedAreaID` statics and tests).
- [ ] HANDOFF.md: how the integrator implements `StorageFileSystem` over
      `FileManager`, how session lifecycle acquires/releases the rootfs
      token, marker-file convention, and a 10-line wiring example.

## Non-goals

- No UI, no notifications, no UserDefaults.
- No real deletion or disk I/O in this package.
- No knowledge of specific apps/tools beyond the five ManagedAreaID statics
  (which are just names).
- No security-scoped bookmark handling (the workspace is out of scope by
  design).
