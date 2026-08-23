# Tether — Integration Status
*Last integration pass: 2026-08-22 · Xcode 26.2 · iPhone 17 Pro Simulator (iOS 26)*

## Headline

**Tether builds, launches, and runs a real terminal with embedded Python, Node 24
(npm + Claude Code), and a Linux guest (Blink) on the Simulator.** Node/npm/Claude
were unblocked by replacing the crashed NodeMobile 18.20.4 binary with digidem
nodejs-mobile **v24.19.0-1 full** (ICU + `--jitless`), plus mobile shims for
`process.title`, `process.platform`, and nested `node` lifecycle scripts.

## Runtime lanes + shell (Simulator evidence, verified 2026-08-22)

Every row below was run inside the app and confirmed by reading the sandbox:

| Command run in the terminal | Result on disk |
|---|---|
| `python3 -c 'open("b_py.txt","w").write(str(6*7))'` | `42` |
| `node --version` | `v24.19.0` |
| `npm --version` | `10.8.2` (real registry CLI) |
| `npm install -g is-odd` then `require('is-odd')(3)` | `true` |
| `npm install -g @anthropic-ai/claude-code@2.1.110` | real install; `cli.js` bin |
| `claude --version` | `2.1.110 (Claude Code)` |
| `echo alive-after-node > d_after_node.txt` | `alive-after-node` |
| `linux /bin/busybox echo hi` | `hi` (Alpine rootfs auto-bootstrapped) |

## Node runtime pin

| Item | Value |
|---|---|
| Framework | `Frameworks/NodeMobile.xcframework` via `Frameworks/build-nodejs-mobile.sh` |
| Upstream | [digidem/nodejs-mobile](https://github.com/digidem/nodejs-mobile) `v24.19.0-1` **full** |
| Why full | lite has no ICU; Claude Code needs `\p{…}` Unicode property escapes |
| Engine flags | `--jitless` (App Store / iOS W^X) |
| Claude pin | `@anthropic-ai/claude-code@2.1.110` (last pure-JS `cli.js`; newer ships native bins) |

Details: `docs/12-node-runtime-recovery.md`.

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
6. **Redirects on compound commands were silently dropped** (found 2026-08-22) —
   `while …; done > f`, `for …; done > f`, and `if …; fi > f` never created the file; the
   trailing `> f` was mis-parsed as a separate command and the output went to the terminal.
   The script parser now captures trailing redirect words into a `.redirected` node, the
   evaluator hands the spec to `ShellHost.withRedirects`, and `RedirectScope` (TermXCore)
   applies it by swapping the session fds exactly as simple-command redirects do.
   Verified on the Simulator; regression tests in `CompoundRedirectTests` (TermXCore) and
   `RedirectedCompoundTests` (TermXShellLang).

**Also fixed 2026-08-22:** every `swift test` / app build failed after the repo moved from
`~/Projects/terminal` to `~/Projects/tether` — the per-package `.build` caches embed
absolute PCH paths from the old location. **If the repo ever moves again, delete every
`.build` directory first** (`find . -type d -name .build -maxdepth 3 | xargs rm -rf`).

## Completed this pass (T1–T8 core)

| Task | Status |
|---|---|
| **T6** TermXCommands → TermXCore | ✅ |
| **T7** TermXShellLang → ShellSession | ✅ |
| **T1** NodeMobile.xcframework + `node_start` bridge | ✅ |
| **T8** Delivered `termx-shim` swapped in | ✅ |
| **T2** Python stdlib via BeeWare `install_python` build phase | ✅ |
| **T3** Blink.xcframework + auto Alpine bootstrap | ✅ (Simulator) |
| **T4** Claude e2e | ✅ `claude --version` on Simulator (Node 24 + npm install); `claude login` still needs a human Anthropic account |
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
xcodebuild -project Tether.xcodeproj -scheme Tether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation build

SIMCTL_CHILD_TERMX_AUTOWORKSPACE=1 \
SIMCTL_CHILD_TERMX_AUTOCOMMANDS='python3 -c '"'"'open("py_out.txt","w").write("42\n")"'"'
node -e '"'"'require("fs").writeFileSync("node_out.txt","4\n")"'"'
linux /bin/busybox echo hi > linux_out.txt' \
xcrun simctl launch "iPhone 17 Pro" com.tether.app
```

Physical-device checklist: [`TermX/docs/DEVICE-PASS.md`](TermX/docs/DEVICE-PASS.md).
Remaining task detail: [`docs/10-remaining-work.md`](docs/10-remaining-work.md).
