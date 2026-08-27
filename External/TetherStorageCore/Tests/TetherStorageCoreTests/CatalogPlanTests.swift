import XCTest
@testable import TetherStorageCore

final class CatalogPlanTests: XCTestCase {
    func testPlanUsesSingleAreaPathAndAccurateInt64Size() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("state/root/one", size: Int64(Int32.max))
        fs.addFile("state/root/two", size: Int64(Int32.max) + 99)
        let area = makeArea(.linuxRootfs, path: "state/root", bootstrap: true)
        let catalog = StorageCatalog(areas: [area], fileSystem: fs)

        let plan = try catalog.plan(delete: .linuxRootfs)

        XCTAssertEqual(plan.area, .linuxRootfs)
        XCTAssertEqual(plan.paths, ["state/root"])
        XCTAssertEqual(plan.estimatedBytes, Int64(Int32.max) * 2 + 99)
        XCTAssertEqual(plan.blockedBy, [])
        XCTAssertEqual(plan.postActions, [.markNeedsBootstrap])
        XCTAssertTrue(plan.estimatedBytes > Int64(Int32.max))
        XCTAssertTrue(fs.exists("state/root/one"))
        XCTAssertTrue(fs.isDirectory("state/root"))
    }

    func testToolPostActionUsesAreaDataRatherThanKnownIdentifier() throws {
        let custom = ManagedAreaID(rawValue: "custom-tool")
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("tools/custom")
        let catalog = StorageCatalog(
            areas: [makeArea(custom, path: "tools/custom", bootstrap: false)],
            fileSystem: fs
        )

        let plan = try catalog.plan(delete: custom)

        XCTAssertEqual(plan.paths, ["tools/custom"])
        XCTAssertEqual(plan.estimatedBytes, 0)
        XCTAssertEqual(plan.postActions, [.invalidateRuntime("custom-tool")])
        XCTAssertEqual(plan.blockedBy.count, 0)
        XCTAssertTrue(fs.exists("tools/custom"))
    }

    func testUnknownAndNonDeletableAreasHaveDefinedErrors() {
        let fs = InMemoryStorageFileSystem()
        let catalog = StorageCatalog(
            areas: [makeArea(.nodeHome, path: "node-home", deletable: false)],
            fileSystem: fs
        )

        XCTAssertStorageError(try catalog.plan(delete: .caches), equals: .unknownArea)
        XCTAssertStorageError(try catalog.plan(delete: .nodeHome), equals: .notDeletable)
        XCTAssertFalse(fs.exists("node-home"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)
    }

    func testInvalidManagedPathIsRejectedBeforeFilesystemAccess() {
        let fs = InMemoryStorageFileSystem()
        let catalog = StorageCatalog(
            areas: [makeArea(.pythonPackages, path: "safe/../outside")],
            fileSystem: fs
        )

        XCTAssertThrowsError(try catalog.plan(delete: .pythonPackages)) { error in
            guard let storageError = error as? StorageError,
                  case .io(let message) = storageError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("invalid managed area path"))
            XCTAssertTrue(message.contains("safe/../outside"))
        }
        XCTAssertFalse(fs.exists("outside"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)
    }

    func testPlanForAbsentTreeHasNoPathsAndZeroBytes() throws {
        let fs = InMemoryStorageFileSystem()
        let catalog = StorageCatalog(
            areas: [makeArea(.caches, path: "cache-data")],
            fileSystem: fs
        )

        let plan = try catalog.plan(delete: .caches)

        XCTAssertEqual(plan.paths, [])
        XCTAssertEqual(plan.estimatedBytes, 0)
        XCTAssertEqual(plan.blockedBy, [])
        XCTAssertEqual(plan.postActions, [.invalidateRuntime("caches")])
        XCTAssertFalse(fs.exists("cache-data"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)
    }

    func testDuplicateAreaDefinitionsUseFirstDefinitionDeterministically() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("first/item", size: 7)
        fs.addFile("second/item", size: 99)
        let first = makeArea(.claudeInstall, path: "first", bootstrap: true)
        let second = makeArea(.claudeInstall, path: "second", bootstrap: false)
        let catalog = StorageCatalog(areas: [first, second], fileSystem: fs)

        let plan = try catalog.plan(delete: .claudeInstall)

        XCTAssertEqual(plan.paths, ["first"])
        XCTAssertEqual(plan.estimatedBytes, 7)
        XCTAssertEqual(plan.postActions, [.markNeedsBootstrap])
        XCTAssertTrue(fs.exists("first/item"))
        XCTAssertTrue(fs.exists("second/item"))
    }
}
