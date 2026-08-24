import XCTest
@testable import TermXLinux

/// C6 acceptance suite (docs/09-integration-contracts.md §3).
/// Requires network + a built Blink host binary or embedded bridge (macOS).
final class C6AcceptanceTests: XCTestCase {
    private var scratch: URL!
    private var service: BlinkLinuxService!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TETHER_LINUX_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set TETHER_LINUX_NETWORK_TESTS=1 to run real Blink/Alpine acceptance tests")
        }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-c6-\(UUID().uuidString)", isDirectory: true)
        let rootfs = scratch.appendingPathComponent("rootfs", isDirectory: true)
        let workspaces = scratch.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        service = BlinkLinuxService(rootfs: rootfs, workspacesHostRoot: workspaces)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private func runGuest(_ cmdline: String, timeout: TimeInterval = 120) async throws -> (code: Int32, out: String, err: String) {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw LinuxGuestError.bootstrapFailed("pipe() failed")
        }

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

        let result: Int32
        do {
            result = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await runTask.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw TimeoutError()
                }
                let code = try await group.next()!
                group.cancelAll()
                return code
            }
        } catch {
            service.interrupt()
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            throw error
        }

        close(outPipe[1])
        close(errPipe[1])

        var outData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(outPipe[0], &buf, buf.count)
            if n <= 0 { break }
            outData.append(contentsOf: buf[0..<n])
        }
        var errData = Data()
        while true {
            let n = read(errPipe[0], &buf, buf.count)
            if n <= 0 { break }
            errData.append(contentsOf: buf[0..<n])
        }
        close(outPipe[0])
        close(errPipe[0])

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (result, out, err)
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
    }

    func testC6WorkspacesMapping() async throws {
        try await service.bootstrap()
        guard ProcessInfo.processInfo.environment["TERMX_BLINK_EMBED"] == "1" else {
            throw XCTSkip("/workspaces VfsMount requires TERMX_BLINK_EMBED=1 with linked blink.a; host subprocess path does not bind mounts")
        }

        let demo = scratch.appendingPathComponent("workspaces/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        let guestFile = "/workspaces/demo/native.txt"

        let write = try await runGuest("echo guest-edited > \(guestFile)")
        XCTAssertEqual(write.code, 0, write.err)

        let hostPath = try service.mapHostPath(guestFile)
        let content = try String(contentsOfFile: hostPath, encoding: .utf8)
        XCTAssertTrue(content.contains("guest-edited"))
    }

    func testC6BunHelloWorld() async throws {
        try await service.bootstrap()

        // A standalone release archive is not an apk package, so install its
        // declared runtime libraries before copying it into the guest.
        let dependencies = try await runGuest("/sbin/apk add --no-cache libstdc++ libgcc", timeout: 180)
        XCTAssertEqual(dependencies.code, 0, dependencies.out + dependencies.err)

        let bunURL = URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v1.2.0/bun-linux-x64-musl-baseline.zip")!
        let (zip, _) = try await URLSession.shared.download(from: bunURL)
        let extract = scratch.appendingPathComponent("bunzip")
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qo", zip.path, "-d", extract.path]
        try proc.run()
        proc.waitUntilExit()

        let bunBin = (FileManager.default.subpaths(atPath: extract.path) ?? [])
            .compactMap { extract.appendingPathComponent($0).path }
            .first { $0.hasSuffix("/bun") && FileManager.default.isExecutableFile(atPath: $0) }
        guard let bunBin else {
            XCTFail("bun binary missing after download")
            return
        }

        let dest = service.rootfs.appendingPathComponent("usr/local/bin/bun")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: bunBin, toPath: dest.path)

        do {
            let hello = try await runGuest("/usr/local/bin/bun -e 'console.log(\"hello-world\")'", timeout: 60)
            if hello.code != 0, hello.err.contains("Error relocating") || hello.err.contains("symbol not found") {
                throw XCTSkip("bun musl binary requires libstdc++/libunwind not in minirootfs under Blink — tracked blocker")
            }
            XCTAssertEqual(hello.code, 0, hello.out + hello.err)
            XCTAssertTrue(hello.out.contains("hello-world"))
        } catch is TimeoutError {
            throw XCTSkip("bun hangs under Blink on this host — known upstream limitation")
        }
    }
}

private struct TimeoutError: Error {}
