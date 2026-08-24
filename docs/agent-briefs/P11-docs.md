# Track P11 — Documentation (markdown only)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Markdown only.** No code, no app repo access needed.
2. **Do not ask** for iOS source — write from spec below. Product name is **Tether** (never TermX).
3. **Deliver** 4 files + HANDOFF.md.
4. **Zip:** `tether-docs-P11.zip`

---

# Your job: architecture + validation docs

## Context
**Tether** is an iOS developer terminal. Production docs like ios-linuxkit's ARCHITECTURE / LIMITATIONS / VALIDATION / RELEASES. Always say **Tether**, never TermX.

## YOUR job ONLY
Four markdown files. **No code.**

## Deliver
```
tether-docs/
├── ARCHITECTURE.md
├── LIMITATIONS.md
├── VALIDATION.md
├── RELEASES.md
└── HANDOFF.md
```

## ARCHITECTURE.md
- Mermaid or ascii: UI → PTY → Shell → Registry → Native|WASM|Linux
- Claude OAuth flow
- host_exec bridge
- Repo folder map

## LIMITATIONS.md
Each gap: description + owner track (P1–I3) + status

## VALIDATION.md
Simulator + device checklists with copy-paste commands

## RELEASES.md
Versioning, TestFlight, App Store review note template

Study public ios-linuxkit doc **structure** only (GPL — no copying text).

## Zip: **`tether-docs-P11.zip`**

## License: your docs are CC-BY or MIT as you prefer
