# @tether/shim HANDOFF

Standalone Node package that replaces `child_process`, `os`, and `tty` by forwarding process launches to a host over newline-delimited JSON IPC.

Product name: **Tether**. Package: `@tether/shim`. Env prefix: `TETHER_*`.

## Load

```
node --require @tether/shim app.js
```

or `NODE_OPTIONS=--require=@tether/shim`.

## IPC protocol (host must match)

**Env (preferred):** `TETHER_IPC_FD` (write requests) + `TETHER_IPC_REPLY_FD` (read replies).

**Fallback:** `TETHER_IPC_SOCK` — unix domain socket, bidirectional.

Each message is one JSON object + newline.

### Spawn request

```json
{"kind":"spawn","file":"git","args":["status"],"cwd":"/work","env":{"KEY":"val"},"interactive":false}
```

Optional fields forwarded when set: `argv0`, `timeout`, `maxBuffer`, `killSignal`, `encoding`.

### Spawn reply

```json
{"ok":true,"exitCode":0,"stdout":"...\n","stderr":"","pid":12345}
```

ENOENT from host:

```json
{"ok":false,"code":"ENOENT","exitCode":null,"stdout":"","stderr":"","pid":0}
```

### Cancel (Ctrl+C / SIGINT)

```json
{"kind":"cancel"}
```

Reply:

```json
{"ok":true,"exitCode":130,"stdout":"","stderr":"","pid":...}
```

`ChildProcess.kill()` sends `cancel` and forces `exitCode` 130.

## Browser / OAuth spawn table

| Command | When | Args |
|---------|------|------|
| `open` | `BROWSER=open` or darwin default | `["https://..."]` |
| `xdg-open` | linux-style, `DISPLAY` set | `["https://..."]` |
| `sensible-browser` | fallback | URL |
| `wslview` | optional | URL |

Parent `env` is passed through unchanged (`DISPLAY`, `BROWSER`, `WAYLAND_DISPLAY`). Host should actually open the URL.

## os / tty

- `os.platform()` → `'darwin'`
- `os.homedir()` / `os.tmpdir()` — `HOME`/`TMPDIR` or `/Users/tether` and `/tmp`; override with `TETHER_HOME` / `TETHER_TMPDIR`
- `tty.isatty(fd)` → `true` when `TETHER_INTERACTIVE=1`

## fork IPC limits

`fork()` runs `node <module>` via the same spawn IPC. There is **no** Node IPC channel: `child.send()` returns `false`, `message` events never fire.

## Node APIs not implemented (or stubbed)

- Continuous stdin streaming after the spawn request is sent (bytes written in the first tick are included as `stdin` on the JSON request)
- `child.send` / `message` IPC for `fork` (`send()` returns `false`)
- Passing raw OS fds through `stdio` (numeric fds / IPC slot); `pipe` / `ignore` / `inherit` are applied locally
- `detached`, process groups, `uid`/`gid`, `windowsHide`
- Incremental/chunked stdout from the host (one reply buffer)
- `os.setPriority` is a no-op

## Tests

`npm test` — Node built-in test runner.

```

> @tether/shim@1.0.0 test
> node --test test/*.test.js

TAP version 13
# Subtest: browser / OAuth spawns
    # Subtest: 11 spawn open + https URL
    ok 1 - 11 spawn open + https URL
      ---
      duration_ms: 41.01943
      ...
    # Subtest: 12 spawn xdg-open + DISPLAY=:0
    ok 2 - 12 spawn xdg-open + DISPLAY=:0
      ---
      duration_ms: 39.481518
      ...
    # Subtest: 13 env DISPLAY/BROWSER preserved in JSON
    ok 3 - 13 env DISPLAY/BROWSER preserved in JSON
      ---
      duration_ms: 39.99739
      ...
    # Subtest: sensible-browser spawn
    ok 4 - sensible-browser spawn
      ---
      duration_ms: 36.124224
      ...
    # Subtest: wslview spawn
    ok 5 - wslview spawn
      ---
      duration_ms: 38.353812
      ...
    # Subtest: parent env passed when options.env omitted
    ok 6 - parent env passed when options.env omitted
      ---
      duration_ms: 35.342771
      ...
    # Subtest: open with BROWSER=open in process.env
    ok 7 - open with BROWSER=open in process.env
      ---
      duration_ms: 36.58839
      ...
    1..7
ok 1 - browser / OAuth spawns
  ---
  duration_ms: 268.718985
  type: 'suite'
  ...
# Subtest: child_process spawn/exec
    # Subtest: 1 spawn exit 0
    ok 1 - 1 spawn exit 0
      ---
      duration_ms: 43.875149
      ...
    # Subtest: 2 spawn exit 1
    ok 2 - 2 spawn exit 1
      ---
      duration_ms: 36.132408
      ...
    # Subtest: 3 spawnSync exit 0
    ok 3 - 3 spawnSync exit 0
      ---
      duration_ms: 66.200548
      ...
    # Subtest: 4 exec callback success
    ok 4 - 4 exec callback success
      ---
      duration_ms: 38.138877
      ...
    # Subtest: 5 execSync throw on nonzero
    ok 5 - 5 execSync throw on nonzero
      ---
      duration_ms: 66.89277
      ...
    # Subtest: 6 ENOENT has Node-accurate fields
    ok 6 - 6 ENOENT has Node-accurate fields
      ---
      duration_ms: 36.335599
      ...
    # Subtest: 7 shell:true uses sh -c
    ok 7 - 7 shell:true uses sh -c
      ---
      duration_ms: 36.1735
      ...
    # Subtest: 8 maxBuffer exceeded on exec
    ok 8 - 8 maxBuffer exceeded on exec
      ---
      duration_ms: 38.40609
      ...
    # Subtest: 9 cancel → exit 130
    ok 9 - 9 cancel → exit 130
      ---
      duration_ms: 35.993009
      ...
    # Subtest: 14 git status spawn
    ok 10 - 14 git status spawn
      ---
      duration_ms: 34.407459
      ...
    # Subtest: 15 rg spawn
    ok 11 - 15 rg spawn
      ---
      duration_ms: 37.938836
      ...
    # Subtest: 16 bash -c pipeline via shell:true
    ok 12 - 16 bash -c pipeline via shell:true
      ---
      duration_ms: 39.851599
      ...
    # Subtest: spawn emits spawn then exit then close
    ok 13 - spawn emits spawn then exit then close
      ---
      duration_ms: 35.183357
      ...
    # Subtest: execFile callback
    ok 14 - execFile callback
      ---
      duration_ms: 34.788764
      ...
    # Subtest: execFileSync returns stdout
    ok 15 - execFileSync returns stdout
      ---
      duration_ms: 68.548947
      ...
    # Subtest: execSync success returns stdout
    ok 16 - execSync success returns stdout
      ---
      duration_ms: 68.433039
      ...
    # Subtest: spawnSync ENOENT sets error
    ok 17 - spawnSync ENOENT sets error
      ---
      duration_ms: 66.407002
      ...
    # Subtest: fork documents no IPC and still runs
    ok 18 - fork documents no IPC and still runs
      ---
      duration_ms: 37.017221
      ...
    # Subtest: cwd is forwarded
    ok 19 - cwd is forwarded
      ---
      duration_ms: 37.443978
      ...
    # Subtest: argv0 forwarded
    ok 20 - argv0 forwarded
      ---
      duration_ms: 36.313326
      ...
    # Subtest: killSignal forwarded on request when set
    ok 21 - killSignal forwarded on request when set
      ---
      duration_ms: 35.902962
      ...
    # Subtest: spawnSync maxBuffer error
    ok 22 - spawnSync maxBuffer error
      ---
      duration_ms: 62.632095
      ...
    # Subtest: execFile nonzero callback error
    ok 23 - execFile nonzero callback error
      ---
      duration_ms: 37.304755
      ...
    # Subtest: execFileSync throws on nonzero
    ok 24 - execFileSync throws on nonzero
      ---
      duration_ms: 64.247578
      ...
    # Subtest: stdio pipe default exposes streams
    ok 25 - stdio pipe default exposes streams
      ---
      duration_ms: 38.125045
      ...
    # Subtest: pid is assigned
    ok 26 - pid is assigned
      ---
      duration_ms: 35.231676
      ...
    # Subtest: options as second arg to spawn
    ok 27 - options as second arg to spawn
      ---
      duration_ms: 35.579323
      ...
    # Subtest: shell string uses that shell
    ok 28 - shell string uses that shell
      ---
      duration_ms: 38.852293
      ...
    # Subtest: encoding utf8 on spawnSync
    ok 29 - encoding utf8 on spawnSync
      ---
      duration_ms: 65.501264
      ...
    # Subtest: default spawnSync stdout is Buffer
    ok 30 - default spawnSync stdout is Buffer
      ---
      duration_ms: 68.117468
      ...
    # Subtest: ChildProcess unref/ref/disconnect are no-throw
    ok 31 - ChildProcess unref/ref/disconnect are no-throw
      ---
      duration_ms: 38.335041
      ...
    # Subtest: cancel request kind is cancel
    ok 32 - cancel request kind is cancel
      ---
      duration_ms: 36.188263
      ...
    # Subtest: interactive true when TETHER_INTERACTIVE=1
    ok 33 - interactive true when TETHER_INTERACTIVE=1
      ---
      duration_ms: 36.357432
      ...
    # Subtest: execFile with options as args object
    ok 34 - execFile with options as args object
      ---
      duration_ms: 37.065333
      ...
    # Subtest: spawnSync status 1
    ok 35 - spawnSync status 1
      ---
      duration_ms: 69.275344
      ...
    # Subtest: false command via spawn
    ok 36 - false command via spawn
      ---
      duration_ms: 36.065001
      ...
    # Subtest: stdio ignore nulls streams
    ok 37 - stdio ignore nulls streams
      ---
      duration_ms: 37.435942
      ...
    # Subtest: stdio inherit is interactive
    ok 38 - stdio inherit is interactive
      ---
      duration_ms: 38.818804
      ...
    # Subtest: timeout option is forwarded and kills
    ok 39 - timeout option is forwarded and kills
      ---
      duration_ms: 37.583208
      ...
    # Subtest: spawnSync input becomes stdin on request
    ok 40 - spawnSync input becomes stdin on request
      ---
      duration_ms: 69.194454
      ...
    1..40
ok 2 - child_process spawn/exec
  ---
  duration_ms: 1816.332092
  type: 'suite'
  ...
# Subtest: index.js Module._load patch
    # Subtest: require("os") after --require is shim darwin
    ok 1 - require("os") after --require is shim darwin
      ---
      duration_ms: 35.749512
      ...
    # Subtest: require("node:os") is also patched
    ok 2 - require("node:os") is also patched
      ---
      duration_ms: 36.310883
      ...
    # Subtest: require("tty").isatty honors TETHER_INTERACTIVE
    ok 3 - require("tty").isatty honors TETHER_INTERACTIVE
      ---
      duration_ms: 39.181898
      ...
    # Subtest: package exports child_process os tty ipc
    ok 4 - package exports child_process os tty ipc
      ---
      duration_ms: 3.812625
      ...
    # Subtest: package.json name is @tether/shim
    ok 5 - package.json name is @tether/shim
      ---
      duration_ms: 0.537066
      ...
    1..5
ok 3 - index.js Module._load patch
  ---
  duration_ms: 117.16739
  type: 'suite'
  ...
# Subtest: os / tty
    # Subtest: 18 os.platform is darwin
    ok 1 - 18 os.platform is darwin
      ---
      duration_ms: 2.180915
      ...
    # Subtest: os.type is Darwin
    ok 2 - os.type is Darwin
      ---
      duration_ms: 0.140636
      ...
    # Subtest: os.homedir is a non-empty path
    ok 3 - os.homedir is a non-empty path
      ---
      duration_ms: 0.175047
      ...
    # Subtest: os.tmpdir is a non-empty path
    ok 4 - os.tmpdir is a non-empty path
      ---
      duration_ms: 0.138519
      ...
    # Subtest: os.homedir respects TETHER_HOME
    ok 5 - os.homedir respects TETHER_HOME
      ---
      duration_ms: 0.17746
      ...
    # Subtest: os.tmpdir respects TETHER_TMPDIR
    ok 6 - os.tmpdir respects TETHER_TMPDIR
      ---
      duration_ms: 0.156394
      ...
    # Subtest: 17 tty.isatty true when TETHER_INTERACTIVE=1
    ok 7 - 17 tty.isatty true when TETHER_INTERACTIVE=1
      ---
      duration_ms: 0.15693
      ...
    # Subtest: tty.isatty false when not interactive
    ok 8 - tty.isatty false when not interactive
      ---
      duration_ms: 0.11471
      ...
    # Subtest: tty.ReadStream setRawMode
    ok 9 - tty.ReadStream setRawMode
      ---
      duration_ms: 0.242123
      ...
    # Subtest: tty.WriteStream window size
    ok 10 - tty.WriteStream window size
      ---
      duration_ms: 0.320005
      ...
    # Subtest: os.cpus length
    ok 11 - os.cpus length
      ---
      duration_ms: 0.208929
      ...
    # Subtest: os.arch default arm64
    ok 12 - os.arch default arm64
      ---
      duration_ms: 0.216416
      ...
    # Subtest: os.userInfo has username and homedir
    ok 13 - os.userInfo has username and homedir
      ---
      duration_ms: 0.224087
      ...
    # Subtest: os.endianness LE
    ok 14 - os.endianness LE
      ---
      duration_ms: 0.125489
      ...
    # Subtest: os.EOL newline
    ok 15 - os.EOL newline
      ---
      duration_ms: 0.174158
      ...
    # Subtest: os.networkInterfaces has lo0
    ok 16 - os.networkInterfaces has lo0
      ---
      duration_ms: 0.142816
      ...
    # Subtest: os.constants.signals.SIGINT is 2
    ok 17 - os.constants.signals.SIGINT is 2
      ---
      duration_ms: 0.114207
      ...
    # Subtest: os.availableParallelism matches cpus
    ok 18 - os.availableParallelism matches cpus
      ---
      duration_ms: 0.287577
      ...
    # Subtest: os.getPriority / setPriority
    ok 19 - os.getPriority / setPriority
      ---
      duration_ms: 1.04402
      ...
    # Subtest: os.totalmem and freemem positive
    ok 20 - os.totalmem and freemem positive
      ---
      duration_ms: 0.181068
      ...
    # Subtest: os.uptime number
    ok 21 - os.uptime number
      ---
      duration_ms: 0.104803
      ...
    # Subtest: os.loadavg is three zeros
    ok 22 - os.loadavg is three zeros
      ---
      duration_ms: 0.645533
      ...
    # Subtest: os.hostname
    ok 23 - os.hostname
      ---
      duration_ms: 0.112283
      ...
    # Subtest: os.release and version
    ok 24 - os.release and version
      ---
      duration_ms: 0.097092
      ...
    # Subtest: os.machine
    ok 25 - os.machine
      ---
      duration_ms: 0.086179
      ...
    # Subtest: os.devNull
    ok 26 - os.devNull
      ---
      duration_ms: 0.086813
      ...
    1..26
ok 4 - os / tty
  ---
  duration_ms: 9.662389
  type: 'suite'
  ...
# Subtest: ipc
    # Subtest: 10 ipc unix socket round-trip
    ok 1 - 10 ipc unix socket round-trip
      ---
      duration_ms: 32.196331
      ...
    # Subtest: ipc cancel round-trip
    ok 2 - ipc cancel round-trip
      ---
      duration_ms: 40.260932
      ...
    # Subtest: ipc missing config throws ENOIPC
    ok 3 - ipc missing config throws ENOIPC
      ---
      duration_ms: 0.750561
      ...
    # Subtest: handleRequest ENOENT
    ok 4 - handleRequest ENOENT
      ---
      duration_ms: 0.129998
      ...
    # Subtest: sync socket helper round-trip
    ok 5 - sync socket helper round-trip
      ---
      duration_ms: 65.920499
      ...
    # Subtest: ipc FD pair writeSync/readSync
    ok 6 - ipc FD pair writeSync/readSync
      ---
      duration_ms: 86.144134
      ...
    1..6
ok 5 - ipc
  ---
  duration_ms: 225.905529
  type: 'suite'
  ...
1..5
# tests 84
# suites 5
# pass 84
# fail 0
# cancelled 0
# skipped 0
# todo 0
# duration_ms 4037.704006
```
