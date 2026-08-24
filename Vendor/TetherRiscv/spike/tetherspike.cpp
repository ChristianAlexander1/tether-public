//
// Tether — Track P8 spike: libriscv (riscv64) evaluation harness
//
// tetherspike: minimal single-file host program that boots a riscv64
// Alpine Linux userspace program (e.g. /bin/uname) using libriscv.
//
// MIT License (glue code; libriscv itself is BSD-3, see libriscv/LICENSE).
//
// Usage:
//   tetherspike [--rootfs DIR] [--memory MiB] [--fuel N] [--quiet]
//               GUEST_PROGRAM [ARGS...]
//
// Examples:
//   tetherspike --rootfs assets/rootfs-riscv64 /bin/uname -a
//   tetherspike --rootfs assets/rootfs-riscv64 /bin/busybox sh /bench/loop.sh 1000000
//
// How it works (same pattern as the upstream `emulator/` example):
//  1. Load the guest ELF. If it carries a PT_INTERP (dynamically linked),
//     the *dynamic linker itself* becomes the machine binary and the real
//     program is inserted as argv[1]. musl's ld.so supports this form:
//     `/lib/ld-musl-riscv64.so.1 /bin/uname -a`.
//  2. setup_linux() builds argv/env/auxv on the guest stack,
//     setup_linux_syscalls() installs ~70 Linux syscall handlers.
//  3. fds().permit_filesystem = true lets openat/mmap/readv hit real files,
//     and fds().filter_open rewrites every guest path into our rootfs
//     directory (a sandboxed chroot-like overlay, path-escape checked).
//  4. simulate() executes instructions; a host-side wall-clock timer wraps
//     the run and reports effective guest-MIPS for benchmarking.
//
#include <libriscv/machine.hpp>
#include <libriscv/util/load_binary_file.hpp>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <deque>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace std::string_literals;

namespace {

struct Options {
    std::string rootfs = "assets/rootfs-riscv64";
    uint64_t    memory_mib = 512;
    uint64_t    fuel = 60'000'000'000ULL; // instruction limit (safety valve)
    bool        quiet = false;
    const char* argv0 = "tetherspike";
};

[[noreturn]] void usage(const char* argv0, int code)
{
    std::fprintf(stderr,
        "Usage: %s [--rootfs DIR] [--memory MiB] [--fuel N] [--quiet] PROGRAM [ARGS...]\n"
        "       PROGRAM is a guest path inside --rootfs, e.g. /bin/uname\n", argv0);
    std::exit(code);
}

// Lexically normalize a POSIX path, removing "." and resolving "..".
// Returns false if it would escape above '/'.
bool normalize_abs(const std::string& in, std::string& out)
{
    std::vector<std::string> parts;
    size_t i = 0;
    while (i < in.size()) {
        size_t j = in.find('/', i);
        if (j == std::string::npos) j = in.size();
        const std::string seg = in.substr(i, j - i);
        if (seg.empty() || seg == ".") {
            // skip
        } else if (seg == "..") {
            if (parts.empty()) return false; // escapes root
            parts.pop_back();
        } else {
            parts.push_back(seg);
        }
        i = j + 1;
    }
    out.clear();
    for (auto& p : parts) { out += '/'; out += p; }
    if (out.empty()) out = "/";
    return true;
}

} // namespace

extern "C" int tetherspike_run(int argc, char* argv[])
{
    Options opt;
    opt.argv0 = argv[0];

    // --- parse arguments -------------------------------------------------
    int aidx = 1;
    for (; aidx < argc; aidx++) {
        const std::string arg = argv[aidx];
        if (arg == "--rootfs" && aidx + 1 < argc)       opt.rootfs = argv[++aidx];
        else if (arg == "--memory" && aidx + 1 < argc)  opt.memory_mib = std::strtoull(argv[++aidx], nullptr, 10);
        else if (arg == "--fuel" && aidx + 1 < argc)    opt.fuel = std::strtoull(argv[++aidx], nullptr, 10);
        else if (arg == "--quiet")                      opt.quiet = true;
        else if (arg == "--help")                       usage(argv[0], 0);
        else if (arg.rfind("-", 0) == 0 && arg.size() > 1) { std::fprintf(stderr, "unknown option: %s\n", arg.c_str()); usage(argv[0], 2); }
        else break; // first non-option = guest program
    }
    if (aidx >= argc) usage(argv[0], 2);

    // Remaining args are the guest program + its arguments (guest paths).
    std::vector<std::string> guest_args;
    for (int i = aidx; i < argc; i++) guest_args.emplace_back(argv[i]);
    const std::string guest_prog = guest_args.at(0);

    // --- load guest binary ------------------------------------------------
    // The rootfs footprint here is tiny; keep the whole program in memory.
    const std::string host_prog = opt.rootfs + guest_prog;
    std::vector<uint8_t> vbin;
    try {
        vbin = load_binary_file(host_prog); // helper is global-namespace
    } catch (const std::exception& e) {
        std::fprintf(stderr, "tetherspike: cannot load %s: %s\n", host_prog.c_str(), e.what());
        return 1;
    }
    if (vbin.size() < 64 || vbin[4] != 2 /*ELFCLASS64*/) {
        std::fprintf(stderr, "tetherspike: %s is not a 64-bit ELF\n", host_prog.c_str());
        return 1;
    }

    std::string_view binary{ (const char*)vbin.data(), vbin.size() };
    bool is_dynamic = false;
    std::string_view interpreter;
    std::tie(is_dynamic, interpreter) = riscv::Elf<8>::is_dynamic(binary);

    std::vector<uint8_t> vlinker; // keep dynamic linker bytes alive
    if (is_dynamic) {
        if (interpreter.empty()) {
            std::fprintf(stderr, "tetherspike: dynamic executable but empty PT_INTERP\n");
            return 1;
        }
        // Load the dynamic linker (e.g. /lib/ld-musl-riscv64.so.1) from rootfs
        const std::string host_linker = opt.rootfs + std::string(interpreter);
        try {
            vlinker = load_binary_file(host_linker);
        } catch (const std::exception& e) {
            std::fprintf(stderr, "tetherspike: cannot load dynamic linker %s: %s\n",
                host_linker.c_str(), e.what());
            return 1;
        }
        // Insert the program as argv[1], make the linker argv[0]
        guest_args.insert(guest_args.begin() + 1, guest_args.at(0));
        guest_args.at(0) = interpreter;
        binary = { (const char*)vlinker.data(), vlinker.size() };
    }

    // --- build the machine ------------------------------------------------
    auto options = std::make_shared<riscv::MachineOptions<riscv::RISCV64>>(
        riscv::MachineOptions<riscv::RISCV64>{
            .memory_max = opt.memory_mib << 20,
            .verbose_loader = std::getenv("TETHERSPIKE_DEBUG") != nullptr,
            // One machine per process in this spike; disable shared segments
            // to enable the single-machine optimizations.
            .use_shared_execute_segments = false,
#ifdef RISCV_BINARY_TRANSLATION
            .translate_enabled = true,
            .translate_ignore_instruction_limit = true,
            .translate_use_register_caching = riscv::libtcc_enabled,
#endif
        });

    riscv::Machine<riscv::RISCV64> machine{ binary, *options };
    machine.set_options(std::move(options));

    // --- set up Linux environment ------------------------------------------
    const std::vector<std::string> env = { "LC_ALL=C", "PATH=/usr/bin:/bin", "HOME=/home" };
    machine.setup_linux(guest_args, env);
    machine.setup_linux_syscalls();      // incl. filesystem + sockets
    machine.setup_posix_threads();       // futex/clone surface (unused by busybox sh, keeps musl happy)

    // AT_BASE fix-up: setup_linux() writes AT_BASE = start & ~16MB, which is
    // 0 whenever the loader image sits below 16MB (always true here).
    // musl's _dlstart_c computes its own load base from auxv AT_BASE; with 0,
    // it relocates its own data pointers to RAW vaddrs and writes into its
    // R+X segment (BSS zeroing) -> protection fault. Rewrite AT_BASE with the
    // true base = loaded_entry - ELF_header_entry.
    if (is_dynamic) {
        const uint64_t e_entry = *(const uint64_t*)&vlinker[24]; // ehdr.e_entry
        const uint64_t base = machine.memory.start_address() - e_entry;
        constexpr uint64_t AT_BASE = 7;
        uint64_t pos = machine.memory.stack_initial();
        auto rd64 = [&](uint64_t p) { return machine.memory.template read<uint64_t>(p); };
        pos += 8;                                   // skip argc
        while (rd64(pos) != 0) pos += 8; pos += 8;  // argv + terminating NULL
        while (rd64(pos) != 0) pos += 8; pos += 8;  // envp + terminating NULL
        for (int guard = 0; guard < 64; guard++, pos += 16) {
            const uint64_t key = rd64(pos);
            if (key == 0) break;                    // AT_NULL
            if (key == AT_BASE) {
                machine.memory.template writable_read<uint64_t>(pos + 8) = base;
                std::fprintf(stderr, "tetherspike: patched auxv AT_BASE -> 0x%llx\n",
                    (unsigned long long)base);
                break;
            }
        }
    }

    machine.fds().permit_filesystem = true;
    machine.fds().permit_sockets    = false;
    machine.fds().cwd = "/home";

    // Sandboxed rootfs overlay: every guest open() path is rewritten into
    // --rootfs; anything escaping it (via absolute paths or "..") is denied,
    // except a tiny allowlist of benign host device nodes.
    const std::string rootfs = opt.rootfs;
    machine.fds().filter_open = [rootfs](void*, std::string& path) {
        if (path == "/dev/null" || path == "/dev/urandom" || path == "/dev/random" ||
            path == "/dev/tty")
            return true; // allowed through to host pseudo-devices
        std::string rel = path;
        if (rel.empty()) return false;
        if (rel[0] != '/') rel = "/home/" + rel;
        std::string norm;
        if (!normalize_abs(rel, norm)) return false; // escapes root
        path = rootfs + norm;
        return true;
    };
    machine.fds().filter_readlink = [rootfs](void*, std::string& path) {
        if (path == "/proc/self/exe") return false; // not needed for this spike
        return true; // stat-like reads only
    };

    // --- run with wall-clock timer -----------------------------------------
    if (!opt.quiet) {
        std::fprintf(stderr, "tetherspike: %s program=%s memory=%lluMiB fuel=%.1fbn\n",
            is_dynamic ? "dynamic" : "static ", guest_prog.c_str(),
            (unsigned long long)opt.memory_mib, (double)opt.fuel / 1e9);
    }
    // Optional single-step trace: keeps the last 40 executed instructions
    const char* trace_env = std::getenv("TETHERSPIKE_TRACE");
    const uint64_t trace_steps = trace_env ? std::strtoull(trace_env, nullptr, 10) : 0;
    std::deque<std::pair<uint64_t, uint32_t>> ring;
    const auto dump_ring = [&] {
        std::fprintf(stderr, "=== execution trace (last %zu) ===\n", ring.size());
        for (const auto& [pc, instr] : ring)
            std::fprintf(stderr, "  [%#llx] %#010x\n", (unsigned long long)pc, instr);
    };

    const auto t0 = std::chrono::steady_clock::now();
    try {
        if (trace_steps > 0) {
            machine.set_max_instructions(std::min(opt.fuel, trace_steps));
            machine.reset_instruction_counter();
            uint64_t left = trace_steps;
            while (!machine.stopped() && left-- > 0) {
                const auto pc = machine.cpu.pc();
                ring.emplace_back((uint64_t)pc,
                    (uint32_t)machine.memory.template read<uint32_t>(pc));
                if (ring.size() > 40) ring.pop_front();
                machine.cpu.step_one();
            }
        } else {
            machine.simulate<false>(opt.fuel);
        }
    } catch (const riscv::MachineException& e) {
        std::fprintf(stderr, "tetherspike: machine exception %d: %s (data=0x%llx), guest PC=0x%llx\n",
            e.type(), e.what(), (unsigned long long)e.data(),
            (unsigned long long)machine.cpu.pc());
        if (std::getenv("TETHERSPIKE_DEBUG")) {
            dump_ring();
            try {
                std::fprintf(stderr, "instr: %s\n",
                    machine.cpu.current_instruction_to_string().c_str());
            } catch (...) { /* best effort */ }
            std::fprintf(stderr, "%s\n", machine.cpu.registers().to_string().c_str());
            // dump argc/argv/env/auxv as the guest actually has them
            try {
                uint64_t p = machine.memory.stack_initial();
                auto rd = [&](uint64_t a) { return machine.memory.template read<uint64_t>(a); };
                std::fprintf(stderr, "stack_initial=0x%llx argc=%llu\n",
                    (unsigned long long)p, (unsigned long long)rd(p));
                p += 8;
                while (rd(p)) p += 8; p += 8;  // argv + NULL
                while (rd(p)) p += 8; p += 8;  // envp + NULL
                std::fprintf(stderr, "auxv at 0x%llx:\n", (unsigned long long)p);
                for (int i = 0; i < 24; i++, p += 16) {
                    const uint64_t k = rd(p), v = rd(p + 8);
                    std::fprintf(stderr, "  key=%llu val=0x%llx\n",
                        (unsigned long long)k, (unsigned long long)v);
                    if (k == 0) break;
                }
            } catch (...) { std::fprintf(stderr, "(auxv dump failed)\n"); }
            try {
                machine.memory.print_backtrace(
                    [](std::string_view line) { std::fprintf(stderr, "BT: %.*s\n", (int)line.size(), line.data()); });
            } catch (...) { /* best effort */ }
        }
        return 3;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "tetherspike: host exception: %s\n", e.what());
        return 3;
    }
    const auto t1 = std::chrono::steady_clock::now();

    const double secs = std::chrono::duration<double>(t1 - t0).count();
    const uint64_t instr = machine.instruction_counter();
    const double mips = (secs > 0.0) ? (double)instr / secs / 1e6 : 0.0;
    const int status = (int)machine.template return_value<int64_t>();
    const bool exhausted = machine.instruction_limit_reached();

    if (!opt.quiet) {
        std::fprintf(stderr,
            "tetherspike: guest exited status=%d, %" PRIu64 " instrs in %.3fs = %.1f guest-MIPS%s\n",
            status, instr, secs, mips, exhausted ? " (fuel exhausted!)" : "");
    }
    // JSON-ish line on stderr for machine parsing by bench.sh
    std::fprintf(stderr, "TETHERSPIKE_RESULT arch=riscv64 guest_mips=%.2f wall_s=%.6f instrs=%" PRIu64
        " status=%d fuel_exhausted=%d\n", mips, secs, instr, status, exhausted ? 1 : 0);

    return status & 0xFF;
}
