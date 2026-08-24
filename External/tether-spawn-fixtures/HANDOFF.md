# Handoff — Track P10

## Verification

Command run:

```text
npm test
```

Full output:

```text

> claude-fixtures-p10@1.0.0 test
> jest --runInBand

PASS test/replay.test.js
  ✓ oauth-open: file is open (2 ms)
  ✓ oauth-open: URL is full HTTPS authorize URL (1 ms)
  ✓ oauth-open: environment is preserved (1 ms)
  ✓ oauth-open: expected exit is zero
  ✓ oauth-xdg-open: file is xdg-open without BROWSER (1 ms)
  ✓ oauth-xdg-open: URL is OAuth URL
  ✓ oauth-sensible-browser: fallback command is present
  ✓ oauth missing DISPLAY and Wayland means no spawn
  ✓ oauth DISPLAY permits BROWSER opener
  ✓ oauth Wayland permits fallback opener
  ✓ oauth opener preserves supplied env (1 ms)
  ✓ git-status: file is git (1 ms)
  ✓ git-status: args contain status
  ✓ git-commit: args are commit with message (1 ms)
  ✓ rg: file is rg (3 ms)
  ✓ rg: pattern and path are passed (1 ms)
  ✓ bash pipeline uses bash -c and shell (1 ms)
  ✓ npm lifecycle uses sh -c (1 ms)
  ✓ all fixtures replay without throwing (2 ms)
  ✓ replay sends exact P3 spawn shape
  ✓ interactive defaults are explicitly false (1 ms)
  ✓ cancel mid-oauth returns exit 130

Test Suites: 1 passed, 1 total
Tests:       22 passed, 22 total
Snapshots:   0 total
Time:        0.243 s, estimated 1 s
Ran all test suites.
```

## Fixture list

| Fixture | Scenario |
|---|---|
| `fixtures/oauth-open.json` | OAuth opener selected by `BROWSER=open` |
| `fixtures/oauth-xdg-open.json` | OAuth `xdg-open` fallback |
| `fixtures/oauth-sensible-browser.json` | OAuth `sensible-browser` fallback |
| `fixtures/git-status.json` | `git status --short` |
| `fixtures/git-commit.json` | `git commit -m ...` |
| `fixtures/rg-search.json` | ripgrep pattern and path |
| `fixtures/bash-pipeline.json` | `bash -c` pipeline |
| `fixtures/npm-lifecycle-sh.json` | npm lifecycle `sh -c` script |

The pack contains 22 Jest tests, including missing-display behavior, exact P3 request replay, and cancellation with exit code 130. It contains no Swift, iOS, Safari UI, or in-app browser code.
