# C7 — App Store Strategy & Licensing

**Goal:** Ship on the App Store, worldwide, under our own brand, with zero licensing
landmines. This doc is the rulebook every other component checks before adding a
dependency.

## License policy

**Green (bundle freely; attribution screen only):** MIT, BSD-2/3, ISC, Apache-2.0,
zlib, PSF, SIL-OFL (fonts), MirOS, public domain / Unlicense.

**Red (never compile into the app):** GPL (any version), AGPL. LGPL: avoid too (static
linking on iOS makes compliance awkward) — there is always a permissive alternative.

**Special:** Anthropic's Claude Code — user-installed via npm under the user's own
Anthropic agreement; we ship a launcher, never redistribute their package. Alpine
packages — downloaded by the user to their device; we redistribute nothing (iSH
precedent since 2020).

## The bill of materials (planned)

| Piece | Source | License | Status |
|---|---|---|---|
| Terminal emulator view | SwiftTerm | MIT | ✅ green |
| Command engine | ios_system (fork) | BSD-3 | ✅ green |
| Shell | mksh port (or dash) | MirOS / BSD | ✅ green |
| git | lg2 / libgit2 | BSD-3 / GPLv2-with-linking-exception (libgit2 is GPL2 **with linking exception** — bundling allowed, treated as permissive for linking; keep notice) | ✅ ok |
| ripgrep, fd, jq | Rust/C ports | MIT | ✅ green |
| curl/ssh stack | curl, libssh2, libressl | MIT-like / BSD | ✅ green |
| vim | ios_system port | Vim license (charityware, GPL-compatible-permissive-ish; a-Shell ships it) | ✅ ok |
| Python | CPython + BeeWare support pkg | PSF / MIT | ✅ green |
| Node | nodejs-mobile | MIT (Node itself MIT) | ✅ green |
| WASM runtime | wasm3 or WasmKit | MIT / Apache-2 | ✅ green |
| Linux engine | Blink | ISC | ✅ green |
| Fonts | JetBrains Mono, Fira Code | SIL-OFL | ✅ green |
| ❌ iSH emulator, bash, GNU coreutils, gdb | — | GPL | 🚫 replaced above |

Obligation: in-app **Settings → Licenses** screen with every notice (generate with a
script from a `NOTICES/` dir; add license file the moment a dep is added).

## App Store Review (Guideline 2.5.2) — the playbook

The rule: apps may not download & run *executable native code*; **interpreted code may be
downloaded and run** (with common-sense limits). Our precedents on the store today:
a-Shell (Python/pip/wasm), iSH (full Alpine!), Pyto, Code App, Pythonista.

Our compliance posture:
1. Native commands: all compiled into the signed app bundle. ✅ literal compliance.
2. Python/pip, npm/Node scripts, shell scripts: interpreted. ✅ explicitly allowed.
3. WASM: interpreted bytecode (wasm3 interprets; no JIT). ✅ a-Shell precedent.
4. Alpine/Blink: x86 binaries *interpreted* by an emulator — no downloaded code ever
   executes as native CPU instructions. ✅ iSH precedent (approved after the famous 2020
   appeal; still on the store in 2026).
5. No JIT anywhere. No dlopen of downloaded dylibs. No "app store for apps" framing.

Review-day tactics (learned from iSH/a-Shell history):
- Position the app as a **developer productivity tool** (category: Developer Tools —
  full of precedents).
- Review notes: explain the interpreter architecture up front, cite that all native code
  is in-bundle, list the precedent apps. Provide a demo login + a 2-min video.
- First submission: consider Linux-lane OFF by default/flagged for a fast first approval,
  enable in 1.0.1 (both iSH and a-Shell ultimately kept their features; this just
  de-risks v1 timing).
- If rejected: respond in Resolution Center citing 2.5.2's interpreted-code clause +
  precedents; appeal to the App Review Board if needed. This path is well trodden and
  it works.

## Other legal checklist

- Export compliance: uses standard encryption (HTTPS, ssh) → `ITSAppUsesNonExemptEncryption=false`
  + France declaration handled by standard exemption (libressl/libssh2 = standard crypto).
- Trademark: don't use "Claude" or "Anthropic" in app name/icon; describing compatibility
  ("run Claude Code") is nominative fair use. Same for "Linux" (say "Linux-compatible
  environment"; the Linux trademark has usage guidelines — fine in descriptions).
- Privacy label: terminal runs locally; network only where user commands it; no tracking.
  Easy, honest label = review goodwill.
- Our own license: app is closed-source & commercial (allowed by every green license
  above). Optionally open-source non-core packages later for community goodwill.

## Monetization note (decide later, affects nothing above)

Freemium is the proven shape: free terminal + Python; one-time "Pro" unlock (Node +
Claude Code launcher + Linux lane + iPad multi-window). All green licenses permit paid
distribution.
