import XCTest
@testable import TermXLinux

/// Real Blink/Alpine acceptance suite; see docs/VALIDATION.md.
///
/// Requires network. The embedded Blink VFS (`termx_blink_init`) is process-wide,
/// so this class shares one bootstrapped service. Per-test scratch directories
/// would leave later cases writing into the first rootfs.
final class C6AcceptanceTests: XCTestCase {
    private static var sharedScratch: URL?
    private static var sharedService: BlinkLinuxService?

    private var scratch: URL { Self.sharedScratch! }
    private var service: BlinkLinuxService { Self.sharedService! }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TETHER_LINUX_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set TETHER_LINUX_NETWORK_TESTS=1 to run real Blink/Alpine acceptance tests")
        }
        if Self.sharedService != nil { return }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-c6-\(UUID().uuidString)", isDirectory: true)
        let rootfs = scratch.appendingPathComponent("rootfs", isDirectory: true)
        let workspaces = scratch.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        Self.sharedScratch = scratch
        Self.sharedService = BlinkLinuxService(rootfs: rootfs, workspacesHostRoot: workspaces)
    }

    override class func tearDown() {
        if let scratch = sharedScratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        sharedScratch = nil
        sharedService = nil
    }

    private func runGuest(_ cmdline: String, timeout: TimeInterval = 120) async throws -> (code: Int32, out: String, err: String) {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw LinuxGuestError.bootstrapFailed("pipe() failed")
        }
        // Drain while the guest runs. Waiting until exit fills the pipe and
        // deadlocks apk/compilers; the embed lane also used to leak the write
        // end onto process stdout, so a post-exit read never saw EOF.
        let stdoutDrain = PipeDrain(fd: outPipe[0])
        let stderrDrain = PipeDrain(fd: errPipe[0])
        stdoutDrain.start()
        stderrDrain.start()

        let argv = ["/bin/sh", "-c", cmdline]
        let runTask = Task {
            await service.run(
                argv: argv,
                cwd: "/",
                stdinFD: -1,
                stdoutFD: outPipe[1],
                stderrFD: errPipe[1],
                interactive: false
            )
        }

        enum RaceResult: Sendable {
            case completed(Int32)
            case timedOut
        }
        let race = await withTaskGroup(of: RaceResult.self) { group in
            group.addTask { .completed(await runTask.value) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            if case .timedOut = first {
                // Interrupt before leaving the group: its scope waits for child
                // tasks, so interrupting afterward deadlocks on a hung guest.
                service.interrupt()
            }
            group.cancelAll()
            return first
        }
        close(outPipe[1])
        close(errPipe[1])
        let out = stdoutDrain.finish()
        let err = stderrDrain.finish()
        switch race {
        case .completed(let code):
            return (code, out, err)
        case .timedOut:
            throw TimeoutError()
        }
    }

    func testC6BootstrapAndBusyBoxSelfTest() async throws {
        try await service.bootstrap()
        XCTAssertEqual(service.state, .ready)

        let list = try await runGuest("busybox --list | wc -l")
        XCTAssertEqual(list.code, 0, list.err)
        XCTAssertGreaterThan(Int(list.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 100)

        let help = try await runGuest("busybox echo ok")
        XCTAssertEqual(help.code, 0, help.err)
        XCTAssertTrue(help.out.contains("ok"))
    }

    func testC6ApkAddPackages() async throws {
        try await service.bootstrap()
        let apk = try await runGuest("/sbin/apk add --no-cache python3 figlet gcc make", timeout: 300)
        XCTAssertEqual(apk.code, 0, apk.out + apk.err)

        let py = try await runGuest("python3 -c 'print(2+2)'")
        XCTAssertEqual(py.code, 0, py.err)
        XCTAssertTrue(py.out.contains("4"))

        let fig = try await runGuest("figlet test")
        XCTAssertEqual(fig.code, 0, fig.err)
        XCTAssertFalse(fig.out.isEmpty)
    }

    func testC6GuestPipeline() async throws {
        try await service.bootstrap()
        let pipe = try await runGuest("ls /bin | wc -l")
        XCTAssertEqual(pipe.code, 0, pipe.err)
        XCTAssertGreaterThan(Int(pipe.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 10)

        // Two-stage pipeline must exit 0: the child's exit path used to
        // longjmp into the parent's jmp_buf and print "Segmentation fault".
        let echo = try await runGuest("echo hello | cat; echo status:$?")
        XCTAssertEqual(echo.code, 0, echo.err)
        XCTAssertTrue(echo.out.contains("hello"), echo.out)
        XCTAssertTrue(echo.out.contains("status:0"), echo.out)
    }

    func testC6WorkspacesAndWorkBindMounts() async throws {
        try await service.bootstrap()
        guard service.bindMountsAvailable else {
            throw XCTSkip(
                "bind mounts need the embedded Blink bridge: TETHER_LINK_BLINK=1 and Frameworks/.build/host/blink.a"
            )
        }

        let demo = scratch.appendingPathComponent("workspaces/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        let work = scratch.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try service.bindWorkRoot(work.path)

        let wsWrite = try await runGuest("echo from-workspaces > /workspaces/demo/native.txt")
        XCTAssertEqual(wsWrite.code, 0, wsWrite.err)
        let wsHost = try service.mapHostPath("/workspaces/demo/native.txt")
        XCTAssertTrue(
            (try String(contentsOfFile: wsHost, encoding: .utf8)).contains("from-workspaces")
        )

        let workWrite = try await runGuest("echo from-work > /work/native.txt")
        XCTAssertEqual(workWrite.code, 0, workWrite.err)
        let workHost = try service.mapHostPath("/work/native.txt")
        XCTAssertTrue(
            (try String(contentsOfFile: workHost, encoding: .utf8)).contains("from-work")
        )
        XCTAssertEqual(
            (try String(contentsOf: work.appendingPathComponent("native.txt"), encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "from-work"
        )
    }
}

private struct TimeoutError: Error {}

/// Reads a pipe on a background thread until EOF. Closing the write end is
/// what unblocks `finish()`; do not wait for the guest to exit first.
private final class PipeDrain: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var data = Data()
    private var thread: Thread?

    init(fd: Int32) { self.fd = fd }

    func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(self.fd, &buf, buf.count)
                if n <= 0 { break }
                self.lock.lock()
                self.data.append(contentsOf: buf[0..<n])
                self.lock.unlock()
            }
            close(self.fd)
        }
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    func finish() -> String {
        while thread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.01)
        }
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
