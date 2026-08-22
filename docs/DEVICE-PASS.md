# Tether physical-device pass

Manual checklist for a real iPhone/iPad. Automated package tests cover logic; this pass confirms sandbox, security-scoped bookmarks, and UI on device.

Mark each item `[x]` when verified. Record device model, iOS version, and build in the notes section.

## Environment

- Device:
- iOS:
- TermX build / commit:
- Tester:
- Date:

## Checklist

### Bookmark persistence across relaunch

1. Launch TermX → **Add Folder** → pick a folder (On My iPhone or iCloud Drive).
2. Confirm the workspace opens and `ls` lists contents.
3. Force-quit TermX (app switcher → swipe away).
4. Relaunch.
5. **Pass:** workspace still opens without re-picking; files remain readable/writable.

### iCloud-evicted file download

1. Pick an **iCloud Drive** folder as the workspace.
2. Ensure a file in that folder shows the cloud download icon in Files (evicted / not local), or add a file from another device and wait for Optimize Storage eviction.
3. In TermX: `cat` (or open) that file path under the workspace.
4. **Pass:** content appears after a short download; no permanent access / I/O failure.

### Security-scope leak check (100 open/close)

1. With a workspace selected, repeatedly leave and re-enter it (or open/close the bound session) **100 times**, or at least 20 rapid cycles if 100 is impractical, then spot-check with Instruments.
2. After the cycles, run a simple read/write (`ls`, `echo hi > …`, `cat …`).
3. **Pass:** no `accessDenied` / scope failures; app stays responsive. Prefer Instruments → File Activity with no growing security-scope leak warnings.
4. Automated counterpart (macOS CI): `testAccessScopeBalancedAfter100Cycles` in TermXFiles.

### Tabs / multi-window

- **Tabs:** multiple terminal tabs are not shipped in this build — N/A until C1 tabs land (`docs/01-terminal-ui.md`).
- **iPad multi-window:** multi-scene / side-by-side folders are not shipped — N/A until UIScene multi-window lands.
- When either ships, re-run: two workspaces side by side, independent cwd/security scope, no cross-talk.

### Font size (pinch if present)

- Current UI exposes font size via the terminal toolbar menu **Stepper** (10–24 pt), not pinch-to-zoom.
- **Pass:** open the `…` menu → change Font pt → glyphs resize immediately.
- If pinch-to-zoom is added later, verify pinch in/out changes size smoothly without breaking selection or keyboard accessory.

## Notes

_(failures, screenshots, Instruments observations)_
