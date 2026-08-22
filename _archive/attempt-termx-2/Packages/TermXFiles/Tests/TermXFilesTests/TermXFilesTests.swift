import XCTest
@testable import TermXFiles
final class TermXFilesTests: XCTestCase {
    func testVirtualPathResolutionAndTraversalProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("src"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = WorkspaceStore(storageDirectory: root.appendingPathComponent("meta")); let workspace = try store.addWorkspace(url: root)
        XCTAssertEqual(store.resolve(virtualPath: workspace.mountPath + "/src"), nested.standardizedFileURL.path)
        XCTAssertNil(store.resolve(virtualPath: workspace.mountPath + "/../outside"))
        XCTAssertEqual(try store.beginAccess(workspace), root.standardizedFileURL.path); store.endAccess(workspace)
    }
}
