# TetherStorageCore handoff

`TetherStorageCore` is intentionally a pure model. It does not know an app's
container URL and does not access disk. The application supplies a
`StorageFileSystem` that treats one selected app-container URL as its virtual
root. Every argument sent by the core is a **relative, canonical** path below
that root.

## Production `StorageFileSystem` adapter

Implement the protocol in the app target (not in this package) using
`FileManager` and a private root `URL`:

1. Reject an empty, absolute, or traversal-containing relative path before
   appending it to the root URL. Compare components, not string prefixes.
2. Resolve only under the injected root URL. Do not accept a Files-app
   workspace URL in this adapter; the workspace is not a managed area.
3. Use `fileExists(atPath:isDirectory:)` for `exists` and `isDirectory`.
4. For `sizeOfTree`, enumerate descendants with resource keys such as
   `.isRegularFileKey` and `.fileSizeKey`, use `Int64`, and do not follow
   symbolic links while totaling a tree.
5. For `removeTree`, remove the validated child URL with `FileManager`.
   If deletion fails, throw the original error; `StorageCatalog` adds the
   completed and remaining plan paths to its `.io` message.
6. For `list`, return immediate child names only, sorted if the adapter wants
   deterministic logs. For `destinationOfSymlink`, return the raw destination
   for a symlink and `nil` for both non-symlinks and missing paths.
7. Treat an absolute symlink destination as outside the adapter's relative
   namespace. Do not resolve a symlink merely to implement `list` or
   `removeTree`.

The production adapter is the security boundary: it should revalidate paths
before every `FileManager` call, even though the catalog has already checked
them. The core itself never imports or references `FileManager`.

## Session lease lifecycle

Acquire the root filesystem's token *before* launching a shell or runtime that
uses it. Release the matching acquisition only after the process has exited
and all runtime references are closed. A token appears once in a delete plan's
`blockedBy` list even if nested lifecycle calls acquire it more than once; each
acquisition still needs one matching release. `execute(_:)` checks leases again
while holding its catalog coordination lock, so a plan made before a session
starts cannot delete an active root filesystem.

Use a unique, stable owner per terminal session, for example
`terminal-session-<UUID>`. Other consumers, such as an indexing task, should
use their own tokens on the same area.

## Marker convention

`ManagedArea.expectedMarkers` contains paths relative to the area, with no
leading slash or `..`. For example, a root filesystem area can use markers
such as `etc/alpine-release` and `bin/sh`. `IntegrityReport.missingMarkers`
returns those same area-relative strings. `suspectPaths` is also relative to
the area (for example, `usr/local/bin/tool-link`), and identifies symlinks
whose raw destination climbs above the app container root.

## Ten-line wiring example

```swift
let fs = AppContainerFileSystem(containerURL: containerURL)
let rootfs = ManagedArea(id: .linuxRootfs, displayName: "Linux", relativePath: "Documents/linux", deletable: true, requiresRebootstrapAfterDelete: true, expectedMarkers: ["etc/alpine-release"])
let caches = ManagedArea(id: .caches, displayName: "Caches", relativePath: "Library/Caches/tools", deletable: true, requiresRebootstrapAfterDelete: false)
let catalog = StorageCatalog(areas: [rootfs, caches], fileSystem: fs)
let sessionToken = ActiveUseToken(owner: "terminal-session-\(sessionID)")
catalog.acquire(sessionToken, on: .linuxRootfs)
terminal.onExit { catalog.release(sessionToken, from: .linuxRootfs) }
let plan = try catalog.plan(delete: .caches)
let actions = try catalog.execute(plan)
applyPostDeleteActions(actions)
```

The storage screen should present `plan.blockedBy` instead of offering an
unsafe force-delete path. If it receives `.blocked`, it should refresh the
plan after the owning sessions end rather than trying deletion again.
