# Track P10 — Generic spawn protocol fixtures (JavaScript)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS, no Safari UI code.
2. **Do not ask** for the iOS app.
3. **Naming:** product is **Tether**. Protocol `@tether/shim`. Never TermX/`termx`.
4. **Generic IPC tests** — NOT “Claude hardcoding”. OAuth is one sample URL only.
5. **All tests green** via `npm test` — paste output in HANDOFF.md.
6. **Zip:** `tether-spawn-fixtures-P10.zip`

---

# Your job: replay tests for the host↔shim spawn protocol

## One-sentence spec

Prove the **generic** `@tether/shim` IPC contract works for **any** spawn pattern —
browser openers, shell pipelines, arbitrary argv — using JSON replay + mock host.

**Do NOT** bake in Claude-specific logic in the mock host. The mock only understands
spawn / cancel / reply.

## YOUR job ONLY
Fixtures + mock host + tests. No Swift. No product-specific hacks.

## Deliver
```
tether-spawn-fixtures/
├── package.json
├── fixtures/
│   ├── url-opener-open.json
│   ├── url-opener-xdg-open.json
│   ├── url-opener-any-https.json      # NOT vendor-specific URL required
│   ├── shell-pipeline.json
│   ├── arbitrary-argv.json
│   ├── env-passthrough.json
│   ├── cancel-exit-130.json
│   └── sample-oauth-url.json          # example only — same as any https URL test
├── lib/mock-host.js
├── lib/replay.js
├── test/replay.test.js
├── SPAWN-PROTOCOL.md
├── URL-OPENER-SPEC.md
├── LICENSE
└── HANDOFF.md
```

## IPC (must match P3 exactly)

Spawn: `{"kind":"spawn","file":"...","args":[...],"cwd":"/work","env":{...},"interactive":false}`  
Cancel: `{"kind":"cancel"}` → exitCode 130

## Fixture rules

1. **url-opener-*** fixtures: assert `file` is opener basename + `args[0]` starts with `https://` — any host, not only claude.com
2. **arbitrary-argv.json**: random command name + args — mock returns exit 0
3. **env-passthrough.json**: DISPLAY, BROWSER, custom keys unchanged in JSON
4. **sample-oauth-url.json**: uses claude.com URL as **one example** of https URL — document that opener class handles all URLs the same way

## Tests — minimum **20**

| Test | Proves |
|------|--------|
| any https URL via open | generic URL opener |
| xdg-open without BROWSER | generic linux path |
| arbitrary argv replay | not tool-specific |
| env passthrough | generic |
| cancel → 130 | generic |
| all fixtures replay | no throw |

## URL-OPENER-SPEC.md

Document Linux rules (DISPLAY, BROWSER, xdg-open) as **platform behavior** — applies to
any CLI, not one product.

## SPAWN-PROTOCOL.md

Full request/reply schema for integrator.

## Do NOT

- Hardcode “if claude then …” in mock host
- Require Claude npm package
- List git/python/node as special cases in fixture runner

## License: MIT
