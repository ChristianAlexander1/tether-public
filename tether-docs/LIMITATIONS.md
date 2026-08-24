# Tether limitations

Tether is a developer terminal inside a single iOS app process. It does not
implement a complete Linux kernel, a hardened container, or a general
untrusted-code sandbox.

Every gap below has three fields:

- **Description** — what is missing or constrained, and why it matters
- **Owner** — the track that must close, accept, or re-home it (P1–I3)
- **Status** — `accepted` (will not change in v1), `open` (needs a decision or
  a fix), `partial` (works on a subset), `in progress`, or `planned`

Statuses are the P11 documentation contract as of 2026-08-23. Tracks update
the row in the same PR that changes the fact. Do not leave a shipped behaviour
undocumented here.

Related: [ARCHITECTURE.md](ARCHITECTURE.md), [VALIDATION.md](VALIDATION.md).

License: [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

---

## How to read the table

| Status | Meaning |
| --- | --- |
| `accepted` | Known, documented, not a v1 bug. Reviewers should not block on it. |
| `open` | Real gap. No accepted workaround yet. |
| `partial` | Some paths work; the row names the missing ones. |
| `in progress` | An owner track is actively closing it. |
| `planned` | Scheduled after v1 or after a named prerequisite. |

An `accepted` row can still become a bug if a later change *claims* the
missing facility. Claiming it without evidence is a [VALIDATION.md](VALIDATION.md)
failure.

---

## 1. Security and process model

### L-SEC-01 — Not a container

| | |
| --- | --- |
| **Description** | Guest permissions, WASM caps, and Linux uid/gid are compatibility shims. A program running in any backend shares the app process (or a bundled helper) and can exercise every host integration the registry exposes. Tether is not a place to confine hostile workloads. |
| **Owner** | I1 (model), P4 / P5 (policy surface) |
| **Status** | `accepted` |

### L-SEC-02 — host_exec argv is hostile

| | |
| --- | --- |
| **Description** | The broker must assume every field of a `host_exec` request is attacker-controlled. Path checks after symlink expansion, an allow-list of names, no `sh -c`, and output caps are mandatory. The allow-list itself has not had an independent review pass. |
| **Owner** | P5, I1 |
| **Status** | `open` |

### L-SEC-03 — Bind mounts and bookmarks widen the view

| | |
| --- | --- |
| **Description** | A user-picked Files location, once bookmarked, is visible to any command whose `fs_view` includes it. There is no per-command re-prompt. A stale bookmark fails closed, but a live one is ambient authority inside the session. |
| **Owner** | P8, I1 |
| **Status** | `partial` |

### L-SEC-04 — No third-party JIT / RWX / MAP_JIT

| | |
| --- | --- |
| **Description** | App Store Tether cannot generate executable pages. V8 JIT, JavaScriptCore JIT, native WASM compilers, and Linux guest JITs are unavailable. Backends interpret. Performance and language coverage follow from that. |
| **Owner** | I1, P6, P7 |
| **Status** | `accepted` |

### L-SEC-05 — Keychain gated when the device is locked

| | |
| --- | --- |
| **Description** | Claude tokens use `AfterFirstUnlockThisDeviceOnly`. After reboot and before first unlock, or in some lock-screen background wakes, `claude-token` fails closed. The UI must not treat this as a sign-out. |
| **Owner** | P10, I1 |
| **Status** | `open` |

### L-SEC-06 — Pasteboard and share sheet exfil paths

| | |
| --- | --- |
| **Description** | `pbcopy`, `pbpaste`, and `share` are on the `host_exec` allow-list. They are user-facing features and also the easiest way for a guest script to move bytes off the sandbox. Size caps exist; content inspection does not. |
| **Owner** | P5, I1 |
| **Status** | `partial` |

---

## 2. Terminal UI

### L-UI-01 — Kitty / iTerm graphics

| | |
| --- | --- |
| **Description** | The renderer targets xterm-256 / 24-bit colour, OSC 52 (capped), and common CSI. Kitty graphics, Sixel, and iTerm inline images are not in v1. Tools that assume them degrade to text. |
| **Owner** | P1 |
| **Status** | `planned` |

### L-UI-02 — IME and dead keys

| | |
| --- | --- |
| **Description** | Composition events from the software keyboard (CJK, accent dead keys) must not be flushed to the PTY as partial UTF-8. Hardware keyboards on iPad are better tested than the software keyboard's marked-text path. |
| **Owner** | P1, P2 |
| **Status** | `partial` |

### L-UI-03 — Large paste

| | |
| --- | --- |
| **Description** | Pastes above the PTY master high-water mark can block the UI or be truncated. There is a cap and a confirmation, but bracketed-paste consumers that are slow (Linux guest) can still back-pressure the renderer. |
| **Owner** | P1, P2 |
| **Status** | `partial` |

### L-UI-04 — Stage Manager and external display

| | |
| --- | --- |
| **Description** | Multi-window and non-native aspect ratios are not a v1 commitment. A session on an external display may keep the original winsize until the user resizes. |
| **Owner** | P1, I1 |
| **Status** | `planned` |

### L-UI-05 — Accessory bar completeness

| | |
| --- | --- |
| **Description** | Esc, Tab, Ctrl, arrows, and a small function row ship. Full `tmux`-style prefix chords and a user-editable key map are incomplete. |
| **Owner** | P1 |
| **Status** | `in progress` |

### L-UI-06 — VoiceOver and Dynamic Type

| | |
| --- | --- |
| **Description** | Chrome (tabs, palette, sign-in) is expected to meet WCAG-equivalent iOS a11y. The glyph grid is a custom renderer; VoiceOver rotor navigation inside scrollback is incomplete, and Dynamic Type does not retile an existing session until reconnect. |
| **Owner** | I1, P1 |
| **Status** | `open` |

---

## 3. PTY and shell

### L-PTY-01 — Host PTY vs guest PTY

| | |
| --- | --- |
| **Description** | The UI speaks a host PTY. Linux programs speak a synthesised Linux PTY. The bridge is lossy for uncommon ioctls (`TIOCLINUX`, some packet-mode features, POSIX job-control edge cases with orphaned process groups). |
| **Owner** | P2, P7 |
| **Status** | `partial` |

### L-PTY-02 — UTF-8 torn reads

| | |
| --- | --- |
| **Description** | The PTY layer is required to reassemble UTF-8 before the renderer consumes a read. A regression here shows up as replacement characters during fast `cat` of UTF-8. Covered by a validation fixture; still easy to break when someone “optimises” the read loop. |
| **Owner** | P2 |
| **Status** | `partial` |

### L-SH-01 — Background death

| | |
| --- | --- |
| **Description** | iOS may jetsam Tether in the background. The live process tree, Linux mappings, and most scrollback die with it. Restore creates a new PTY and, at best, the last cwd. This is not crash-recovery of `tmux` state. |
| **Owner** | P3, I1 |
| **Status** | `accepted` |

### L-SH-02 — Multiplexed session restore

| | |
| --- | --- |
| **Description** | Tab list and last cwd persist. Running jobs, shell history beyond the persisted cap, and Linux overlay dirty state may not. Users who need durability should treat the overlay as best-effort and copy out work they care about. |
| **Owner** | P3, P8 |
| **Status** | `in progress` |

### L-SH-03 — Job control vs backend mix

| | |
| --- | --- |
| **Description** | `Ctrl-Z` / `fg` / `bg` are defined for the Linux backend's process groups. Native `host_exec` and WASM instances are not full POSIX jobs; suspending them is a cooperative cancel, not `SIGTSTP`. |
| **Owner** | P3, P4, P5, P6 |
| **Status** | `partial` |

---

## 4. Registry and backends

### L-REG-01 — Ambiguous names

| | |
| --- | --- |
| **Description** | A name can exist as a native handler *and* a Linux `$PATH` hit (`ssh`, `git` if both ship). Session profile (`linux-first` / `native-first`) plus `tether-run --backend=` are the only disambiguation. Getting the default wrong looks like a “broken” tool. |
| **Owner** | P4 |
| **Status** | `partial` |

### L-REG-02 — No user-installable native code

| | |
| --- | --- |
| **Description** | Users cannot drop a Mach-O into the app and have the registry execute it. That is an App Store rule, not a missing feature. New native tools ship in an app update. |
| **Owner** | P5, I1, I3 |
| **Status** | `accepted` |

### L-NAT-01 — Thin native toolbox

| | |
| --- | --- |
| **Description** | Native coverage is the allow-list in [ARCHITECTURE.md](ARCHITECTURE.md) plus a small set of builtins. It will never be a substitute for the Linux userland. Expectation-setting in the UI is still incomplete. |
| **Owner** | P5, P1 |
| **Status** | `in progress` |

### L-WASM-01 — Interpreter only, incomplete WASI

| | |
| --- | --- |
| **Description** | WASM is interpreted. WASI preview coverage is the subset needed by shipped modules (files, clocks, args, a tight sockets cap). `poll_oneoff`, sockets, and rights narrowing have known holes. A module that runs in wasmtime on a desktop may fail here. |
| **Owner** | P6 |
| **Status** | `partial` |

### L-WASM-02 — No WASM threads / shared memory

| | |
| --- | --- |
| **Description** | Threads, `shared` memories, and `wait` / `notify` are not in the v1 contract. Modules that require them are rejected at load. |
| **Owner** | P6 |
| **Status** | `planned` |

### L-WASM-03 — Module index is signed and closed

| | |
| --- | --- |
| **Description** | Only modules in the shipped, signed index run. Users cannot fetch an arbitrary `.wasm` and execute it. This is an App Review and security choice. It also means “install a WASM tool” is an app-update path, not `curl`. |
| **Owner** | P6, I3 |
| **Status** | `accepted` |

### L-LNX-01 — Incomplete syscall surface

| | |
| --- | --- |
| **Description** | Unimplemented Linux calls return `ENOSYS` (or a documented stub). A quiet fallback is not an implementation. Language runtimes that probe modern calls (io_uring, some clone flags, some netlink) will take degraded paths or fail. |
| **Owner** | P7 |
| **Status** | `partial` |

### L-LNX-02 — No namespaces, cgroups, Docker, or kernel modules

| | |
| --- | --- |
| **Description** | There is no container runtime and no loadable kernel. Docker, Podman, snap, and anything that needs cgroups or a real mount namespace are unsupported. Rows in validation must say `unsupported`, not `pass`. |
| **Owner** | P7 |
| **Status** | `accepted` |

### L-LNX-03 — No hardware passthrough

| | |
| --- | --- |
| **Description** | No GPU, no USB gadget, no `/dev` that maps to real hardware beyond the usual pseudo devices. CUDA, Vulkan, and similar stacks will not run. |
| **Owner** | P7 |
| **Status** | `accepted` |

### L-LNX-04 — Guest instruction coverage

| | |
| --- | --- |
| **Description** | The AArch64 interpreter does not claim architectural completeness. Unrecognised encodings take the guest undefined-instruction path. Adding an instruction requires a fixture ([VALIDATION.md](VALIDATION.md)), not only a decoder match. |
| **Owner** | P7, I2 |
| **Status** | `partial` |

### L-LNX-05 — Compatibility env defaults

| | |
| --- | --- |
| **Description** | Some language runtimes need conservative defaults (serialised GC, limited `GOMAXPROCS`, interpreter flags) to stay stable under a user-mode kernel and a no-JIT policy. Overriding them can reintroduce hangs. These defaults are part of the contract until P7 says otherwise. |
| **Owner** | P7 |
| **Status** | `partial` |

### L-LNX-06 — Rootfs is a packaging surface

| | |
| --- | --- |
| **Description** | A missing binary, class, or shared library is often a rootfs packaging defect, not an emulator defect. It still fails the workload. Dated pass counts apply only to the rootfs they name. |
| **Owner** | P7, I2 |
| **Status** | `open` |

---

## 5. Filesystem and network

### L-FS-01 — Overlay durability

| | |
| --- | --- |
| **Description** | The Linux writable overlay is flushed on an orderly teardown. Jetsam can lose unsynced pages. `fsync` in the guest is honoured on a best-effort path; it is not a power-loss guarantee. |
| **Owner** | P8, P7 |
| **Status** | `partial` |

### L-FS-02 — Bookmark expiry

| | |
| --- | --- |
| **Description** | Security-scoped bookmarks expire or fail after Files-provider migrations and some iOS upgrades. Tether must fail closed and prompt, not crash, and not silently write into the container instead. |
| **Owner** | P8 |
| **Status** | `partial` |

### L-FS-03 — iCloud off by default

| | |
| --- | --- |
| **Description** | Ubiquity containers are a surprise for a Unix `$HOME`. iCloud is opt-in. Conflicts and evicted-fault I/O are not handled as if they were POSIX files. |
| **Owner** | P8, I1 |
| **Status** | `accepted` |

### L-NET-01 — No raw sockets, no packet filters

| | |
| --- | --- |
| **Description** | Linux `AF_PACKET`, raw ICMP (except what the host stack already allows), and BPF/seccomp/fanotify are absent. `ping` and `nmap` in the forms people expect on a desktop will not work or will be `unsupported`. |
| **Owner** | P9, P7 |
| **Status** | `accepted` |

### L-NET-02 — ATS and certificate pinning surprises

| | |
| --- | --- |
| **Description** | Native traffic uses App Transport Security. Linux TLS is whatever the rootfs ships (typically OpenSSL against the host-validated path, or a guest CA store). Corporate MITM and user-installed CAs do not automatically apply to the guest store. |
| **Owner** | P9, P7 |
| **Status** | `partial` |

### L-NET-03 — Local Network permission

| | |
| --- | --- |
| **Description** | Talking to a LAN SSH box or a printer requires the user's Local Network permission. Simulator and device prompts differ. A denied permission looks like a mysterious timeout. |
| **Owner** | P9, I1, I2 |
| **Status** | `open` |

### L-NET-04 — SSH agent forwarding

| | |
| --- | --- |
| **Description** | An SSH *client* is planned. Agent forwarding, multiplexed control sockets, and hardware-key (Secure Enclave) identities are not v1. |
| **Owner** | P9 |
| **Status** | `planned` |

### L-NET-05 — IPv6 and NECP

| | |
| --- | --- |
| **Description** | IPv6 works on paths that the host stack already supports. Constrained networks, per-app VPN, and NECP “connection denied” can surface as generic `EHOSTUNREACH` inside Linux. Diagnosis is still Native-side. |
| **Owner** | P9 |
| **Status** | `partial` |

---

## 6. Claude

### L-CLD-01 — Token refresh edge cases

| | |
| --- | --- |
| **Description** | Concurrent `claude-token` calls during a refresh must rotate once, not thrash. A 401 on refresh is a hard sign-out. Network loss mid-refresh must not delete a still-valid refresh token. These cases are implemented in outline and not fully gated. |
| **Owner** | P10, I2 |
| **Status** | `in progress` |

### L-CLD-02 — No guest-visible refresh token

| | |
| --- | --- |
| **Description** | Linux/WASM tools receive only a short-lived access token on stdout of `claude-token`. The refresh token never leaves the Keychain. This is the platform contract. |
| **Owner** | P10, P5 |
| **Status** | `accepted` |

### L-CLD-03 — OAuth client is public

| | |
| --- | --- |
| **Description** | PKCE is mandatory; there is no client secret in the binary. Anyone can impersonate the public client id. Protection is the user's password / passkey at the IdP plus token storage on device, not client secrecy. |
| **Owner** | P10 |
| **Status** | `accepted` |

### L-CLD-04 — ASWebAuthenticationSession cancellations

| | |
| --- | --- |
| **Description** | iPad split-view, an external browser preference, and ITP-like cookie partitioning can make the callback fail even after a successful IdP login. The fallback universal link is the spare path; it is not fully proven on device. |
| **Owner** | P10, I1 |
| **Status** | `open` |

### L-CLD-05 — Shipped tools must not persist access tokens

| | |
| --- | --- |
| **Description** | Tether cannot stop a guest tool from writing the short-lived access token it just received to a file. Every shipped Claude-facing tool must be audited to keep the token in memory only. That audit has not landed. |
| **Owner** | P10, P5 |
| **Status** | `open` |

---

## 7. iOS platform

### L-IOS-01 — Background execution

| | |
| --- | --- |
| **Description** | Tether is not a VoIP app and does not hold an unbounded background assertion. Long jobs should be assumed dead after backgrounding. A future “continue in background for N minutes” is I1 work and an App Review risk. |
| **Owner** | I1 |
| **Status** | `accepted` |

### L-IOS-02 — Jetsam

| | |
| --- | --- |
| **Description** | Linux userland plus a Metal renderer plus a WASM interpreter is a memory-heavy process. On 4 GB class devices, large compiles will jetsam. There is no good guest-visible “OOM killer” story yet; the app disappears. |
| **Owner** | I1, P7, P1 |
| **Status** | `open` |

### L-IOS-03 — Simulator is not the device

| | |
| --- | --- |
| **Description** | A pass on the iOS Simulator does not establish signing, Keychain access groups, Local Network, jetsam, thermal, ProMotion vs 60 Hz input, or hardware-keyboard behaviour. Device gates in [VALIDATION.md](VALIDATION.md) are mandatory before TestFlight. |
| **Owner** | I2, I1 |
| **Status** | `accepted` |

### L-IOS-04 — Entitlement drift vs TestFlight

| | |
| --- | --- |
| **Description** | Debug, TestFlight, and App Store profiles can disagree (push, associated domains, Keychain groups). A capability that works in Xcode may vanish on TestFlight. I3 owns the matrix; it is not fully filled in. |
| **Owner** | I3, I1 |
| **Status** | `open` |

### L-IOS-05 — App Review interpreter policy

| | |
| --- | --- |
| **Description** | Tether interprets guest and WASM code and does not download executable native code. That is the intended review position (see [RELEASES.md](RELEASES.md)). It is still a review risk. A rejected build is an I3 incident, not a silent retry. |
| **Owner** | I3 |
| **Status** | `open` |

---

## 8. Validation and release

### L-VAL-01 — Linux-host fixtures ≠ iOS behaviour

| | |
| --- | --- |
| **Description** | If P7 runs a Linux-host harness for the userspace kernel, those results do not cover UI, PTY bridge, Keychain, or jetsam. They are necessary, not sufficient. |
| **Owner** | I2, P7 |
| **Status** | `accepted` |

### L-VAL-02 — Live package repositories

| | |
| --- | --- |
| **Description** | Rootfs package installs against live mirrors are non-deterministic. A bootstrap failure is infrastructure, not an emulator pass. Record it separately. |
| **Owner** | I2, P7 |
| **Status** | `open` |

### L-REL-01 — Version sources can drift

| | |
| --- | --- |
| **Description** | Marketing version, Apple build number, and Git tag are three sources. Uploading a build whose numbers do not match the tag is an I3 failure. The bump script is the only supported editor. |
| **Owner** | I3 |
| **Status** | `partial` |

### L-DOC-01 — Documentation drift

| | |
| --- | --- |
| **Description** | These files were written from the P11 spec without the iOS tree in-repo. Path names and allow-lists are the contract; if the tree differs, the tree or this file must change in the same PR. P11 does not own runtime code. |
| **Owner** | P11 |
| **Status** | `in progress` |

---

## 9. Index by owner

| Track | Rows |
| --- | --- |
| P1 | L-UI-01, L-UI-02, L-UI-03, L-UI-04, L-UI-05, L-UI-06, L-NAT-01, L-IOS-02 |
| P2 | L-UI-02, L-UI-03, L-PTY-01, L-PTY-02 |
| P3 | L-SH-01, L-SH-02, L-SH-03 |
| P4 | L-SEC-01, L-SH-03, L-REG-01 |
| P5 | L-SEC-01, L-SEC-02, L-SEC-06, L-SH-03, L-REG-02, L-NAT-01, L-CLD-02, L-CLD-05 |
| P6 | L-SEC-04, L-SH-03, L-WASM-01, L-WASM-02, L-WASM-03 |
| P7 | L-SEC-04, L-PTY-01, L-LNX-01 … L-LNX-06, L-FS-01, L-NET-01, L-NET-02, L-IOS-02, L-VAL-01, L-VAL-02 |
| P8 | L-SEC-03, L-SH-02, L-FS-01, L-FS-02, L-FS-03 |
| P9 | L-NET-01 … L-NET-05 |
| P10 | L-SEC-05, L-CLD-01, L-CLD-02, L-CLD-03, L-CLD-04, L-CLD-05 |
| P11 | L-DOC-01 |
| I1 | L-SEC-01 … L-SEC-06, L-UI-04, L-UI-06, L-SH-01, L-REG-02, L-FS-03, L-NET-03, L-CLD-04, L-IOS-01 … L-IOS-04 |
| I2 | L-LNX-04, L-LNX-06, L-NET-03, L-CLD-01, L-IOS-03, L-VAL-01, L-VAL-02 |
| I3 | L-REG-02, L-WASM-03, L-IOS-04, L-IOS-05, L-REL-01 |

---

## 10. What “done” looks like for a gap

A status may move to `accepted` only when:

1. the behaviour is described here in user-visible terms,
2. [VALIDATION.md](VALIDATION.md) has a row that would fail if someone accidentally “implements” it as a silent success,
3. the owner track is named.

A status may move to closed (delete the row, or mark `accepted` if it remains a product limit) only with a validation pointer.

Do not delete a row because it is embarrassing. Delete it because the fact changed.
