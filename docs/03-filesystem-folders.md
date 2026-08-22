# C3 — Filesystem & Folder Access

**Goal:** The user picks any folder (local, iCloud Drive, or another app's storage via
Files providers) and the terminal runs *in that space* with full read/write, persisting
across launches — the iOS answer to "cd into any directory".

## How iOS makes this possible (all public API, all App Store-legal)

1. **`UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`** — system folder
   picker. Whatever the user picks, the app gets a security-scoped URL granting full
   recursive read/write to that folder — including folders outside our sandbox.
2. **Security-scoped bookmarks** — serialize that grant: `url.bookmarkData(...)`, store in
   app support; on next launch `URL(resolvingBookmarkData:)` + `startAccessingSecurityScopedResource()`
   restores access with no re-prompt. a-Shell's `pickFolder` is this exact pattern.
3. **iCloud Drive folders** work through the same picker; files may be evicted, so we
   call `FileManager.startDownloadingUbiquitousItem` before opening non-local files.

## Filesystem layout we present

```
$HOME  = <app sandbox>/Documents            (survives forever, user-visible in Files app)
 ├─ .profile, .termx_history, .config/...
 ├─ wasm/bin/            user-installed wasm commands
 ├─ python/              pip site-packages (C4)
 ├─ node/                npm prefix (C4)
 └─ linux/               Alpine rootfs (C6)

/workspaces/<name>       ← mount points for user-picked folders (the star feature)
```

- **Workspace = picked folder.** Session model: each terminal tab is bound to a workspace;
  new tab starts with `cwd = /workspaces/<name>`.
- Implement mount points as symlinks in a private dir + a path-resolution shim in
  TermXCore (ios_system already routes all command file access through thread-local cwd;
  we add a `realpath` hook so `/workspaces/foo/...` resolves to the security-scoped URL's
  path). Note: once access is started, the folder's real POSIX path works with normal
  `open()/read()/write()` — commands don't need changes.
- Keep grants alive: call `startAccessingSecurityScopedResource` once per workspace per
  session, balanced stop on close. Track leaks (iOS has a per-process limit of active
  scoped resources — pool them).

## Manager component

`WorkspaceManager` (Swift):
- `addWorkspace()` → shows picker, saves bookmark, returns Workspace
- `restoreAll()` on launch; stale bookmark → gentle re-pick prompt
- `recentWorkspaces` list for the launcher screen ("Open folder…" like VS Code)
- Watches folder (dispatch source / `NSFilePresenter`) → optional `fs events` for tools
- Exposes `resolve(path:) -> String` shim to TermXCore

## Rules & edge cases

- **Never** write user files outside the picked workspace or $HOME (trust = product).
- Deny-by-design paths (other apps' data, system dirs) simply don't appear; commands get
  clean `ENOENT/EACCES` — exactly like Unix permissions, so scripts behave sanely.
- `open .` command → `UIDocumentInteractionController`/ShareSheet; `open file.png` →
  QuickLook preview in-app. Nice touch, cheap to build.
- Files.app integration (later): expose $HOME via `FileProviderExtension` so other apps
  can see our home too.
- iCloud eviction: `ls` shows placeholder names fine; `cat` triggers download-on-open with
  a spinner message if slow.

## Deliverable

Swift package `TermXFiles`:
- `WorkspaceManager` + bookmark store (+ tests with mocked bookmarks)
- Path-resolution shim wired into TermXCore
- Launcher UI screen: recent workspaces grid + "Open Folder" button (SwiftUI)
- QuickLook/`open` helpers
