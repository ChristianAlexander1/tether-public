import Foundation
import TetherWasm

/// Runs arbitrary wasm32-wasi command modules with the selected workspace as
/// their filesystem root. The adapter contains no module-name allowlist.
public final class TetherWasmService: @unchecked Sendable {
    private final class Cancellation: @unchecked Sendable {
        let flag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        init() { flag.initialize(to: 0) }
        deinit {
            flag.deinitialize(count: 1)
            flag.deallocate()
        }
    }

    private let lock = NSLock()
    private var active: [ObjectIdentifier: Cancellation] = [:]

    public init() {}

    public func run(
        argv: [String],
        hostCwd: String,
        environment: [String: String],
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32
    ) async -> Int32 {
        guard argv.count >= 2 else {
            writeError("usage: wasm MODULE.wasm [ARG ...]\n", to: stderrFD)
            return 2
        }

        let modulePath: String
        do {
            modulePath = try resolveModulePath(argv[1], workspace: hostCwd)
        } catch {
            writeError("wasm: \(error.localizedDescription)\n", to: stderrFD)
            return 126
        }

        let guestArgv = [URL(fileURLWithPath: argv[1]).lastPathComponent] + Array(argv.dropFirst(2))
        let cancellation = Cancellation()
        let key = ObjectIdentifier(cancellation)
        lock.withLock { active[key] = cancellation }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { _ = lock.withLock { active.removeValue(forKey: key) } }

                var options = tether_wasm_options()
                options.max_memory_bytes = 256 * 1024 * 1024
                options.stack_bytes = 256 * 1024
                options.timeout_ms = 0
                options.cancel_flag = UnsafePointer(cancellation.flag)

                var cEnv = environment.sorted { $0.key < $1.key }
                    .map { strdup("\($0.key)=\($0.value)") }
                cEnv.append(nil)
                defer { cEnv.forEach { free($0) } }

                var cArgv = guestArgv.map { strdup($0) }
                defer { cArgv.forEach { free($0) } }

                var diagnostic: UnsafeMutablePointer<CChar>?
                let code = modulePath.withCString { module in
                    hostCwd.withCString { cwd in
                        cEnv.withUnsafeMutableBufferPointer { envBuffer in
                            cArgv.withUnsafeMutableBufferPointer { argvBuffer in
                                options.envp = envBuffer.baseAddress.map { UnsafePointer($0) }
                                return tether_wasm_run_opts(
                                    module,
                                    argvBuffer.baseAddress,
                                    Int32(argvBuffer.count),
                                    cwd,
                                    stdinFD,
                                    stdoutFD,
                                    stderrFD,
                                    &options,
                                    &diagnostic
                                )
                            }
                        }
                    }
                }

                if let diagnostic {
                    writeError("wasm: \(String(cString: diagnostic))\n", to: stderrFD)
                    tether_wasm_free(diagnostic)
                }
                let status: Int32
                if code == Int32(TETHER_WASM_ERR_TIMEOUT) {
                    status = 124
                } else if code == Int32(TETHER_WASM_ERR_CANCELLED) {
                    status = 130
                } else if code >= 256 {
                    status = 126
                } else {
                    status = code
                }
                continuation.resume(returning: status)
            }
        }
    }

    public func interrupt() {
        lock.withLock {
            for cancellation in active.values {
                cancellation.flag.pointee = 1
            }
        }
    }

    private func resolveModulePath(_ argument: String, workspace: String) throws -> String {
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let relative: String
        if argument == "/work" {
            relative = ""
        } else if argument.hasPrefix("/work/") {
            relative = String(argument.dropFirst("/work/".count))
        } else if argument.hasPrefix("/") {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "absolute module paths must be under /work",
            ])
        } else {
            relative = argument
        }

        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              FileManager.default.isReadableFile(atPath: candidate.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "module is missing or outside the workspace: \(argument)",
            ])
        }
        return candidate.path
    }

    private func writeError(_ message: String, to fd: Int32) {
        guard fd >= 0 else { return }
        message.utf8CString.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            let count = buffer.count - 1
            while offset < count {
                let result = write(fd, base.advanced(by: offset), count - offset)
                if result > 0 { offset += result }
                else if result < 0, errno == EINTR { continue }
                else { return }
            }
        }
    }
}
