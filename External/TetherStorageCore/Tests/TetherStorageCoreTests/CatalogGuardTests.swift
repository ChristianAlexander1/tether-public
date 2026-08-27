import XCTest
@testable import TetherStorageCore

final class CatalogGuardTests: XCTestCase {
    func testRootfsDeletePlanIsBlockedUntilSessionReleases() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("rootfs/bin/shell", size: 42)
        let catalog = StorageCatalog(
            areas: [makeArea(.linuxRootfs, path: "rootfs", bootstrap: true)],
            fileSystem: fs
        )
        let session = ActiveUseToken(owner: "terminal-1")

        catalog.acquire(session, on: .linuxRootfs)
        let blockedPlan = try catalog.plan(delete: .linuxRootfs)

        XCTAssertEqual(blockedPlan.paths, ["rootfs"])
        XCTAssertEqual(blockedPlan.estimatedBytes, 42)
        XCTAssertEqual(blockedPlan.blockedBy, [session])
        XCTAssertEqual(blockedPlan.postActions, [.markNeedsBootstrap])
        XCTAssertTrue(fs.exists("rootfs/bin/shell"))

        XCTAssertStorageError(
            try catalog.execute(blockedPlan),
            equals: .blocked([session])
        )
        XCTAssertTrue(fs.exists("rootfs"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)

        catalog.release(session, from: .linuxRootfs)
        let freshPlan = try catalog.plan(delete: .linuxRootfs)
        let actions = try catalog.execute(freshPlan)

        XCTAssertEqual(freshPlan.blockedBy, [])
        XCTAssertEqual(actions, [.markNeedsBootstrap])
        XCTAssertFalse(fs.exists("rootfs"))
        XCTAssertEqual(fs.removeTreeCallCount, 1)
    }

    func testAcquireBetweenPlanAndExecuteBlocksExecution() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("runtime/bin/tool", size: 5)
        let catalog = StorageCatalog(
            areas: [makeArea(.nodeHome, path: "runtime")],
            fileSystem: fs
        )
        let token = ActiveUseToken(owner: "late-session")

        let plan = try catalog.plan(delete: .nodeHome)
        catalog.acquire(token, on: .nodeHome)

        XCTAssertEqual(plan.blockedBy, [])
        XCTAssertEqual(plan.paths, ["runtime"])
        XCTAssertStorageError(try catalog.execute(plan), equals: .blocked([token]))
        XCTAssertTrue(fs.exists("runtime/bin/tool"))
        XCTAssertEqual(fs.removeTreeCallCount, 0)

        catalog.release(token, from: .nodeHome)
        XCTAssertEqual(try catalog.execute(plan), [.invalidateRuntime("node")])
        XCTAssertFalse(fs.exists("runtime"))
        XCTAssertEqual(fs.removeTreeCallCount, 1)
    }

    func testIdempotentAcquireRequiresMatchingReleasesAndReportsOneToken() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("root")
        let catalog = StorageCatalog(
            areas: [makeArea(.linuxRootfs, path: "root", bootstrap: true)],
            fileSystem: fs
        )
        let token = ActiveUseToken(owner: "same-owner")

        catalog.acquire(token, on: .linuxRootfs)
        catalog.acquire(token, on: .linuxRootfs)
        let twiceAcquired = try catalog.plan(delete: .linuxRootfs)

        XCTAssertEqual(twiceAcquired.blockedBy, [token])
        XCTAssertEqual(twiceAcquired.blockedBy.count, 1)
        XCTAssertStorageError(try catalog.execute(twiceAcquired), equals: .blocked([token]))

        catalog.release(token, from: .linuxRootfs)
        let onceReleased = try catalog.plan(delete: .linuxRootfs)
        XCTAssertEqual(onceReleased.blockedBy, [token])
        XCTAssertEqual(onceReleased.blockedBy.count, 1)
        XCTAssertStorageError(try catalog.execute(onceReleased), equals: .blocked([token]))

        catalog.release(token, from: .linuxRootfs)
        let balanced = try catalog.plan(delete: .linuxRootfs)
        XCTAssertEqual(balanced.blockedBy, [])
        XCTAssertEqual(try catalog.execute(balanced), [.markNeedsBootstrap])
        XCTAssertFalse(fs.exists("root"))
    }

    func testTwoOwnersAreSortedAndUnmatchedReleaseDoesNotAffectThem() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("shared")
        let catalog = StorageCatalog(
            areas: [makeArea(.claudeInstall, path: "shared")],
            fileSystem: fs
        )
        let zed = ActiveUseToken(owner: "zed")
        let amy = ActiveUseToken(owner: "amy")
        let unknown = ActiveUseToken(owner: "unknown")

        catalog.acquire(zed, on: .claudeInstall)
        catalog.acquire(amy, on: .claudeInstall)
        catalog.release(unknown, from: .claudeInstall)
        let plan = try catalog.plan(delete: .claudeInstall)

        XCTAssertEqual(plan.blockedBy, [amy, zed])
        XCTAssertEqual(plan.blockedBy.map(\.owner), ["amy", "zed"])
        XCTAssertEqual(plan.blockedBy.count, 2)
        XCTAssertStorageError(try catalog.execute(plan), equals: .blocked([amy, zed]))
        XCTAssertTrue(fs.exists("shared"))

        catalog.release(amy, from: .claudeInstall)
        XCTAssertEqual(try catalog.plan(delete: .claudeInstall).blockedBy, [zed])
        catalog.release(zed, from: .claudeInstall)
        XCTAssertEqual(try catalog.plan(delete: .claudeInstall).blockedBy, [])
        XCTAssertEqual(fs.removeTreeCallCount, 0)
    }

    func testUnknownAreaLeaseCallsAreHarmless() throws {
        let fs = InMemoryStorageFileSystem()
        let catalog = StorageCatalog(areas: [], fileSystem: fs)
        let token = ActiveUseToken(owner: "orphan")
        let unknown = ManagedAreaID(rawValue: "unknown")

        catalog.acquire(token, on: unknown)
        catalog.release(token, from: unknown)

        XCTAssertStorageError(try catalog.plan(delete: unknown), equals: .unknownArea)
        XCTAssertEqual(fs.removeTreeCallCount, 0)
        XCTAssertFalse(fs.exists("anything"))
    }
}
