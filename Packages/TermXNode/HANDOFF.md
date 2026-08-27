# TermXNode runtime notes

TermXNode embeds nodejs-mobile and serializes jobs through one persistent
engine. Host tests use the installed system Node with the same preload and
Unix-socket child-process protocol.

## Platform behavior

- `@tether/shim` is developed and tested in `External/tether-shim` and copied
  into this package’s resources.
- `child_process` requests are delegated to `SpawnExecuting`; the bridge does
  not probe iOS host paths for guest commands.
- standard opener commands use `SystemOpen` for any application and URL.
- `os` forwards Node’s native platform, CPU, memory, user, network and kernel
  data. Session `HOME`/`TMPDIR` are the only path adaptations.
- `tty.isatty` reflects the real job descriptor mode supplied by Swift.
- new IPC/job environment keys use `TETHER_*`; legacy `TERMX_*` keys remain
  accepted for compatibility.

The iOS engine starts with `--jitless`, because iOS does not permit writable
executable memory. `process.title` is virtualized so a JavaScript assignment
cannot corrupt nodejs-mobile’s process-wide host state.

## Verify

```sh
cd External/tether-shim && npm test
cd Packages/TermXNode && swift test
```

NodeMobile.xcframework is produced by `Frameworks/build-nodejs-mobile.sh` and
is ignored by Git. See `docs/ARCHITECTURE.md` and `docs/ENGINEERING-TARGETS.md` for the
guest/host boundary.
