# Validation

The canonical entry point is `scripts/validate.sh`.

| Mode | Gate |
|---|---|
| `--quick` | all Swift packages, JS suites, WASI CTest, fakefs CTest, native-offload C tests, script syntax and component reports |
| `--network` | real Alpine bootstrap and package installation through host Blink |
| `--ios` | regenerate Xcode project and build the named iOS Simulator destination |
| `--all` | quick + network + iOS |

Quick validation requires Homebrew `libarchive` and `pkg-config` for the P4
archive-creation tests. Network validation is intentionally opt-in.

## Required interactive smoke

In one app session, run the sequence in `HOW-TO-RUN.md`, then verify:

- Ctrl-C interrupts `sleep 30` and returns a usable prompt.
- redirected Node output contains no cursor-control bytes.
- `xdg-open https://example.com` presents in-app Safari and the shell remains usable.
- an arbitrary workspace WASI module receives its arguments and exits.
- installing several unrelated Alpine packages does not restart or crash Tether.

## Failure rule

A skipped environment-dependent test is not evidence for that environment.
Device/OAuth results must be recorded separately; unit mocks and transfer-agent
handoff claims do not replace integration evidence.
