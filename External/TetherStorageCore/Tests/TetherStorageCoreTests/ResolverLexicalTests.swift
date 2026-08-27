import XCTest
@testable import TetherStorageCore

final class ResolverLexicalTests: XCTestCase {
    func testRequiredAbsoluteAndEmptyLexicalCases() {
        let fs = InMemoryStorageFileSystem()
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertResolution(resolver.resolve("/work/a/../b"), equals: "b")
        XCTAssertViolation(resolver.resolve("/work/../etc/passwd"), equals: .dotDotEscape)
        XCTAssertViolation(resolver.resolve("/etc/passwd"), equals: .absoluteOutsideRoot)
        XCTAssertViolation(resolver.resolve(""), equals: .emptyPath)
        XCTAssertViolation(resolver.resolve("   "), equals: .emptyPath)
        XCTAssertResolution(resolver.resolve("/work"), equals: "")
        XCTAssertResolution(resolver.resolve("."), equals: "")
        XCTAssertResolution(resolver.resolve("folder/./child"), equals: "folder/child")
        XCTAssertViolation(resolver.resolve("../folder"), equals: .dotDotEscape)
        XCTAssertViolation(resolver.resolve("/work/../../again"), equals: .dotDotEscape)
    }

    func testRelativeTraversalAndRepeatedSlashNormalization() {
        let fs = InMemoryStorageFileSystem()
        let resolver = ConfinedPathResolver(confinementRoot: "/work", fileSystem: fs)

        XCTAssertResolution(resolver.resolve("a/b/../c"), equals: "a/c")
        XCTAssertResolution(resolver.resolve("//work///one//two"), equals: "one/two")
        XCTAssertResolution(resolver.resolve("/work/a/.."), equals: "")
        XCTAssertResolution(resolver.resolve("one//two///three"), equals: "one/two/three")
        XCTAssertViolation(resolver.resolve("/workish/file"), equals: .absoluteOutsideRoot)
        XCTAssertViolation(resolver.resolve("/other/../work/file"), equals: .absoluteOutsideRoot)
        XCTAssertViolation(resolver.resolve("/work/../work/file"), equals: .dotDotEscape)
        XCTAssertResolution(resolver.resolve("/work/.hidden"), equals: ".hidden")
    }

    func testRootAdjacentPrefixDoesNotPassComponentBoundaryCheck() {
        let fs = InMemoryStorageFileSystem()
        let resolver = ConfinedPathResolver(confinementRoot: "/data/app", fileSystem: fs)

        XCTAssertViolation(resolver.resolve("/data/appendix"), equals: .absoluteOutsideRoot)
        XCTAssertViolation(resolver.resolve("/data/application/file"), equals: .absoluteOutsideRoot)
        XCTAssertResolution(resolver.resolve("/data/app/file"), equals: "file")
        XCTAssertResolution(resolver.resolve("/data/app/sub/../next"), equals: "next")
        XCTAssertViolation(resolver.resolve("/data/app/../appendix"), equals: .dotDotEscape)
        XCTAssertViolation(resolver.resolve("/data/ap"), equals: .absoluteOutsideRoot)
        XCTAssertResolution(resolver.resolve("inside"), equals: "inside")
    }

    func testUnicodeAndSpaceComponentsArePreservedByteForByte() {
        let fs = InMemoryStorageFileSystem()
        let root = "/data space/🧪"
        let resolver = ConfinedPathResolver(confinementRoot: root, fileSystem: fs)

        XCTAssertResolution(
            resolver.resolve("/data space/🧪/ folder ü /東京/naïve file.txt"),
            equals: " folder ü /東京/naïve file.txt"
        )
        XCTAssertResolution(resolver.resolve("emoji 🐚/two words"), equals: "emoji 🐚/two words")
        XCTAssertResolution(resolver.resolve("/data space/🧪/a/../ß"), equals: "ß")
        XCTAssertViolation(resolver.resolve("/data space/🧪/../外"), equals: .dotDotEscape)
        XCTAssertViolation(resolver.resolve("/data space/🧪x/file"), equals: .absoluteOutsideRoot)
        XCTAssertResolution(resolver.resolve(" /leading space"), equals: " /leading space")
        XCTAssertResolution(resolver.resolve("trailing space "), equals: "trailing space ")
    }

    func testRootSlashAllowsAllDescendantsButStillRejectsUpwardTraversal() {
        let fs = InMemoryStorageFileSystem()
        let resolver = ConfinedPathResolver(confinementRoot: "/", fileSystem: fs)

        XCTAssertResolution(resolver.resolve("/etc/passwd"), equals: "etc/passwd")
        XCTAssertResolution(resolver.resolve("relative/path"), equals: "relative/path")
        XCTAssertResolution(resolver.resolve("/a/../b"), equals: "b")
        XCTAssertViolation(resolver.resolve("../outside"), equals: .dotDotEscape)
        XCTAssertViolation(resolver.resolve("/../outside"), equals: .dotDotEscape)
        XCTAssertResolution(resolver.resolve("/"), equals: "")
    }
}
