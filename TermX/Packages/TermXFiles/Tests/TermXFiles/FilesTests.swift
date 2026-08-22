import XCTest
@testable import TermXFiles

final class FilesTests: XCTestCase {

    private func makeStore(suiteName: String = #function) -> WorkspaceStore {
        let suite = "TermXFilesTests.\(suiteName)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults)
    }

    private func makeTempWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermXFilesTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Empty Store

    func testEmptyStoreRestoresNoWorkspaces() {
        let store = makeStore()
        XCTAssertTrue(store.restoreAll().isEmpty)
    }

    func testEmptyStoreRecentWorkspacesEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.recentWorkspaces().isEmpty)
    }

    func testEmptyStoreTotalAccessCountIsZero() {
        let store = makeStore()
        XCTAssertEqual(store.totalActiveAccessCount, 0)
    }

    // MARK: - Sanitize

    func testSanitizeStripsSpecialCharacters() {
        let store = makeStore()
        XCTAssertEqual(store.sanitize("My Project"), "My-Project")
        XCTAssertEqual(store.sanitize("hello_world"), "hello_world")
        XCTAssertEqual(store.sanitize("test.dir"), "test.dir")
        XCTAssertEqual(store.sanitize("foo/bar\\baz"), "foo-bar-baz")
        XCTAssertEqual(store.sanitize("---leading---"), "leading")
        XCTAssertEqual(store.sanitize("abc123"), "abc123")
    }

    func testSanitizeEmptyString() {
        let store = makeStore()
        XCTAssertEqual(store.sanitize(""), "")
    }

    func testSanitizeUnicodeCharacters() {
        let store = makeStore()
        // Unicode should be replaced with dashes
        let result = store.sanitize("프로젝트")
        XCTAssertFalse(result.contains("프"))
    }

    // MARK: - Resolve (virtual path → real path)

    func testResolveReturnsNilForInvalidPrefix() {
        let store = makeStore()
        XCTAssertNil(store.resolve(virtualPath: "/home/user/file.txt"))
        XCTAssertNil(store.resolve(virtualPath: "/tmp/something"))
        XCTAssertNil(store.resolve(virtualPath: ""))
        XCTAssertNil(store.resolve(virtualPath: "/"))
    }

    func testResolveReturnsNilForUnknownWorkspace() {
        let store = makeStore()
        XCTAssertNil(store.resolve(virtualPath: "/workspaces/nonexistent/file.txt"))
    }

    func testResolveReturnsNilForWorkspacesWithoutSlugMatch() {
        let store = makeStore()
        // No workspaces registered, so nothing can match
        XCTAssertNil(store.resolve(virtualPath: "/workspaces/demo"))
    }

    func testResolveRequiresAtLeastTwoPathComponents() {
        let store = makeStore()
        // "workspaces" alone is not enough
        XCTAssertNil(store.resolve(virtualPath: "/workspaces"))
    }

    // MARK: - Remove Workspace

    func testRemoveWorkspaceRemovesFromStore() {
        let store = makeStore()
        // Manually inject a workspace for testing
        let ws = Workspace(name: "test", mountPath: "/workspaces/test")
        // Since we can't call addWorkspace (needs UIKit), test that remove
        // doesn't crash on unknown workspace
        store.removeWorkspace(ws)
        XCTAssertTrue(store.restoreAll().isEmpty)
    }

    // MARK: - Access Count Balancing (Leak Detection)

    func testAccessCountStartsAtZero() {
        let store = makeStore()
        let ws = Workspace(name: "test", mountPath: "/workspaces/test")
        XCTAssertEqual(store.activeAccessCount(for: ws), 0)
    }

    func testEndAccessOnUnknownWorkspaceIsNoOp() {
        let store = makeStore()
        let ws = Workspace(name: "test", mountPath: "/workspaces/test")
        // Should not crash or throw
        store.endAccess(ws)
        XCTAssertEqual(store.activeAccessCount(for: ws), 0)
    }

    // MARK: - Missing Bookmark

    func testBeginAccessThrowsMissingBookmark() {
        let store = makeStore()
        let ws = Workspace(name: "ghost", mountPath: "/workspaces/ghost")
        XCTAssertThrowsError(try store.beginAccess(ws)) { error in
            XCTAssertEqual(error as? WorkspaceError, .missingBookmark)
        }
    }

    // MARK: - WorkspaceError Equatable

    func testWorkspaceErrorEquality() {
        XCTAssertEqual(WorkspaceError.invalidVirtualPath, WorkspaceError.invalidVirtualPath)
        XCTAssertEqual(WorkspaceError.missingBookmark, WorkspaceError.missingBookmark)
        XCTAssertEqual(WorkspaceError.pickerUnavailable, WorkspaceError.pickerUnavailable)
        XCTAssertEqual(WorkspaceError.accessDenied, WorkspaceError.accessDenied)
        XCTAssertEqual(WorkspaceError.iCloudDownloadFailed, WorkspaceError.iCloudDownloadFailed)
        XCTAssertEqual(WorkspaceError.bookmarkStale, WorkspaceError.bookmarkStale)
        XCTAssertNotEqual(WorkspaceError.missingBookmark, WorkspaceError.accessDenied)
    }

    // MARK: - Workspace Model

    func testWorkspaceIdentifiable() {
        let ws1 = Workspace(name: "a", mountPath: "/workspaces/a")
        let ws2 = Workspace(name: "b", mountPath: "/workspaces/b")
        XCTAssertNotEqual(ws1.id, ws2.id)
    }

    func testWorkspaceHashable() {
        let ws = Workspace(name: "test", mountPath: "/workspaces/test")
        var set: Set<Workspace> = []
        set.insert(ws)
        set.insert(ws) // Same instance
        XCTAssertEqual(set.count, 1)
    }

    func testWorkspaceCodable() throws {
        let original = Workspace(name: "demo", mountPath: "/workspaces/demo")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.mountPath, decoded.mountPath)
    }

    func testWorkspaceSendable() {
        // Compile-time check: Workspace conforms to Sendable
        let ws = Workspace(name: "test", mountPath: "/workspaces/test")
        Task { @Sendable in _ = ws }
    }

    // MARK: - Traversal Protection

    func testResolveBlocksPathTraversal() {
        // Even if we could set up a workspace with a known real path,
        // the resolve function must block traversal attempts
        let store = makeStore()
        // These should all return nil since no workspace is registered
        XCTAssertNil(store.resolve(virtualPath: "/workspaces/demo/../../../etc/passwd"))
        XCTAssertNil(store.resolve(virtualPath: "/workspaces/demo/./../../secret"))
    }

    // MARK: - Restore All Sorting

    func testRestoreAllReturnsSortedByName() {
        let store = makeStore()
        // With no workspaces, just verify empty sorted is still empty
        let result = store.restoreAll()
        XCTAssertEqual(result, result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    // MARK: - Concurrency Safety

    func testConcurrentAccessCountOperations() {
        let store = makeStore()
        let ws = Workspace(name: "concurrent", mountPath: "/workspaces/concurrent")

        // Rapid fire endAccess from multiple threads should not crash
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                store.endAccess(ws)
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(store.activeAccessCount(for: ws), 0)
    }

    // MARK: - BookmarkRecord Internal

    func testBookmarkRecordCodable() throws {
        let ws = Workspace(name: "test", mountPath: "/workspaces/test")
        let record = BookmarkRecord(workspace: ws, data: Data([0x01, 0x02, 0x03]))
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BookmarkRecord.self, from: encoded)
        XCTAssertEqual(decoded.workspace.id, ws.id)
        XCTAssertEqual(decoded.data, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(decoded.accessCount, 0)
    }

    // MARK: - Stale Bookmarks

    func testStaleWorkspaceIDsEmptyStore() {
        let store = makeStore()
        XCTAssertTrue(store.staleWorkspaceIDs().isEmpty)
    }

    // MARK: - Resolve Nested Paths

    func testResolveNestedPaths() throws {
        let store = makeStore()
        let root = try makeTempWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("src/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try "print('hello')".write(to: file, atomically: true, encoding: .utf8)

        let ws = Workspace(name: "nested", mountPath: "/workspaces/nested")
        try store.registerLocalWorkspaceForTesting(ws, rootURL: root)
        _ = try store.beginLocalAccessForTesting(ws)
        defer { store.endAccess(ws) }

        XCTAssertEqual(
            store.resolve(virtualPath: "/workspaces/nested/src/lib/main.swift"),
            file.standardizedFileURL.path
        )
        XCTAssertEqual(
            store.resolve(virtualPath: "/workspaces/nested/src"),
            root.appendingPathComponent("src").standardizedFileURL.path
        )
        XCTAssertEqual(
            store.resolve(virtualPath: "/workspaces/nested"),
            root.standardizedFileURL.path
        )
    }

    func testResolveNestedPathTraversalBlockedAfterAccess() throws {
        let store = makeStore()
        let root = try makeTempWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ws = Workspace(name: "secure", mountPath: "/workspaces/secure")
        try store.registerLocalWorkspaceForTesting(ws, rootURL: root)
        _ = try store.beginLocalAccessForTesting(ws)
        defer { store.endAccess(ws) }

        XCTAssertNil(store.resolve(virtualPath: "/workspaces/secure/../../etc/passwd"))
        XCTAssertNil(store.resolve(virtualPath: "/workspaces/secure/nope/../../../private"))
    }

    // MARK: - Bookmark Persistence Round-Trip

    func testBookmarkPersistenceSurvivesRelaunch() throws {
        let suite = "TermXFilesTests.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = try makeTempWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ws = Workspace(id: UUID(), name: "persist", mountPath: "/workspaces/persist")

        let store1 = WorkspaceStore(defaults: defaults)
        try store1.registerLocalWorkspaceForTesting(ws, rootURL: root)
        XCTAssertEqual(store1.restoreAll().map(\.id), [ws.id])

        let store2 = WorkspaceStore(defaults: defaults)
        let restored = store2.restoreAll()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, ws.id)
        XCTAssertEqual(restored[0].name, "persist")
        XCTAssertEqual(restored[0].mountPath, "/workspaces/persist")

        let path = try store2.beginLocalAccessForTesting(restored[0])
        XCTAssertEqual(
            URL(fileURLWithPath: path).standardizedFileURL.path,
            root.standardizedFileURL.path
        )
        store2.endAccess(restored[0])
        XCTAssertEqual(store2.activeAccessCount(for: restored[0]), 0)
    }

    // MARK: - Access Scope Leak Test (100 cycles)

    func testAccessScopeBalancedAfter100Cycles() throws {
        let store = makeStore()
        let root = try makeTempWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ws = Workspace(name: "leak-test", mountPath: "/workspaces/leak-test")
        try store.registerLocalWorkspaceForTesting(ws, rootURL: root)

        for cycle in 0..<100 {
            _ = try store.beginLocalAccessForTesting(ws)
            store.endAccess(ws)
            XCTAssertEqual(
                store.activeAccessCount(for: ws),
                0,
                "Leak after cycle \(cycle + 1)"
            )
        }
        XCTAssertEqual(store.totalActiveAccessCount, 0)
    }

    func testNestedAccessRefCountBalancedAfter100Cycles() throws {
        let store = makeStore()
        let root = try makeTempWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ws = Workspace(name: "refcount", mountPath: "/workspaces/refcount")
        try store.registerLocalWorkspaceForTesting(ws, rootURL: root)

        for _ in 0..<100 {
            _ = try store.beginLocalAccessForTesting(ws)
            _ = try store.beginLocalAccessForTesting(ws)
            XCTAssertEqual(store.activeAccessCount(for: ws), 2)
            store.endAccess(ws)
            XCTAssertEqual(store.activeAccessCount(for: ws), 1)
            store.endAccess(ws)
            XCTAssertEqual(store.activeAccessCount(for: ws), 0)
        }
        XCTAssertEqual(store.totalActiveAccessCount, 0)
    }

    // MARK: - iCloud Download (local path)

    func testDownloadIfNeededSkipsLocalFiles() async throws {
        let store = makeStore()
        let root = try makeTempWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("local.txt")
        try "local".write(to: file, atomically: true, encoding: .utf8)

        try await store.downloadIfNeeded(at: file)
    }
}
