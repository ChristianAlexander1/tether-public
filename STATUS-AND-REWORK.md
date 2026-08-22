# TermX — Integration Status
*Last integration pass: 2026-08-22 · Xcode 26.2 · iPhone 17 Pro Simulator (iOS 26)*

## Headline

**The app builds, launches, and runs a real terminal with embedded Python, Node, and a
Linux guest (Blink) on the Simulator** — verified end-to-end by the integrator on
2026-08-22, after fixing five bugs that made the shipping terminal freeze or silently
fail (see "Integration verification" below).

## Runtime lanes + shell (Simulator evidence, verified 2026-08-22)

Every row below was run inside the app in one session and confirmed by reading the app
sandbox afterwards:

| Command run in the terminal | Result on disk |
|---|---|
| `python3 -c 'open("b_py.txt","w").write(str(6*7))'` | `42` |
| `node -e 'require("fs").writeFileSync("c_node.txt",String(2+2))'` | `4` |
| `echo alive-after-node > d_after_node.txt` | `alive-after-node` (terminal survives Node) |
| `printf "one\ntwo\nthree\n" > src.txt` | three lines |
| `awk "{print NR}" src.txt` | `1 2 3` |
| `sed "s/one/ONE/" src.txt` | `ONE two three` |
| `cat src.txt \| wc -l` | `3` |
| `if [ -f src.txt ]; then echo yes; fi` | `yes` |
| `i=0; while [ $i -lt 3 ]; do echo n$i; i=$((i+1)); done` | `n0 n1 n2` |
| `echo count=$(ls \| wc -l)` | `count=9` |
| `linux /bin/busybox echo hi` | `hi` (Alpine rootfs auto-bootstrapped) |

## Integration verification (2026-08-22, integrator)

The embedding work was delivered as complete; verifying it uncovered **five blocking bugs**,
each now fixed with a regression test:

1. **Any one-word command crashed the app** — `ScriptParser.containsConstruct` computed
   `0..<(tokens.count - 2)`, which underflows on a short line. Typing `ls` or `jobs`
   killed the process.
2. **The terminal went deaf after any `node` command** — Node's stdin pump kept reading
   the pty after its job finished. `DispatchWorkItem.cancel()` cannot interrupt a thread
   already blocked in `read()`, so it swallowed everything typed afterwards. Replaced with
   a poll-based pump that can actually be stopped.
3. **`awk file.txt` hung the shell forever** — the external-command adapter slurped stdin
   to EOF for *every* command, and a terminal never sends EOF. `readAllStdin()` now
   returns nil when stdin is a tty.
4. **`printf` produced nothing** — it formatted its output and never wrote it, and both
   lexers plus the variable expander stripped backslashes inside double quotes.
   Backslash handling now follows the POSIX double-quote rules.
5. **Every counter loop was a no-op** — variables assigned inside a script were invisible
   to later expansions in the same script, so `while [ $i -lt 3 ]` never entered.

## Completed this pass (T1–T8 core)

| Task | Status |
|---|---|
| **T6** TermXCommands → TermXCore | ✅ |
| **T7** TermXShellLang → ShellSession | ✅ |
| **T1** NodeMobile.xcframework + `node_start` bridge | ✅ |
| **T8** Delivered `termx-shim` swapped in | ✅ |
| **T2** Python stdlib via BeeWare `install_python` build phase | ✅ |
| **T3** Blink.xcframework + auto Alpine bootstrap | ✅ (Simulator) |
| **T4** Claude e2e | ⚠️ Node unblocked; real `claude login` still needs a human account |
| **T5** Device pass / UX | ⚠️ Licenses screen + `docs/DEVICE-PASS.md`; physical device still manual |

## Package tests (host) — all green, 2026-08-22

| Package | Tests |
|---|---|
| TermXCore | 48 |
| TermXFiles | 30 |
| TermXShellLang (External) | 46 |
| TermXCommands (External) | 27 |
| termx-shim (External, JS) | 48 |
| TermXNode | 9 |
| TermXPython | 6 |
| TermXLinux | 8 (2 skipped) |
| TermXClaude | 6 |

## Repository hygiene

Git tracks 1112 files; the largest is a 272 KB font. The ~708 MB of xcframeworks
(Python 538 MB, NodeMobile 163 MB, Blink 7 MB) are **not** committed — they are
rebuilt by `Frameworks/build-blink.sh`, `Frameworks/build-nodejs-mobile.sh` and
`Packages/TermXPython/Scripts/build-termx-python-xcframework.sh`, as listed in
`Frameworks/README.md`. Working tree is clean.

## How to verify

```bash
cd TermX
xcodegen generate
xcodebuild -project TermX.xcodeproj -scheme TermX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation build

SIMCTL_CHILD_TERMX_AUTOWORKSPACE=1 \
SIMCTL_CHILD_TERMX_AUTOCOMMANDS='python3 -c '"'"'open("py_out.txt","w").write("42\n")"'"'
node -e '"'"'require("fs").writeFileSync("node_out.txt","4\n")"'"'
linux /bin/busybox echo hi > linux_out.txt' \
xcrun simctl launch "iPhone 17 Pro" com.termx.app
```

Physical-device checklist: [`TermX/docs/DEVICE-PASS.md`](TermX/docs/DEVICE-PASS.md).
Remaining task detail: [`docs/10-remaining-work.md`](docs/10-remaining-work.md).
