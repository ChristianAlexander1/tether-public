import XCTest
@testable import TetherStorageCore

final class ResolverSymlinkTests: XCTestCase {
    func testDepthThreeEscapingSymlinkNamesTheLink() {
        let fs = InMemoryStorageFileSystem()
        fs.addSymlink("work/one/two/link", destination: "/outside")
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertViolation(
            resolver.resolve("/work/one/two/link/file"),
            equals: .symlinkEscape(via: "work/one/two/link")
        )
        XCTAssertEqual(try? fs.destinationOfSymlink("work/one/two/link"), "/outside")
        XCTAssertTrue(fs.exists("work/one/two/link"))
        XCTAssertTrue(fs.isDirectory("work/one/two"))
        XCTAssertFalse(fs.isDirectory("work/one/two/link"))
    }

    func testInsideRelativeSymlinkResolvesThroughTarget() {
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("work/inside/dir")
        fs.addSymlink("work/link", destination: "inside/dir")
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertResolution(resolver.resolve("link"), equals: "inside/dir")
        XCTAssertResolution(resolver.resolve("link/file.txt"), equals: "inside/dir/file.txt")
        XCTAssertResolution(resolver.resolve("/work/link/../other"), equals: "inside/other")
        XCTAssertResolution(resolver.resolve("/work/inside/dir"), equals: "inside/dir")
        XCTAssertEqual(try? fs.destinationOfSymlink("work/link"), "inside/dir")
        XCTAssertTrue(fs.isDirectory("work/inside/dir"))
        XCTAssertEqual(try? fs.list("work"), ["inside", "link"])
    }

    func testAbsoluteTargetInsideRootIsAllowedAndOutsideTargetIsNot() {
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("work/inside")
        fs.addSymlink("work/absolute-inside", destination: "/work/inside")
        fs.addSymlink("work/absolute-outside", destination: "/outside")
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertResolution(resolver.resolve("absolute-inside/file"), equals: "inside/file")
        XCTAssertViolation(
            resolver.resolve("absolute-outside/file"),
            equals: .symlinkEscape(via: "work/absolute-outside")
        )
        XCTAssertTrue(fs.exists("work/absolute-inside"))
        XCTAssertTrue(fs.exists("work/absolute-outside"))
        XCTAssertEqual(try? fs.destinationOfSymlink("work/absolute-inside"), "/work/inside")
        XCTAssertEqual(try? fs.destinationOfSymlink("work/absolute-outside"), "/outside")
    }

    func testRelativeSymlinkThatClimbsAboveRootIsRejectedImmediately() {
        let fs = InMemoryStorageFileSystem()
        fs.addSymlink("work/link", destination: "../../outside")
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertViolation(
            resolver.resolve("/work/link"),
            equals: .symlinkEscape(via: "work/link")
        )
        XCTAssertViolation(
            resolver.resolve("link/child"),
            equals: .symlinkEscape(via: "work/link")
        )
        XCTAssertEqual(try? fs.destinationOfSymlink("work/link"), "../../outside")
        XCTAssertTrue(fs.exists("work/link"))
        XCTAssertTrue(fs.isDirectory("work"))
    }

    func testSymlinkCycleTerminatesWithBoundedFailure() {
        let fs = InMemoryStorageFileSystem()
        fs.addSymlink("work/a", destination: "b")
        fs.addSymlink("work/b", destination: "a")
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertViolation(
            resolver.resolve("a"),
            equals: .symlinkEscape(via: "work/a")
        )
        XCTAssertViolation(
            resolver.resolve("/work/b/child"),
            equals: .symlinkEscape(via: "work/b")
        )
        XCTAssertEqual(try? fs.destinationOfSymlink("work/a"), "b")
        XCTAssertEqual(try? fs.destinationOfSymlink("work/b"), "a")
        XCTAssertTrue(fs.exists("work/a"))
        XCTAssertTrue(fs.exists("work/b"))
        XCTAssertLessThanOrEqual(fs.removeTreeCallCount, 0)
    }

    func testSymlinkInAnAncestorIsCheckedBeforeLaterLexicalComponents() {
        let fs = InMemoryStorageFileSystem()
        fs.addSymlink("work/redirect", destination: "inside")
        fs.addDirectory("work/inside")
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertResolution(resolver.resolve("redirect/a/../b"), equals: "inside/b")
        XCTAssertResolution(resolver.resolve("redirect/./child"), equals: "inside/child")
        XCTAssertResolution(resolver.resolve("/work/redirect"), equals: "inside")
        XCTAssertEqual(try? fs.destinationOfSymlink("work/redirect"), "inside")
        XCTAssertTrue(fs.isDirectory("work/inside"))
        XCTAssertTrue(fs.isDirectory("work"))
    }
}
