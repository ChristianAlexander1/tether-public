import XCTest
@testable import TetherStorageCore

final class ManagedAreaAPITests: XCTestCase {
    func testFrozenManagedAreaInitializerDefaultsExpectedMarkersToEmpty() {
        let area = ManagedArea(
            id: .nodeHome,
            displayName: "Node",
            relativePath: "tooling/node",
            deletable: true,
            requiresRebootstrapAfterDelete: false
        )

        XCTAssertEqual(area.id, .nodeHome)
        XCTAssertEqual(area.displayName, "Node")
        XCTAssertEqual(area.relativePath, "tooling/node")
        XCTAssertTrue(area.deletable)
        XCTAssertFalse(area.requiresRebootstrapAfterDelete)
        XCTAssertEqual(area.expectedMarkers, [])
    }

    func testExtendedManagedAreaInitializerPreservesSuppliedMarkers() {
        let area = ManagedArea(
            id: .pythonPackages,
            displayName: "Python",
            relativePath: "tooling/python",
            deletable: true,
            requiresRebootstrapAfterDelete: false,
            expectedMarkers: ["site-packages", "metadata/version"]
        )

        XCTAssertEqual(area.expectedMarkers, ["site-packages", "metadata/version"])
        XCTAssertEqual(area.id.rawValue, "python")
        XCTAssertEqual(area.relativePath, "tooling/python")
    }
}
