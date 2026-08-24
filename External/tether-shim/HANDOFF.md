# @tether/shim

This standalone package implements the Node child-process, TTY and IPC boundary
used by embedded Node. It is a protocol implementation, not a collection of
program-specific responses.

## Behavior

- `spawn`, `spawnSync`, `exec`, `execSync`, `execFile`, `execFileSync` and
  `fork` serialize standard request fields to the host executor.
- stdout, stderr, exit status, signals, input, maxBuffer, cwd, environment and
  interactive mode follow Node-style behavior covered by the test suite.
- common browser opener executables remain ordinary spawn requests.
- `os` forwards native Node data and adapts only the job’s real `HOME` and
  `TMPDIR` values.
- `tty` reports the interactive state supplied for the active descriptors.
- socket and descriptor transports accept `TETHER_*` keys first and legacy
  `TERMX_*` keys for compatibility.

`fork()` can launch a Node entry through the executor but does not invent a
native Node IPC channel when the host has not supplied one; unsupported IPC is
reported rather than simulated.

## Verify

```sh
npm test
```

The tests use injected/standalone protocol servers; production uses
`NodeSpawnBridge.swift`. Request and reply keys must remain synchronized across
both implementations.
