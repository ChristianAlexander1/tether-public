# Project context

Tether is a Linux-first iOS developer terminal. The selected folder is mounted
at `/work`; Alpine packages run as guest ELF programs under Blink. Embedded
Python, Node and WASI are platform runtime lanes, not per-application command
fakes.

## Invariants

- Guest ELF is the default dispatch result.
- Never block UIKit’s main thread on PTY, browser or process work.
- A terminal does not imply stdin EOF; do not drain an interactive PTY to EOF.
- Do not close a descriptor while another thread is blocked on it.
- Do not start a second Blink run while the login machine owns the guest.
- Do not forge OS, Git, hostname, CPU or memory data.
- New environment/configuration names use `TETHER_`; legacy `TERMX_` inputs are
  read only where compatibility still matters.
- Edit `project.yml` and regenerate `Tether.xcodeproj`.

## Canonical reading order

1. `ARCHITECTURE.md`
2. `GUEST-PLATFORM.md`
3. `VALIDATION.md`
4. `../STATUS-AND-REWORK.md`
5. `ENGINEERING-TARGETS.md`

The P1–P12 agent briefs and transfer folder were integration inputs, not ongoing
product documentation. Their completed components now live under `External/`
and `Vendor/` and are covered by the aggregate validation gate.
