# Platform limitations (honest gaps)

Track IDs point to work in `13-parallel-agent-plan.md` / `10-remaining-work.md`.
**Fix guest/syscalls/manifest — never add tool names to host lists.**

| Gap | Symptom | Owner track |
|-----|---------|-------------|
| ~~Hardcoded `path_is_host_backed()`~~ | ~~Wrong lane for apk tools~~ | **Fixed in-repo** — manifest dispatch |
| Guest login env | Some CLIs skip open without DISPLAY | **Fixed** — `etc/profile.d/tether-env.sh` |
| SpawnExecuting no guest one-shot | JS CLI can't spawn guest ELFs in PATH | Mac / TermXNode |
| Single Blink session rules | Crash on parallel `blink_run` | I2, PROJECT-CONTEXT |
| `/workspaces/*` binds | Only `/work` mounted today | I2 |
| Syscall holes | Specific guest binaries fail | P7 harness |
| DEC 2031 / width | TUI layout glitches | P9 |
| ios_system tier | No native fast PATH yet | I1, P12 |
| fakefs rootfs | Large apk trees slow on device | P4 |

Update this file when a gap closes or a harness adds a new failure ID.

See **`GUEST-PLATFORM.md`** §8 for the diagnostic tree.
