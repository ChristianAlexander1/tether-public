import XCTest
@testable import TetherStorageCore

final class CatalogExecuteTests: XCTestCase {
    func testMissingTreePlanExecutesTriviallyAndReturnsPostActions() throws {
        let fs = InMemoryStorageFileSystem()
        let catalog = StorageCatalog(
            areas: [makeArea(.pythonPackages, path: "python-store")],
            fileSystem: fs
        )

        let plan = try catalog.plan(delete: .pythonPackages)
        let actions = try catalog.execute(plan)

        XCTAssertEqual(plan.paths, [])
        XCTAssertEqual(plan.estimatedBytes, 0)
        XCTAssertEqual(actions, [.invalidateRuntime("python")])
        XCTAssertFalse(fs.exists("python-store"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)
    }

    func testSecondRemoveFailureReportsCompletedAndRemainingPaths() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("bundle/first/file", size: 1)
        fs.addFile("bundle/second/file", size: 2)
        fs.addFile("bundle/third/file", size: 3)
        fs.failRemoveTree(onCall: 2, message: "intentional second removal failure")
        let catalog = StorageCatalog(
            areas: [makeArea(.caches, path: "bundle")],
            fileSystem: fs
        )
        let plan = DeletePlan(
            area: .caches,
            paths: ["bundle/first", "bundle/second", "bundle/third"],
            estimatedBytes: 6,
            blockedBy: [],
            postActions: [.invalidateRuntime("caches")]
        )

        XCTAssertThrowsError(try catalog.execute(plan)) { error in
            guard let storageError = error as? StorageError,
                  case .io(let message) = storageError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("bundle/first"))
            XCTAssertTrue(message.contains("bundle/second"))
            XCTAssertTrue(message.contains("bundle/third"))
            XCTAssertTrue(message.contains("successfully removed paths"))
            XCTAssertTrue(message.contains("remaining paths"))
            XCTAssertTrue(message.contains("intentional second removal failure"))
        }
        XCTAssertFalse(fs.exists("bundle/first"))
        XCTAssertTrue(fs.exists("bundle/second"))
        XCTAssertTrue(fs.exists("bundle/third"))
        XCTAssertEqual(fs.removeTreeCallCount, 2)
        XCTAssertEqual(try fs.sizeOfTree("bundle"), 5)
    }

    func testExecuteRejectsForgedPathOutsideTheManagedArea() {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("allowed/file", size: 1)
        fs.addFile("other/file", size: 1)
        let catalog = StorageCatalog(
            areas: [makeArea(.nodeHome, path: "allowed")],
            fileSystem: fs
        )
        let forged = DeletePlan(
            area: .nodeHome,
            paths: ["other"],
            estimatedBytes: 1,
            blockedBy: [],
            postActions: [.none]
        )

        XCTAssertThrowsError(try catalog.execute(forged)) { error in
            guard let storageError = error as? StorageError,
                  case .io(let message) = storageError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("invalid delete plan path"))
            XCTAssertTrue(message.contains("other"))
        }
        XCTAssertTrue(fs.exists("allowed/file"))
        XCTAssertTrue(fs.exists("other/file"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)
    }

    func testExecuteRechecksAreaExistenceAndDeletabilityForForgedPlans() {
        let fs = InMemoryStorageFileSystem()
        let disabled = makeArea(.claudeInstall, path: "disabled", deletable: false)
        let catalog = StorageCatalog(areas: [disabled], fileSystem: fs)
        let unknownPlan = DeletePlan(
            area: .caches,
            paths: [],
            estimatedBytes: 0,
            blockedBy: [],
            postActions: []
        )
        let disabledPlan = DeletePlan(
            area: .claudeInstall,
            paths: [],
            estimatedBytes: 0,
            blockedBy: [],
            postActions: []
        )

        XCTAssertStorageError(try catalog.execute(unknownPlan), equals: .unknownArea)
        XCTAssertStorageError(try catalog.execute(disabledPlan), equals: .notDeletable)
        XCTAssertEqual(fs.removeTreeCallCount, 0)
        XCTAssertFalse(fs.exists("disabled"))
    }

    func testExecuteReturnsPlanActionsVerbatimOnSuccess() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("owned/file", size: 4)
        let catalog = StorageCatalog(
            areas: [makeArea(.nodeHome, path: "owned")],
            fileSystem: fs
        )
        let plan = DeletePlan(
            area: .nodeHome,
            paths: ["owned"],
            estimatedBytes: 4,
            blockedBy: [],
            postActions: [.none, .invalidateRuntime("caller-selected")]
        )

        let returned = try catalog.execute(plan)

        XCTAssertEqual(returned, [.none, .invalidateRuntime("caller-selected")])
        XCTAssertFalse(fs.exists("owned"))
        XCTAssertEqual(fs.removeTreeCallCount, 1)
        XCTAssertEqual(plan.estimatedBytes, 4)
        XCTAssertEqual(plan.blockedBy, [])
    }
}
