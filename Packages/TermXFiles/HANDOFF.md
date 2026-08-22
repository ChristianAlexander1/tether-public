# TermXFiles Handoff

**Status: 100% acceptance (automated); 3 device-only checks documented below**

## Implemented Surface

TermXFiles provides the complete C3 filesystem boundary described by the TermX integration
contracts (docs/09-integration-contracts.md §2.3).

### Frozen API (preserved exactly)

- `Workspace` — `Codable`, `Identifiable`, `Hashable`, `Sendable` value type with `id`, `name`, `mountPath`
- `WorkspaceProviding` protocol — `addWorkspace()`, `restoreAll()`, `beginAccess()`, `endAccess()`, `resolve(virtualPath:)`
- `WorkspaceStore` — full implementation of `WorkspaceProviding`

### Extended API (additions beyond frozen contract)

- `removeWorkspace(_ w: Workspace)` — removes workspace and its bookmark from the store
- `recentWorkspaces() -> [Workspace]` — ordered by last-access timestamp (most recent first)
- `activeAccessCount(for:)` / `totalActiveAccessCount` — for leak detection and monitoring
- `downloadIfNeeded(at:)` — iCloud eviction handling; triggers download + polls until ready (60s timeout)
- `staleWorkspaceIDs()` — returns workspace IDs whose bookmarks need user re-pick
- `sanitize(_ name:)` — exposed as internal for testing

### Internal test seams (unit tests only; not mocks in product paths)

- `registerLocalWorkspaceForTesting(_:rootURL:)` — registers a workspace from a local directory bookmark
- `beginLocalAccessForTesting(_:)` — exercises ref-count access logic without security-scoped URLs (macOS CI)

### UI Components

- `WorkspaceLauncherView` — SwiftUI launcher screen with:
  - Adaptive grid of workspace cards (folder icon, name, mount path)
  - "Open Folder…" button (toolbar + empty state CTA)
  - Context menu with delete action
  - Empty state with instructions
  - Error alert handling
- `WorkspaceLauncherViewModel` — `@MainActor` view model driving the launcher

### QuickLook Integration

- `QuickLookHelper` — static methods for:
  - `preview(url:from:)` — QLPreviewController for files
  - `share(url:from:)` — UIActivityViewController for directories
  - `handleOpenCommand(path:from:)` — dispatcher for the shell's `open` command
- SwiftUI `.quickLookPreview(url:)` view modifier

### UIDocumentPickerViewController flow

- `UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)` — in-place folder access
- Delegate calls `startAccessingSecurityScopedResource()` before returning the picked URL
- `addWorkspace()` creates security-scoped bookmark, persists, then stops picker-granted access
- Presents from foreground-active scene's topmost view controller (handles nested modals)

## C3 Acceptance Criteria (docs/09 §3)

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Picker grants recursive R/W | **Device manual** | Steps below; picker uses `asCopy: false` + security-scoped bookmark |
| Bookmark survives relaunch | **Automated** | `testBookmarkPersistenceSurvivesRelaunch` |
| `resolve()` correct for nested paths | **Automated** | `testResolveNestedPaths`, `testResolveNestedPathTraversalBlockedAfterAccess` |
| Access-scope counting balanced (100 cycles) | **Automated** | `testAccessScopeBalancedAfter100Cycles`, `testNestedAccessRefCountBalancedAfter100Cycles` |
| iCloud-evicted file downloads on open | **Device manual** | `downloadIfNeeded(at:)` implemented; local skip tested in `testDownloadIfNeededSkipsLocalFiles` |

## Build and Tests

```sh
# Swift package tests (macOS CI — all 30 tests)
cd TermX/Packages/TermXFiles && swift test

# Xcode Simulator tests (full UIKit paths — optional)
xcodebuild -scheme TermXFiles -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### Latest `swift test` output (2026-08-22)

```
Test Suite 'All tests' started.
Test Suite 'TermXFilesPackageTests.xctest' started.
Test Suite 'FilesTests' started.
Test Case '-[TermXFilesTests.FilesTests testAccessCountStartsAtZero]' passed (0.002 seconds).
Test Case '-[TermXFilesTests.FilesTests testAccessScopeBalancedAfter100Cycles]' passed (0.017 seconds).
Test Case '-[TermXFilesTests.FilesTests testBeginAccessThrowsMissingBookmark]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testBookmarkPersistenceSurvivesRelaunch]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testBookmarkRecordCodable]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testConcurrentAccessCountOperations]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testDownloadIfNeededSkipsLocalFiles]' passed (0.005 seconds).
Test Case '-[TermXFilesTests.FilesTests testEmptyStoreRecentWorkspacesEmpty]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testEmptyStoreRestoresNoWorkspaces]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testEmptyStoreTotalAccessCountIsZero]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testEndAccessOnUnknownWorkspaceIsNoOp]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testNestedAccessRefCountBalancedAfter100Cycles]' passed (0.025 seconds).
Test Case '-[TermXFilesTests.FilesTests testRemoveWorkspaceRemovesFromStore]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveBlocksPathTraversal]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveNestedPaths]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveNestedPathTraversalBlockedAfterAccess]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveRequiresAtLeastTwoPathComponents]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveReturnsNilForInvalidPrefix]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveReturnsNilForUnknownWorkspace]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testResolveReturnsNilForWorkspacesWithoutSlugMatch]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testRestoreAllReturnsSortedByName]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testSanitizeEmptyString]' passed (0.001 seconds).
Test Case '-[TermXFilesTests.FilesTests testSanitizeStripsSpecialCharacters]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testSanitizeUnicodeCharacters]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testStaleWorkspaceIDsEmptyStore]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testWorkspaceCodable]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testWorkspaceErrorEquality]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testWorkspaceHashable]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testWorkspaceIdentifiable]' passed (0.000 seconds).
Test Case '-[TermXFilesTests.FilesTests testWorkspaceSendable]' passed (0.000 seconds).
Test Suite 'FilesTests' passed.
	 Executed 30 tests, with 0 failures (0 unexpected) in 0.062 (0.064) seconds
Test Suite 'TermXFilesPackageTests.xctest' passed.
	 Executed 30 tests, with 0 failures (0 unexpected) in 0.062 (0.064) seconds
Test Suite 'All tests' passed.
	 Executed 30 tests, with 0 failures (0 unexpected) in 0.062 (0.065) seconds
```

**Result: 30/30 passed, 0 failures**

### Test Coverage

- Empty store: restoreAll, recentWorkspaces, totalAccessCount
- Sanitize: special chars, empty string, unicode, leading/trailing dashes
- Resolve: invalid prefix, unknown workspace, insufficient components, traversal protection
- Resolve nested: multi-level paths (`src/lib/main.swift`), workspace root, traversal after access
- Workspace model: Identifiable, Hashable, Codable, Sendable conformances
- Access counting: starts at zero, endAccess no-op on unknown, concurrency safety (100 threads)
- Access leak: 100 begin/end cycles balanced; 100 nested ref-count cycles balanced
- Missing bookmark: beginAccess throws `.missingBookmark`
- Error model: all WorkspaceError cases equatable
- BookmarkRecord: internal Codable round-trip
- Bookmark persistence: survives UserDefaults round-trip (simulated relaunch)
- Stale bookmarks: empty store returns empty
- iCloud download: local files skip download path

## Device-Required Tests (manual)

These cannot be fully validated in macOS `swift test`; run on a physical iPhone/iPad with the TermX app.

### 1. Picker grants recursive R/W

1. Launch app → Workspace launcher → tap **Open Folder…**
2. Pick a folder in Files (preferably outside app sandbox, e.g. iCloud Drive or On My iPhone)
3. In terminal tab bound to that workspace, run:
   - `touch /workspaces/<name>/termx-write-test.txt` — expect success
   - `mkdir -p /workspaces/<name>/nested/deep` — expect success
   - `echo hello > /workspaces/<name>/nested/deep/file.txt && cat /workspaces/<name>/nested/deep/file.txt` — expect `hello`
4. Verify files appear in Files app at the picked location

### 2. Bookmark survives relaunch (device confirmation)

Automated by `testBookmarkPersistenceSurvivesRelaunch`; device confirmation:

1. Pick a workspace folder (step 1 above)
2. Force-quit the app (swipe away from app switcher)
3. Relaunch → workspace appears in launcher without re-picking
4. Open workspace → `ls /workspaces/<name>` lists folder contents

### 3. iCloud-evicted file downloads on open

1. Pick an iCloud Drive folder as workspace
2. On another device or macOS, add a file to that folder
3. On device, enable **Settings → [Apple ID] → iCloud → Optimize iPhone Storage** (or wait for eviction)
4. In terminal: `cat /workspaces/<name>/<evicted-file>` — expect download then content (may take a few seconds)
5. Alternatively: use Files app to confirm cloud icon on file, then `cat` in TermX

### 4. Access-scope counting on real security-scoped resources (device confirmation)

Automated ref-count logic by `testAccessScopeBalancedAfter100Cycles`; device confirmation:

1. Pick a workspace
2. Open and close the workspace tab 10+ times rapidly
3. Monitor for `accessDenied` errors or inability to read/write — should not occur
4. (Optional) Instruments → File Activity to confirm no scope leak warnings

## Dependency and Licensing

No external dependencies beyond UIKit, QuickLook, and UniformTypeIdentifiers (all Apple frameworks).
No GPL or AGPL sources bundled.

## Known Limitations

- `addWorkspace()` requires UIKit (iOS runtime); returns `.pickerUnavailable` on non-Darwin.
- iCloud download polling has a 60-second hard timeout; could be made configurable.
- Stale bookmark detection requires UIKit for security-scoped bookmark resolution.
- `NSFilePresenter`-based folder watching (for fs events) is deferred to integration.
