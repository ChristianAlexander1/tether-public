import XCTest
@testable import TermXNode

final class NodeStdinSlurpTests: XCTestCase {
    func testReadPipeSlurpsBytesAndEOF() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer {
            close(readFD)
            close(writeFD)
        }

        let payload = Data("hello pipe\n".utf8)
        payload.withUnsafeBytes { raw in
            _ = write(writeFD, raw.baseAddress!, payload.count)
        }
        close(writeFD)

        let slurped = NodeStdinSlurp.readPipeIfNeeded(fd: readFD)
        XCTAssertEqual(slurped, payload)
    }

    func testTTYReturnsNil() {
        XCTAssertNil(NodeStdinSlurp.readPipeIfNeeded(fd: -1))
    }
}
