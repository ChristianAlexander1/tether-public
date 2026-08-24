# Track P8 — libriscv spike

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No iOS.
2. **Do not ask** for the iOS app.
3. **Naming:** product is **Tether**. Folder `TetherRiscv`. Never TermX/`termx`.
4. **Deliver** spike + **REPORT.md** (required).
5. **Zip:** `TetherRiscv-P8.zip`

---

# Your job: evaluate riscv64 Alpine vs x86 Blink

## Context
Blink runs x86_64 Alpine (slower). Evaluate **riscv64 Alpine** via libriscv for speed/simplicity.

## YOUR job ONLY
Spike on Linux/macOS host + written report. No iOS.

## Deliver
```
TetherRiscv/
├── spike/             # minimal main.c loading libriscv
├── REPORT.md          # required
├── LICENSE
└── HANDOFF.md
```

## REPORT.md must answer
1. Does riscv64 Alpine minirootfs boot `/bin/uname`?
2. Simple benchmark vs Blink x86 on same machine (timer)
3. apk package count / compatibility notes
4. Estimated iOS integration effort (1–5 scale)
5. Recommendation: stay Blink / add riscv / replace

## Zip: **`TetherRiscv-P8.zip`**

## Open source
- [libriscv](https://github.com/libriscv/libriscv) BSD-3

## License: MIT (your glue code)
