# TermX — Integration Status
*Last integration pass: 2026-08-22 · Xcode 26.2 · iPhone 17 Pro Simulator (iOS 26)*

## Headline

**The app builds, launches, and runs a real terminal with embedded Python, Node, and Linux
guest (Blink) on the Simulator.** Open a folder, get a pty shell, and run pipelines plus
`python3` / `node` / `linux` against workspace files.

## Runtime lanes (Simulator evidence, 2026-08-22)

| Command | Result |
|---|---|
| `python3 -c '…write(str(6*7))'` | `py_out.txt` → `42` |
| `import ssl, sqlite3` | `py_mods.txt` → `ok` |
| `node -e '…writeFileSync(..., String(2+2))'` | `node_out.txt` → `4` |
| `linux /bin/busybox echo hi` | `linux_out.txt` → `hi` (Alpine rootfs auto-bootstrapped) |
| Shell redirects / builtins | still green |

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

## Package tests (host)

- TermXNode 9/9 · TermXPython 6/6 · TermXLinux 8 (2 skipped) · TermXClaude unit tests unchanged

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
