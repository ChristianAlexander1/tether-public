import Foundation
import XCTest
@testable import TermXLinux

/// `LinuxPathMapper` now delegates its confinement checks to
/// `ConfinedPathResolver`. These are the cases the previous prefix-and-leaf
/// implementation could not catch.
final class PathConfinementTests: XCTestCase {
    private var tmp: URL!
    private var workspaces: URL!
    private var outside: URL!
    private var mapper: LinuxPathMapper!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspaces = tmp.appendingPathComponent("workspaces")
        outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        mapper = LinuxPathMapper(workspacesHostRoot: workspaces, homeHostRoot: tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testOrdinaryPathInsideTheWorkspaceResolves() throws {
        let project = workspaces.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let resolved = try mapper.hostPath(forGuestPath: "/workspaces/project/main.swift")
        XCTAssertTrue(resolved.hasSuffix("/project/main.swift"))
    }

    /// A symlink in an *ancestor* — the old check resolved only the nearest
    /// existing ancestor of the whole path, so a link partway down could be
    /// missed when deeper components existed.
    func testSymlinkInAnAncestorIsRejectedNotJustAtTheLeaf() throws {
        let link = workspaces.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let deep = outside.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertThrowsError(try mapper.hostPath(forGuestPath: "/workspaces/escape/a/b/file.txt"))
    }

    /// `..` must not be able to climb out, even when it is later "cancelled".
    func testDotDotEscapeIsRejected() {
        XCTAssertThrowsError(try mapper.hostPath(forGuestPath: "/workspaces/../outside/secret"))
    }

    /// A component-prefix collision: `/workspaces-elsewhere` shares the string
    /// prefix `/workspaces` but is a different directory.
    func testComponentPrefixConfusionIsRejected() {
        XCTAssertThrowsError(try mapper.hostPath(forGuestPath: "/workspaces-elsewhere/file"))
    }

    /// A symlink cycle must terminate with a rejection rather than spin.
    func testSymlinkCycleTerminates() throws {
        let a = workspaces.appendingPathComponent("a")
        let b = workspaces.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

        let expectation = XCTestExpectation(description: "resolution terminates")
        DispatchQueue.global().async {
            _ = try? self.mapper.hostPath(forGuestPath: "/workspaces/a/file")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testWorkPathMapsTheSelectedFolder() throws {
        let work = tmp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        mapper.workHostRoot = work
        let resolved = try mapper.hostPath(forGuestPath: "/work/src/main.c")
        XCTAssertTrue(resolved.hasSuffix("/project/src/main.c"))
        XCTAssertEqual(
            try mapper.hostPath(forGuestPath: "/work"),
            work.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testWorkPathRejectsEscapeAndPrefixCollision() {
        mapper.workHostRoot = workspaces
        XCTAssertThrowsError(try mapper.hostPath(forGuestPath: "/work/../outside/secret"))
        XCTAssertThrowsError(try mapper.hostPath(forGuestPath: "/workish/file"))
    }

    func testWorkspacesRootItselfResolves() throws {
        let resolved = try mapper.hostPath(forGuestPath: "/workspaces")
        XCTAssertFalse(resolved.isEmpty)
    }
}
