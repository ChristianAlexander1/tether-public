# Tether

A real terminal for iPhone and iPad. Pick a folder, get a proper shell inside it — pipes,
redirects, loops, `python3`, `node`, and a Linux package manager — all running on the
device, with your files staying yours.

```
Documents % printf "one\ntwo\n" > src.txt
Documents % awk '{print NR, $1}' src.txt
1 one
2 two
Documents % python3 -c 'print(6*7)'
42
Documents % node -e 'console.log(2+2)'
4
Documents % linux /sbin/apk add git && git --version
git version 2.45.4
```

## Why it works at all

iOS forbids `fork`/`exec`, so a normal terminal is impossible. Tether runs **every command
inside the app process**: each one is a function invoked on its own thread with its own
file descriptors, wired to a real pty. Python is embedded CPython, Node is nodejs-mobile,
and anything else comes from an Alpine Linux userspace interpreted by Blink — which is how
`apk add` installs from ~24,000 packages without ever executing downloaded native code.

Everything bundled is under a permissive licence (MIT / BSD / ISC / Apache-2.0 / PSF), so
the app can ship on the App Store.

## Getting started

- **Run it:** [`HOW-TO-RUN.md`](HOW-TO-RUN.md)
- **Use it** (commands, installing and removing packages, storage): [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md)
- **Work on it** (architecture, rules, gotchas): [`docs/PROJECT-CONTEXT.md`](docs/PROJECT-CONTEXT.md)
- **Current state and verified evidence:** [`STATUS-AND-REWORK.md`](STATUS-AND-REWORK.md)

```bash
xcodegen generate
xcodebuild -project Tether.xcodeproj -scheme Tether \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation build
```

The three native xcframeworks (~708 MB: CPython, Node, Blink) are **not** in this repo —
rebuild them with the scripts listed in [`Frameworks/README.md`](Frameworks/README.md).

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app target, integration wiring, UI tests |
| `Packages/TermXCore` | Shell parser, command engine, built-in commands |
| `Packages/TermXUI` | SwiftTerm terminal view, pty, themes, keyboard bar |
| `Packages/TermXFiles` | Folder picker, security-scoped bookmarks, workspaces |
| `Packages/TermXPython` · `TermXNode` · `TermXLinux` · `TermXClaude` | Runtime lanes |
| `External/` | Packages built standalone: shell language, extra commands, the Node shim |
| `Frameworks/` | Build scripts and notices for the native binaries |
| `docs/` | Plans, contracts, guides, remaining work |

*(Swift module names still carry the project's former `TermX` prefix; the shipped app is
Tether.)*

## Status

The shell, Python, Node, the Linux lane and the folder picker are working and verified on
the Simulator; 220 tests pass across nine packages. Remaining work is tracked in
[`docs/10-remaining-work.md`](docs/10-remaining-work.md).
