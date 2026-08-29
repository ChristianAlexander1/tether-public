import XCTest
@testable import TermXNode

/// The pump drains the *login PTY slave* — the same open file description the
/// guest shell reads from. Anything it does to that descriptor is done to the
/// shell too, so its cleanup is a correctness requirement, not hygiene.
final class NodeStdinPumpTests: XCTestCase {

    /// The pump sets O_NONBLOCK so its own reads never park. It must hand the
    /// original flags back on the way out: the flag lives on the shared open
    /// file description, so leaking it left the guest shell's own `read()`
    /// non-blocking for the rest of the session after the first host-backed
    /// job — permanently, and with no visible error.
    func testStopRestoresTheOriginalDescriptorFlags() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer {
            close(readFD)
            close(writeFD)
        }

        let before = fcntl(readFD, F_GETFL)
        XCTAssertEqual(before & O_NONBLOCK, 0, "precondition: pipe starts blocking")

        let pump = NodeStdinPump(fd: readFD) { _ in }
        pump.start()
        pump.stop()

        let after = fcntl(readFD, F_GETFL)
        XCTAssertEqual(
            after, before,
            "pump leaked descriptor flags onto the fd the guest shell shares"
        )
        XCTAssertEqual(
            after & O_NONBLOCK, 0,
            "O_NONBLOCK survived stop(); the guest shell's reads are now non-blocking"
        )
    }

    /// `stop()` must not return while the reader thread can still consume a
    /// byte. A pump that outlived its job swallowed the first keystrokes of the
    /// next prompt, so a typed `claude` arrived at the shell as `clclaude`.
    func testStopIsSynchronousSoNoByteIsStolenAfterwards() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer {
            close(readFD)
            close(writeFD)
        }

        let seen = NSMutableData()
        let lock = NSLock()
        let pump = NodeStdinPump(fd: readFD) { data in
            lock.lock()
            seen.append(data)
            lock.unlock()
        }
        pump.start()
        pump.stop()

        // Everything written after stop() returned belongs to whoever reads
        // next — the pump must not take any of it.
        let afterStop = Data("claude\n".utf8)
        afterStop.withUnsafeBytes { raw in
            _ = write(writeFD, raw.baseAddress!, afterStop.count)
        }
        Thread.sleep(forTimeInterval: 0.4)

        lock.lock()
        let stolen = seen.length
        lock.unlock()
        XCTAssertEqual(stolen, 0, "pump consumed bytes after stop() returned")

        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(readFD, &buf, buf.count)
        XCTAssertEqual(n, afterStop.count, "bytes written after stop() must still be readable")
    }

    /// stop() on a pump that was never started must return immediately rather
    /// than waiting on a semaphore no thread will ever signal.
    func testStopWithoutStartDoesNotBlock() {
        let pump = NodeStdinPump(fd: -1) { _ in }
        let started = Date()
        pump.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}
