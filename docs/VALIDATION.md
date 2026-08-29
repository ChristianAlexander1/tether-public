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
- job control is real, not just a quiet startup: no `can't access tty` warning,
  and `sleep 30` / Ctrl-Z / `jobs` / `bg` / `jobs` / `fg` / Ctrl-C leaves a
  stopped, then running, then foregrounded, then interrupted job. Both Ctrl-C
  presses report shell status `130`, and the same shell stays usable.
- no guest process survives the login shell. With two `sleep 400 &` jobs and one
  stopped with Ctrl-Z, `exit` must leave no `Tether` process reparented to pid 1
  (`ps -eo pid,ppid,command | grep Tether.app/Tether`). Force-quitting the app,
  including `simctl terminate`, is `SIGKILL` and is expected to orphan jobs.
- redirected Node output contains no cursor-control bytes.
- `xdg-open https://example.com` presents in-app Safari and the shell remains usable.
- an arbitrary workspace WASI module receives its arguments and exits.
- installing several unrelated Alpine packages does not restart or crash Tether.
- `python3`, `python`, `pip3`, and `pip` all return to the same usable prompt;
  a clean pip user base bootstraps without first printing an import failure.
- in a non-home project directory, Claude accepts the trust dialog with Return,
  reaches its authenticated main UI, exits after two Ctrl-C presses inside its
  documented interval, and leaves shell and Node commands usable afterward.

For DEBUG simulator automation, `TETHER_AUTOCOMMAND_FILE` is line-oriented.
Ordinary lines are sent with a newline; `#delay N`, `#enter`, `#ctrlc`, `#ctrlz`, and
`#raw:TEXT` model pauses and terminal keys. `#enter` deliberately sends CR,
matching a physical Return key rather than shell-test LF.

`TETHER_TTY_TRACE=1` prints the bridge's foreground-process-group and terminal
signal decisions to stderr. Use it when a job-control result is wrong: it is
the difference between "the signal was never sent" and "the signal was sent and
ignored". It emits nothing unless the variable is set, so it is safe to leave
in place, and normal runs must show no `[tether-tty]` lines.

## Failure rule

A skipped environment-dependent test is not evidence for that environment.
Device/OAuth results must be recorded separately; unit mocks and transfer-agent
handoff claims do not replace integration evidence.
