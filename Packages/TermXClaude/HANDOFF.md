# TermXClaude runtime notes

Claude Code’s packaged JavaScript is extracted from the real distribution and
executed by Tether’s embedded Node engine. The launcher supplies the minimum
Bun compatibility surface required by that distribution and preserves the
normal `BROWSER=open`/child-process route.

There is no Claude-specific PTY URL scraping or npm `open` replacement.
Browser requests use the same generic command bridge as every other Node CLI.
Older installed `termx-open-stub.js` files are removed during launcher refresh.
The official split graph imports built-ins through ESM, so the launcher copies
the active TJIP built-in implementations into Node's live ESM exports before
loading the graph. `Tests/RuntimeJS/claude-launcher.test.js` verifies both named
and default `child_process` ESM imports, extracted text/asset loading, and a
second launch after persistent-job teardown restores `Module._load`.

`ClaudeRuntime.swift` owns installation/probing, `TermXClaude.swift` owns
lifecycle and cancellation, and `Resources/launcher.js` plus `bun-shim.js`
form the runtime adapter. Account-backed login remains a signed-device release
gate, not a mocked completion claim.

Authentication is invoked as `claude auth login`; `claude login` is prompt
text in current releases and must not be used as the programmatic login route.

```sh
cd Packages/TermXClaude
swift test
```

See `docs/ARCHITECTURE.md`, `docs/VALIDATION.md`, and the bundled attribution
notice for the current contract.
