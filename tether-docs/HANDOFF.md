# P11 handoff — Tether documentation

Track **P11** delivers architecture, limitations, validation, and release
documentation for **Tether**. No application source was available to this
track. Nothing in this folder is code.

Product name is **Tether**. Do not introduce any other product name into
these files.

License for this documentation set: [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

---

## 1. Delivered

```text
tether-docs/
├── ARCHITECTURE.md     runtime shape, diagrams, OAuth, host_exec, repo map
├── LIMITATIONS.md      every gap = description + owner (P1–I3) + status
├── VALIDATION.md       simulator + device checklists, copy-paste commands
├── RELEASES.md         versioning, TestFlight, App Store review template
└── HANDOFF.md          this file
```

Zip: `tether-docs-P11.zip` (created next to this folder, or containing it).

These five files are the whole P11 scope. There is no app target, no script
body beyond the copy-paste commands in VALIDATION / RELEASES, and no pass
counts.

---

## 2. How the four guides fit

| File | Question it answers | Owner after merge |
| --- | --- | --- |
| `ARCHITECTURE.md` | What are the layers, who talks to whom, where does a byte go? | P11 maintains; every other track updates on a boundary change |
| `LIMITATIONS.md` | What is missing, who owns it, is it a bug? | Row owner named in the table |
| `VALIDATION.md` | What do I type to prove a change? | I2 |
| `RELEASES.md` | How do we version, beta, and review? | I3 |

Read `ARCHITECTURE.md` first. Do not implement from `HANDOFF.md`.

---

## 3. Track map (P1–I3)

| Track | Name | First doc to read |
| --- | --- | --- |
| P1 | Terminal UI | ARCHITECTURE §3.1, LIMITATIONS L-UI-*, VALIDATION §4.4 / §5.3 keyboard |
| P2 | PTY | ARCHITECTURE §3.2, L-PTY-*, UTF-8 fixtures |
| P3 | Shell | ARCHITECTURE §3.3, L-SH-* |
| P4 | Registry | ARCHITECTURE §3.4, L-REG-* |
| P5 | Native / host_exec | ARCHITECTURE §3.5 and §5, L-SEC-02, L-NAT-* |
| P6 | WASM | ARCHITECTURE §3.6, L-WASM-* |
| P7 | Linux | ARCHITECTURE §3.7, L-LNX-* |
| P8 | Filesystem | ARCHITECTURE §6.1, L-FS-* |
| P9 | Network | ARCHITECTURE §6.2, L-NET-* |
| P10 | Claude OAuth | ARCHITECTURE §4, L-CLD-* |
| P11 | Documentation | this folder |
| I1 | iOS platform | ARCHITECTURE §8 and §11, L-IOS-*, L-SEC-* |
| I2 | Validation | VALIDATION.md entire |
| I3 | Release | RELEASES.md entire |

---

## 4. Assumptions made without the iOS tree

P11 wrote a *contract*, not a tour of an existing checkout. The following
are invented names that other tracks must either adopt or replace **in the
same PR that lands the real path**.

| Assumption | Where it appears | Reconcile with |
| --- | --- | --- |
| Package layout under `Apps/Tether` + `Packages/Tether*` | ARCHITECTURE §9 | actual workspace |
| Bundle id `app.tether.terminal` | VALIDATION, RELEASES | I1 / I3 Info.plist |
| URL scheme `tether://oauth/callback` | ARCHITECTURE §4, RELEASES §7 | P10 + I1 entitlements |
| `host_exec` allow-list of nine names | ARCHITECTURE §5.2 | P5 policy table |
| Session profiles `linux-first` / `native-first` | ARCHITECTURE §3.4 | P4 |
| Version file `Apps/Tether/Support/Version.xcconfig` | RELEASES §2 | I3 |
| Scripts `Scripts/validate-*.sh`, `Scripts/bump-version.sh`, `Scripts/mock-oauth.sh` | VALIDATION, RELEASES | I2 / I3 / P10 |
| First public line `0.1.0` build `1` | RELEASES §1 | I3 |
| Mock OAuth on simulator, real OAuth on device | VALIDATION §4.5 / §5.4 | P10 |
| Alpine-class AArch64 rootfs, interpreted, no JIT | ARCHITECTURE §3.7 | P7 |
| Signed WASM module index, no user-fetched modules | ARCHITECTURE §3.6, L-WASM-03 | P6 + I3 |

If the real tree already chose different names, **change the docs to match
the tree** unless the tree is a typo against this contract. Do not leave
both names alive.

Statuses in LIMITATIONS (`open`, `partial`, `in progress`, `planned`,
`accepted`) are P11's best reading of a v1 iOS developer terminal. Owners
should restamp them as soon as they have a build.

No pass counts, no syscall catalogue, no entitlement dump. Those need
source and a green gate.

---

## 5. What each track should do next

**P1–P10, I1.** Read your rows in LIMITATIONS.md. For every `open` or
`in progress` row you own, either land a fix + a VALIDATION fixture, or
move the row to `accepted` with a one-line reason.

**P5.** Publish the real `host_exec` allow-list. If it is longer than
ARCHITECTURE §5.2, add I1 commentary in the same PR. Independent review of
the broker is still `open` (L-SEC-02).

**P10.** Fill the authorize / token URLs and client id in package config
(not in these docs). Confirm PKCE S256, Keychain accessibility, and the
`claude-token` helper's stderr tokens match VALIDATION §4.5 / §5.4.

**I1.** Entitlements, associated domains spare for OAuth, VoiceOver on
chrome, jetsam behaviour. L-UI-06 and L-IOS-02 are the user-visible ones.

**I2.** Turn VALIDATION.md commands into `Scripts/validate-sim.sh` and
`Scripts/validate-device.sh`. Create the focused XCTest skeletons listed in
VALIDATION §6. Start `docs/reports/` only when a gate has been run.

**I3.** Replace the `0.1.0` / build `1` placeholders when the first archive
exists. Fill the three `<I3 fills>` slots in the App Store review notes
*before* any 1.x submission. Confirm export-compliance wording against
this year's form.

**P11 (follow-up).** After the first merge into the product repo, grep for
stale paths (`app.tether.terminal`, `Version.xcconfig`, allow-list names)
and restamp. Do not expand scope into CONTRIBUTING or a marketing site.

---

## 6. Merge instructions

1. Copy this folder to `docs/` at the product-repo root (ARCHITECTURE §9),
   **or** keep it as `tether-docs/` if the repo is docs-only for now.
2. Do not copy `tether-docs-P11.zip` into git; zip is the P11 transfer
   artefact.
3. Add a one-line pointer from the product README to `docs/ARCHITECTURE.md`.
4. In the same PR, if the tree already exists, fix every path this handoff
   marked as assumed.
5. License header: CC-BY-4.0 is declared at the top of each file. If the
   product repo is MIT for code, that is fine — keep the *docs* CC-BY-4.0
   or re-license the docs to MIT in a dedicated commit. Do not leave them
   unlicensed.

---

## 7. Explicit non-goals of P11

- No iOS source, no Swift packages, no Xcode project.
- No rootfs, no WASM modules, no Fastlane Ruby.
- No copying of third-party documentation text. ios-linuxkit was used as a
  *structure* reference only (separate files for architecture, limitations,
  validation, releases; tables; copy-paste gates; failure rules). All
  sentences here are original and describe Tether.
- No claim that a backend has shipped. Diagrams are the intended shape.

---

## 8. Change rule going forward

A PR that changes a boundary (new backend, new `host_exec` name, new URL
scheme, new version source, a limitation that becomes a feature) updates
the affected file in the same PR. A PR that only changes prose is P11.

If you are unsure which file to touch: behaviour → ARCHITECTURE,
missing behaviour → LIMITATIONS, how to prove it → VALIDATION, how to
ship it → RELEASES.
