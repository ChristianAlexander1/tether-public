import XCTest
@testable import TermXFiles

final class TermXFilesTests: XCTestCase {
    func testResolveStaysInsideWorkspace() throws {
        let defaults = UserDefaults(suiteName: "termx.tests.\(UUID().uuidString)")!
        let store = WorkspaceStore(defaults: defaults)
        let workspace = Workspace(name: "Demo", mountPath: "/workspaces/Demo")
        store.register(workspace, realPath: "/tmp/demo")
        XCTAssertEqual(store.resolve(virtualPath: "/workspaces/Demo/src/main.swift"), "/tmp/demo/src/main.swift")
        XCTAssertNil(store.resolve(virtualPath: "/workspaces/Demo/../../etc/passwd"))
    }
}
