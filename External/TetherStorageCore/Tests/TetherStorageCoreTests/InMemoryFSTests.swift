import XCTest
@testable import TetherStorageCore

final class InMemoryFSTests: XCTestCase {
    func testNestedTreesCreateParentsListImmediateEntriesAndMeasureSize() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("alpha/beta/one.txt", size: 10)
        fs.addFile("alpha/beta/two.txt", size: 20)
        fs.addFile("alpha/gamma/three.txt", size: 30)

        XCTAssertTrue(fs.exists("alpha"))
        XCTAssertTrue(fs.exists("alpha/beta"))
        XCTAssertTrue(fs.exists("alpha/beta/one.txt"))
        XCTAssertTrue(fs.isDirectory("alpha"))
        XCTAssertTrue(fs.isDirectory("alpha/beta"))
        XCTAssertFalse(fs.isDirectory("alpha/beta/one.txt"))
        XCTAssertEqual(try fs.list("alpha"), ["beta", "gamma"])
        XCTAssertEqual(try fs.list("alpha/beta"), ["one.txt", "two.txt"])
        XCTAssertEqual(try fs.sizeOfTree("alpha"), 60)
        XCTAssertEqual(try fs.sizeOfTree("alpha/beta"), 30)
        XCTAssertEqual(try fs.sizeOfTree("alpha/gamma/three.txt"), 30)
        XCTAssertEqual(try fs.sizeOfTree("/alpha"), 60)
        XCTAssertTrue(fs.exists("/alpha/beta/two.txt"))
    }

    func testSymlinksAreStoredVerbatimAndAreNotFollowedForSizingOrDeletion() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("target/payload", size: 44)
        fs.addSymlink("links/to-target", destination: "../target")
        fs.addSymlink("links/outside", destination: "/outside")

        XCTAssertTrue(fs.exists("links/to-target"))
        XCTAssertFalse(fs.isDirectory("links/to-target"))
        XCTAssertEqual(try fs.destinationOfSymlink("links/to-target"), "../target")
        XCTAssertEqual(try fs.destinationOfSymlink("links/outside"), "/outside")
        XCTAssertNil(try fs.destinationOfSymlink("target"))
        XCTAssertNil(try fs.destinationOfSymlink("missing"))
        XCTAssertEqual(try fs.sizeOfTree("links"), 0)
        XCTAssertEqual(try fs.list("links"), ["outside", "to-target"])

        try fs.removeTree("links/to-target")

        XCTAssertFalse(fs.exists("links/to-target"))
        XCTAssertTrue(fs.exists("target/payload"))
        XCTAssertTrue(fs.exists("links/outside"))
        XCTAssertEqual(try fs.sizeOfTree("target"), 44)
        XCTAssertEqual(fs.removeTreeCallCount, 1)
    }

    func testRemoveTreeRemovesNestedChildrenButNotSiblingTrees() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("top/remove/deep/file", size: 1)
        fs.addFile("top/keep/file", size: 2)
        fs.addFile("other/file", size: 3)

        try fs.removeTree("top/remove")

        XCTAssertFalse(fs.exists("top/remove"))
        XCTAssertFalse(fs.exists("top/remove/deep/file"))
        XCTAssertTrue(fs.exists("top/keep"))
        XCTAssertTrue(fs.exists("top/keep/file"))
        XCTAssertTrue(fs.exists("other/file"))
        XCTAssertEqual(try fs.list("top"), ["keep"])
        XCTAssertEqual(try fs.sizeOfTree("top"), 2)
        XCTAssertEqual(try fs.sizeOfTree("other"), 3)
        XCTAssertEqual(fs.removeTreeCallCount, 1)
    }

    func testScriptedRemoveFailureIsDeterministicAndNonMutating() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("tree/file", size: 8)
        fs.failRemoveTree(onCall: 1, message: "planned failure")

        XCTAssertThrowsError(try fs.removeTree("tree")) { error in
            XCTAssertEqual(
                error as? InMemoryStorageFileSystemError,
                .scriptedRemoveFailure("planned failure")
            )
        }
        XCTAssertTrue(fs.exists("tree"))
        XCTAssertTrue(fs.exists("tree/file"))
        XCTAssertEqual(fs.removeTreeCallCount, 1)

        fs.clearRemoveTreeFailures()
        try fs.removeTree("tree")

        XCTAssertFalse(fs.exists("tree"))
        XCTAssertEqual(fs.removeTreeCallCount, 2)
        XCTAssertFalse(fs.exists("tree/file"))
    }

    func testInvalidAndMissingPathsHaveDefinedBehavior() {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("safe/file", size: 1)
        fs.addFile("../ignored", size: 9)

        XCTAssertFalse(fs.exists("../ignored"))
        XCTAssertFalse(fs.isDirectory("../ignored"))
        XCTAssertTrue(fs.exists("safe/file"))
        XCTAssertThrowsError(try fs.sizeOfTree("../ignored")) { error in
            XCTAssertEqual(error as? InMemoryStorageFileSystemError, .invalidPath("../ignored"))
        }
        XCTAssertThrowsError(try fs.removeTree("missing")) { error in
            XCTAssertEqual(error as? InMemoryStorageFileSystemError, .notFound("missing"))
        }
        XCTAssertThrowsError(try fs.list("safe/file")) { error in
            XCTAssertEqual(error as? InMemoryStorageFileSystemError, .notDirectory("safe/file"))
        }
        XCTAssertThrowsError(try fs.removeTree("/")) { error in
            XCTAssertEqual(error as? InMemoryStorageFileSystemError, .cannotRemoveVirtualRoot)
        }
        XCTAssertEqual(fs.removeTreeCallCount, 2)
    }

    func testInt64SizingDoesNotUseInt32ArithmeticAndSaturatesSafely() throws {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("large/first", size: Int64(Int32.max))
        fs.addFile("large/second", size: Int64(Int32.max) + 1)
        fs.addFile("huge/a", size: Int64.max)
        fs.addFile("huge/b", size: 1)

        XCTAssertEqual(try fs.sizeOfTree("large"), Int64(Int32.max) * 2 + 1)
        XCTAssertTrue(try fs.sizeOfTree("large") > Int64(Int32.max))
        XCTAssertEqual(try fs.sizeOfTree("huge"), Int64.max)
        XCTAssertEqual(try fs.sizeOfTree("huge/a"), Int64.max)
        XCTAssertEqual(try fs.sizeOfTree("huge/b"), 1)
        XCTAssertTrue(fs.isDirectory("large"))
        XCTAssertTrue(fs.isDirectory("huge"))
    }
}
