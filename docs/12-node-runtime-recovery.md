# Node, npm, and Claude Runtime Recovery

## Outcome

Ship a stable Node lane that can run Node projects, install pure-JavaScript npm packages
into the app sandbox, and launch Claude Code in the user-selected workspace. The terminal
stays alive if a package fails, and every package is scoped to the app's approved storage.

## Verified state — 2026-08-22

| Check | Result |
|---|---|
| App launch with no automation | stable |
| Replacement binary | digidem `v24.19.0-1` **full** (Node 24.19.0, ICU, `--jitless`) |
| `node --version` / nested `node` spawn | `v24.19.0` / status 0 |
| `npm --version` / `npm install -g is-odd` | real CLI; package loads |
| `claude --version` (`@anthropic-ai/claude-code@2.1.110`) | `2.1.110 (Claude Code)` |
| Install path | `Frameworks/NodeMobile.xcframework` via `Frameworks/build-nodejs-mobile.sh` |

Official nodejs-mobile stopped at 18.20.4 / V8 10.2 (tiering crash under npm). digidem
24.19.0-1 full is the N1 pin: ICU is required for Claude Code's Unicode property regexes;
keep launching with `--jitless`. Claude releases ≥2.1.120 ship native darwin/linux bins
that cannot exec on iOS — pin the last pure-JS `cli.js` release (`2.1.110`) for the
launcher, or install that version explicitly with npm.


The upstream NodeMobile FAQ also states that Node modules are supported when prepared at
development time, while process-spawning APIs and `process.exit()` need mobile-specific
handling. Tether already supplies those mobile shims; the replacement runtime must be
validated against them before it replaces the currently vendored framework.

## Workstream N1 — vetted Node runtime

Owner: **Node Runtime**

1. Build a signed, reproducible `NodeMobile.xcframework` from the maintained
   nodejs-mobile source pinned to a current Node 22 LTS-compatible commit.
2. Build arm64-device, arm64-simulator, and x86_64-simulator slices with the current
   Xcode toolchain. Keep V8 in interpreter-only mode (`--jitless` at engine launch); do
   not enable runtime executable-memory allocation.
3. Replace `Packages/TermXNode/Vendor/NodeMobile.xcframework`, update
   `Frameworks/VERSIONS.node`, notices, SHA-256 manifest, and the build script.
4. Keep `termx_node_launch()` as the singleton dedicated engine thread. Its 8 MiB stack
   is now the project baseline for deep CLI module graphs.

Acceptance on both simulator and a physical iPhone:

```sh
node --version
node -e 'console.log(6 * 7)'
npm --version
npm install -g @anthropic-ai/claude-code
claude --version
```

Each command must return an exit code, write its output, leave the app alive for 30 seconds,
and produce no new Tether crash report.

## Workstream N2 — package manager

Owner: **Package Runtime**

Keep npm package data in `Library/Application Support/Tether/node`, not in the app bundle
or outside the selected workspace. The command adapter owns:

- registry metadata and tarball downloads over `URLSession`;
- integrity (`dist.integrity` / SHA-512) verification before extraction;
- semver dependency resolution, lockfiles, bins, and atomic staging/rename;
- `npm install`, `npm install -g`, `npm uninstall`, `npm list`, and `npm --version`;
- clear handling for native add-ons: use a prebuilt iOS slice approved by the app, otherwise
  report the required build rather than attempting `node-gyp` or executing downloaded code.

The existing `TarGzExtractor` and `NpmBootstrap` are starting points for fetch/extract and
atomic placement. The production interface belongs behind a dedicated `NpmService`, so
the shell never needs to know whether a package is prepared at build time or retrieved into
the sandbox.

Acceptance:

```sh
npm install is-odd
node -e 'console.log(require("is-odd")(3))'
npm install -g @anthropic-ai/claude-code
```

## Workstream N3 — Claude adapter

Owner: **Claude Integration**

1. Install the exact Claude Code version through `NpmService` into the global prefix.
2. Resolve the generated `claude` bin to its JavaScript entry point; never execute a shebang
   as a new OS process.
3. Route its file access to the security-scoped workspace, stdout/stderr to the active PTY,
   and `child_process` requests through the existing structured bridge.
4. Provide account login, credential storage in Keychain, cancellation, terminal resize, and
   a diagnostic bundle that removes tokens before export.
5. Run the published `claude --version`, `claude login`, and a read-only workspace task on a
   real device with a user-owned Anthropic account.

## Workstream N4 — release safety

Owner: **Integration and QA**

- Add a simulator automation batch that records one file per command plus an `app-alive`
  marker after npm and Claude complete.
- Run the same suite on a physical device, including background/foreground and low-storage
  cases.
- Preserve license notices for Node, NodeMobile, npm, and every bundled package; expose them
  in the Licenses screen.
- Treat packages, workspaces, credentials, and downloaded runtime data as user data with
  explicit delete/export flows.

## Ownership boundaries

| Area | Files owned |
|---|---|
| N1 runtime | `Frameworks/`, `Packages/TermXNode/Sources/NodeMobileBridge/`, `NodeMobileRuntime.swift` |
| N2 package manager | new `Packages/TermXNpm/` package, `TarGzExtractor.swift` integration |
| N3 Claude | `Packages/TermXClaude/`, Node shim compatibility tests |
| N4 integration | `App/IntegrationSource/`, `App/IntegrationTests/`, `docs/DEVICE-PASS.md` |

No workstream edits another owner's source without an explicit integration handoff and its
acceptance tests. This keeps the runtime replacement, package manager, Claude UI, and shell
work independently mergeable.
