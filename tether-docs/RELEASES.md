# Tether versioning and releases

Tether uses a semantic marketing version, a monotonically increasing Apple
build number, and a matching annotated Git tag. The three must name the same
commit before anyone uploads to App Store Connect.

This is the I3 contract. Signing identities, team ids, and App Store Connect
API keys are **not** in this file.

Related: [VALIDATION.md](VALIDATION.md), [LIMITATIONS.md](LIMITATIONS.md),
[ARCHITECTURE.md](ARCHITECTURE.md).

License: [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

---

## 1. Current version

Until I3 lands the first tagged archive, treat the intended first public line
as:

| Field | Value | Source |
| --- | --- | --- |
| Marketing version | `0.1.0` | `MARKETING_VERSION` / `CFBundleShortVersionString` |
| Apple build | `1` | `CURRENT_PROJECT_VERSION` / `CFBundleVersion` |
| Git tag | `v0.1.0` | annotated tag on the release commit |

Bump this table in the same commit that bumps the Xcode fields.

---

## 2. Version sources

| Value | Source | Consumed by |
| --- | --- | --- |
| Marketing version | `MARKETING_VERSION` in the app xcconfig (`Apps/Tether/Support/Version.xcconfig` or the I3-chosen equivalent) | `CFBundleShortVersionString`, this file, TestFlight what-to-test |
| Apple build number | `CURRENT_PROJECT_VERSION` in **every** configuration of the app target | `CFBundleVersion`, App Store Connect |
| Source tag | annotated Git tag `v<marketing version>` | provenance; never used as the App Store build number |

Rules:

- One marketing version maps to one or more build numbers (rebuilds, hotfix
  archives).
- A build number is used **once** on App Store Connect. Never reuse it, even
  for an identical binary.
- The Git tag is created *after* validation, on the exact commit that
  produced the archive.
- Debug, TestFlight, and App Store must not silently disagree on
  `CFBundleIdentifier` or Keychain access groups. If they must differ, the
  matrix lives in an I3 file next to `fastlane/` and is linked here.

Verify after every bump:

```sh
# From the repository root
grep -n 'MARKETING_VERSION' Apps/Tether/Support/Version.xcconfig
grep -n 'CURRENT_PROJECT_VERSION' Apps/Tether/Support/Version.xcconfig

# After an archive
plutil -p .ci/Tether.xcarchive/Products/Applications/Tether.app/Info.plist \
  | egrep 'CFBundleShortVersionString|CFBundleVersion|CFBundleIdentifier'
```

All app configurations must print the same build number.

---

## 3. Choosing the next version

Semantic versioning for the *shipped application*:

| Bump | When |
| --- | --- |
| **patch** | Compatible fixes. No new user-visible capability. Rootfs security rebuilds that do not change the contract. |
| **minor** | Compatible new capability: a backend feature, a new `host_exec` name, a terminal feature, a new shipped WASM module class. |
| **major** | Incompatible change: sandbox layout, URL scheme, OAuth client, registry policy that breaks scripts, or a rootfs that cannot open the previous overlay. |

Always increment the Apple build number for every uploaded archive, including
rebuilds of the same marketing version.

Pre-1.0 (`0.y.z`) may still bump `y` for capability and `z` for fixes. The
first App Store public release is `1.0.0` and requires a completed review-note
pass (see §7).

---

## 4. Bump procedure

Use the I3 script. Do not hand-edit three files and forget the fourth.

```sh
Scripts/bump-version.sh --marketing 0.1.1 --build 2
```

The script must:

1. write `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
2. update the table in this file
3. update any README / marketing version badge that I3 has declared canonical
4. refuse to run on a dirty tree unless `--allow-dirty` is passed (release
   commits should be clean)

Then:

```sh
git diff --check
git status --short
```

Follow [VALIDATION.md](VALIDATION.md) §9 (commit) and §5 (device archive)
before tagging.

---

## 5. Tag

Only after the device gate on *this* archive:

```sh
# marketing version 0.1.0 — replace as needed
git status --short          # must be empty
git tag -a v0.1.0 -m 'Tether 0.1.0'
git rev-parse HEAD
git rev-list -n 1 v0.1.0    # must equal HEAD
git push origin HEAD
git push origin v0.1.0
```

A tag is provenance. It does not prove that an `.ipa` was signed, notarised,
or uploaded. Record the archive UUID / App Store Connect build number in
`docs/reports/releases/` when I3 starts keeping those notes.

Never move a tag that has been uploaded.

---

## 6. TestFlight

### 6.1 Preconditions

- [ ] marketing version and build bumped
- [ ] simulator gate green on this commit
- [ ] device gate green on this **archive**
- [ ] no token material in logs or screenshots
- [ ] export options plist matches the TestFlight profile (I3)
- [ ] `CFBundleIdentifier` is the production id, not a developer-only id
- [ ] `tether://` URL scheme and (if used) associated domains are in the
      entitlements of *this* archive

### 6.2 Upload

I3 owns the lane. Shape:

```sh
# Prefer the checked-in lane so signing stays consistent
bundle exec fastlane ios beta
```

If Fastlane is not yet wired, Organizer → Distribute App → App Store Connect
→ Upload is acceptable for the first train. Do not mix the two methods on
the same build number.

### 6.3 Groups

| Group | Who | What they get |
| --- | --- | --- |
| `internal-eng` | Tether tracks P1–I3 | Every build that passed the device gate |
| `internal-design` | UI / a11y reviewers | Builds that change P1 / I1 chrome |
| `external-closed` | Named testers under NDA | Minor-or-greater bumps, after 24 h on internal with no blocker |

Do not add a public link until I3 and the project owner say so.

### 6.4 What to Test (paste into App Store Connect)

Keep this short. Testers ignore essays.

```text
Tether 0.1.0 (1)

What to try
• Open a session. Confirm the prompt, colours, and keyboard accessory (Esc, Ctrl, Tab, arrows).
• Rotate the device. The terminal size should follow.
• Background the app for a few seconds and return. The session should still be there.
• Sign in with Claude (device, not Simulator). Sign out. Sign in again.
• Files → pick a document → show its contents in the session.
• Optional: HTTPS curl to a public site; LAN SSH only if you are willing to grant Local Network.

Known limits
• This is a developer terminal, not a Linux VM. No Docker, no JIT, no general native downloads.
• Long jobs will die if iOS jetsams the app in the background.
• Simulator sign-in is mocked; please test Claude on a device.

Please report
• Crash on launch or on background/foreground.
• Torn Unicode, stuck winsize, or a keyboard that cannot send Ctrl-C.
• Any screen that shows an access token or refresh token.
```

### 6.5 Compliance answers (TestFlight / Export Compliance)

| Question | Answer | Notes |
| --- | --- | --- |
| Uses encryption | **Yes** — HTTPS / TLS only, standard OS and documented libraries | Not a proprietary cipher |
| Exempt under French / US ERN rules for HTTPS | **Yes**, if that is the current Apple wording | I3 confirms against this year's form |
| Third-party analytics IDFA | **No** unless a later track adds it | Adding it is a major privacy review |
| Login with a third party | **Yes** — Claude / Anthropic OAuth | Optional; app usable without it |

If Apple's form text changes, update this table, not the archive.

---

## 7. App Store review notes

Paste the following into App Store Connect → App Review Information → Notes
for the *first* 1.x submission, and whenever the interpreter / OAuth / URL
scheme story changes. Keep it factual. Do not mention other product names.

Attach a 2-minute screen recording: launch → type `echo hello` → resize →
sign-in chrome (not a live token) → sign-out.

```text
Review notes — Tether (developer terminal)

WHAT THE APP IS
Tether is a developer terminal that runs on the user’s iPhone or iPad. It
gives the device owner a shell, a text terminal, and three on-device
execution backends: (1) native commands bundled in the app, (2) a
WebAssembly interpreter for signed modules we ship, and (3) a user-mode
Linux userland that we interpret. Nothing in Tether downloads and executes
new native (Mach-O) code.

HOW TO REACH THE FIRST PROMPT
1. Install and launch Tether.
2. Grant any first-run keyboard / Files prompts you are comfortable with.
3. A session starts automatically. The first prompt is the product.

TEST ACCOUNT (Claude, optional)
Claude sign-in is optional. The terminal works without it.
Username: <I3 fills — a dedicated Anthropic reviewer account>
Password: <I3 fills — stored in the review account vault, not in git>
If sign-in is not exercised, skip any command that begins with `claude`.

WHAT REVIEWERS MAY TYPE
    echo hello
    stty size
    pwd
    printf 'caf\xc3\xa9\n'

Please do not expect Docker, a package-installer for native iOS binaries,
or background execution after the app is dismissed.

EXECUTION MODEL (App Review Guideline 2.5.2 / interpreter policy)
• Native tools are compiled into the app or shipped as signed helpers in
  the bundle. Users cannot add Mach-O binaries.
• WebAssembly modules come from a signed index we ship. Users cannot fetch
  and run arbitrary .wasm.
• Linux programs run under an instruction interpreter. Tether does not use
  JIT, MAP_JIT, or RWX pages.
• A mediated host_exec bridge exposes a short allow-list of host actions
  (clipboard, Files picker, URL open, Claude token helper). It is not a
  general process spawn.

OAUTH AND URL SCHEME
Sign in with Claude uses ASWebAuthenticationSession and OAuth 2.0 with
PKCE. The redirect URL scheme is tether://oauth/callback. Tokens are stored
in the Keychain on this device only. The guest environment never receives a
refresh token.

BACKGROUND AND NETWORK
Tether does not claim VoIP or unbounded background execution. Network use
is the user’s own HTTPS / SSH / package traffic. There is no hidden
always-on connection.

ACCOUNT DELETION
Claude sign-out is in Settings and removes tokens from the Keychain. An
Anthropic account itself is deleted on Anthropic’s side; we link to that
flow from Settings.

CONTACT
<I3 fills a monitored email and a phone number Apple can reach during review>
```

Replace the three `<I3 fills>` placeholders before the first submission.
Leaving them in is an I3 release-blocker.

---

## 8. Privacy nutrition and encryption

Minimum labels for the first submission. I3 confirms against the current
app and against whatever P10 actually sends.

| Category | Linked to user | Used for tracking | Purpose |
| --- | --- | --- | --- |
| Contact info (email) if Claude sign-in reveals one | Yes, if we display it | No | App functionality |
| User ID (Anthropic account id) | Yes | No | App functionality |
| Product interaction (optional, off by default) | No | No | — do not enable until a privacy spec exists |
| Diagnostics (opt-in crash logs via Apple) | No | No | App functionality |

No advertising SDK in v1. Adding one is a major-version conversation.

---

## 9. Hotfix

A store-blocking crash after `1.0.0`:

1. branch from the released tag, not from `main` if `main` has moved
2. bump **build** always; bump **patch** if the binary will be marketed as a
   new version
3. run the device gate on the hotfix archive
4. tag `vX.Y.Z` if the marketing version changed
5. upload; do not reuse the rejected or crashing build number
6. write `docs/reports/releases/` with the crash id and the fix revision

---

## 10. Checklist (copy into the release PR)

```text
## Release PR

- [ ] MARKETING_VERSION and CURRENT_PROJECT_VERSION match this file
- [ ] git tree clean
- [ ] VALIDATION.md simulator gate
- [ ] VALIDATION.md device gate on this archive
- [ ] What to Test text updated
- [ ] Review notes placeholders filled (1.x and any OAuth/interpreter change)
- [ ] Export compliance answers confirmed
- [ ] Privacy labels confirmed
- [ ] No tokens in screenshots or logs
- [ ] annotated tag on this commit (after merge, or on the release branch)
- [ ] App Store Connect build number recorded
```

A Git tag without an uploaded archive is not a release. An uploaded archive
without a tag is not a release either.
