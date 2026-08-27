import XCTest
@testable import TetherStorageCore

final class IntegrityTests: XCTestCase {
    func testMissingMarkerAndEscapingInternalSymlinkAreReported() {
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("rootfs")
        fs.addFile("rootfs/etc/hostname", size: 3)
        fs.addSymlink("rootfs/escape-link", destination: "../../outside")
        let catalog = StorageCatalog(
            areas: [makeArea(
                .linuxRootfs,
                path: "rootfs",
                bootstrap: true,
                markers: ["etc/alpine-release", "etc/hostname"]
            )],
            fileSystem: fs
        )

        let report = catalog.integrityReport(for: .linuxRootfs)

        XCTAssertEqual(report.area, .linuxRootfs)
        XCTAssertTrue(report.present)
        XCTAssertEqual(report.missingMarkers, ["etc/alpine-release"])
        XCTAssertEqual(report.suspectPaths, ["escape-link"])
        XCTAssertTrue(fs.exists("rootfs/etc/hostname"))
        XCTAssertEqual(try? fs.destinationOfSymlink("rootfs/escape-link"), "../../outside")
        XCTAssertTrue(fs.isDirectory("rootfs"))
    }

    func testNestedSuspectsAreAreaRelativeAndSafeSymlinksAreIgnored() {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("tree/bin/tool", size: 1)
        fs.addSymlink("tree/deep/unsafe", destination: "../../../outside")
        fs.addSymlink("tree/deep/inside", destination: "../bin/tool")
        let catalog = StorageCatalog(
            areas: [makeArea(.nodeHome, path: "tree", markers: ["bin/tool"])],
            fileSystem: fs
        )

        let report = catalog.integrityReport(for: .nodeHome)

        XCTAssertTrue(report.present)
        XCTAssertEqual(report.missingMarkers, [])
        XCTAssertEqual(report.suspectPaths, ["deep/unsafe"])
        XCTAssertFalse(report.suspectPaths.contains("deep/inside"))
        XCTAssertEqual(try? fs.destinationOfSymlink("tree/deep/inside"), "../bin/tool")
        XCTAssertTrue(fs.isDirectory("tree/deep"))
        XCTAssertEqual(try? fs.list("tree"), ["bin", "deep"])
    }

    func testAbsentAreaReportsAbsentAndAllExpectedMarkersMissing() {
        let fs = InMemoryStorageFileSystem()
        let catalog = StorageCatalog(
            areas: [makeArea(
                .pythonPackages,
                path: "packages",
                markers: ["site-packages", "metadata/version"]
            )],
            fileSystem: fs
        )

        let report = catalog.integrityReport(for: .pythonPackages)

        XCTAssertEqual(report.area, .pythonPackages)
        XCTAssertFalse(report.present)
        XCTAssertEqual(report.missingMarkers, ["site-packages", "metadata/version"])
        XCTAssertEqual(report.suspectPaths, [])
        XCTAssertFalse(fs.exists("packages"))
        XCTAssertFalse(fs.isDirectory("packages"))
    }

    func testUnknownAreaAndInvalidMarkerHaveSafeReports() {
        let fs = InMemoryStorageFileSystem()
        fs.addDirectory("cache")
        let catalog = StorageCatalog(
            areas: [makeArea(.caches, path: "cache", markers: ["../bad", "valid-marker"])],
            fileSystem: fs
        )

        let known = catalog.integrityReport(for: .caches)
        let unknown = catalog.integrityReport(for: ManagedAreaID(rawValue: "not-registered"))

        XCTAssertTrue(known.present)
        XCTAssertEqual(known.missingMarkers, ["../bad", "valid-marker"])
        XCTAssertEqual(known.suspectPaths, [])
        XCTAssertFalse(unknown.present)
        XCTAssertEqual(unknown.missingMarkers, [])
        XCTAssertEqual(unknown.suspectPaths, [])
        XCTAssertEqual(unknown.area.rawValue, "not-registered")
    }

    func testAFileAtAreaPathIsNotReportedAsPresentDirectory() {
        let fs = InMemoryStorageFileSystem()
        fs.addFile("not-a-tree", size: 12)
        let catalog = StorageCatalog(
            areas: [makeArea(.claudeInstall, path: "not-a-tree", markers: ["marker"])],
            fileSystem: fs
        )

        let report = catalog.integrityReport(for: .claudeInstall)

        XCTAssertFalse(report.present)
        XCTAssertEqual(report.missingMarkers, ["marker"])
        XCTAssertEqual(report.suspectPaths, [])
        XCTAssertTrue(fs.exists("not-a-tree"))
        XCTAssertFalse(fs.isDirectory("not-a-tree"))
        XCTAssertEqual(try? fs.sizeOfTree("not-a-tree"), 12)
    }
}
