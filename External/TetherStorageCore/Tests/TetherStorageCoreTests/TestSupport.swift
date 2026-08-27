import XCTest
@testable import TetherStorageCore

func XCTAssertResolution(
    _ result: Result<String, ConfinementViolation>,
    equals expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch result {
    case .success(let actual):
        XCTAssertEqual(actual, expected, file: file, line: line)
    case .failure(let violation):
        XCTFail("expected success \(expected), got \(violation)", file: file, line: line)
    }
}

func XCTAssertViolation(
    _ result: Result<String, ConfinementViolation>,
    equals expected: ConfinementViolation,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch result {
    case .success(let path):
        XCTFail("expected violation \(expected), got success \(path)", file: file, line: line)
    case .failure(let actual):
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

func XCTAssertStorageError(
    _ expression: @autoclosure () throws -> Any,
    equals expected: StorageError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        XCTFail("expected storage error \(expected)", file: file, line: line)
    } catch let actual as StorageError {
        XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
        XCTFail("expected StorageError, got \(error)", file: file, line: line)
    }
}

func makeArea(
    _ id: ManagedAreaID,
    path: String,
    deletable: Bool = true,
    bootstrap: Bool = false,
    markers: [String] = []
) -> ManagedArea {
    ManagedArea(
        id: id,
        displayName: id.rawValue,
        relativePath: path,
        deletable: deletable,
        requiresRebootstrapAfterDelete: bootstrap,
        expectedMarkers: markers
    )
}
