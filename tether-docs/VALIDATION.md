# Tether validation

Every behavioural change needs a focused regression and a broader gate.
Simulator gates are necessary. They are not sufficient. A build that will be
installed on a person must pass the **device** checklist on the exact archive.

This file is the I2 contract. Copy-paste the commands. Do not retype them from
memory. If a path in the product repo differs, fix the script or this file in
the same PR.

Related: [ARCHITECTURE.md](ARCHITECTURE.md), [LIMITATIONS.md](LIMITATIONS.md),
[RELEASES.md](RELEASES.md).

License: [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

---

## 1. What a pass means

A row **fails** when any of these occur:

1. the command exits non-zero
2. the harness times out or is killed
3. a required row is skipped or silently reported as success
4. an unsupported facility is reported as `pass` instead of `unsupported`
5. the output came from a stale artefact, the wrong scheme, or a different
   commit than the one under test
6. a token, refresh secret, or Keychain dump appears in a log

A row is **unsupported** when the facility is listed as `accepted` in
[LIMITATIONS.md](LIMITATIONS.md) (Docker, JIT, raw sockets, …). Write
`unsupported` and a reason. Do not skip the row.

Package / rootfs / network bootstrap failures are **infrastructure**, not
emulator passes and not silent skips. Record them separately.

---

## 2. Environments

| Gate | Where | Proves |
| --- | --- | --- |
| Unit | macOS host, `xcodebuild test` | Packages in isolation |
| Simulator | iOS Simulator, signed with the development team | UI, PTY, registry, mocked OAuth |
| Device | Physical iPhone / iPad, the *archive* that would be uploaded | Keychain, ATS, Local Network, keyboard, jetsam, lifecycle |
| Linux-host (optional, P7) | AArch64 Linux | Userspace kernel fixtures only |

Never promote a build on unit + simulator alone.

### Gate table

Copy-paste from the matching section. Stop on the first fail.

| Gate | Where | Command / section |
| --- | --- | --- |
| Setup | Mac | [§3](#3-one-time-setup) |
| Clean build | Simulator | [§4.1](#41-clean-build) |
| Unit + package tests | Simulator | [§4.2](#42-unit--package-tests) |
| Install + launch | Simulator | [§4.3](#43-boot-a-fresh-simulator-and-install) |
| Interactive rows | Simulator | [§4.4](#44-interactive-simulator-rows) |
| Mock OAuth | Simulator | [§4.5](#45-mocked-oauth-on-the-simulator) |
| Simulator checklist | Simulator | [§4.7](#47-simulator-sign-off-checklist) |
| Archive | Device | [§5.1](#51-archive-the-same-thing-you-will-upload) |
| Install + launch | Device | [§5.2](#52-identity-on-the-device) |
| Interactive rows | Device | [§5.3](#53-interactive-device-rows) |
| Real Claude OAuth | Device | [§5.4](#54-real-claude-oauth-on-the-device) |
| Jetsam / a11y | Device | [§5.5](#55-jetsam--memory-smoke), [§5.6](#56-accessibility-spot-check) |
| Linux-host (optional) | AArch64 Linux | [§7](#7-optional-linux-host-gate-p7) |
| Before commit | Mac | [§9](#9-before-commit) |

Record with every run:

- git revision and dirty-tree state (`git status --short`)
- scheme, configuration, destination
- marketing version and `CFBundleVersion`
- device model + iOS version, or simulator runtime
- rootfs / WASM index stamps if those moved

---

## 3. One-time setup

Run from the repository root. Adjust `TETHER_ROOT` if you keep the checkout
elsewhere.

```sh
export TETHER_ROOT="${TETHER_ROOT:-$PWD}"
cd "$TETHER_ROOT"

# Xcode + CLT present
xcodebuild -version
xcrun simctl list runtimes | grep -i ios

# Team and bundle — do not commit secrets
export TETHER_SCHEME="${TETHER_SCHEME:-Tether}"
export TETHER_APP="${TETHER_APP:-Apps/Tether}"
export TETHER_BUNDLE="${TETHER_BUNDLE:-app.tether.terminal}"
export TETHER_TEAM="${TETHER_TEAM:?set TETHER_TEAM to the Apple team id}"

# DerivedData isolated from the personal default
export TETHER_DD="${TETHER_DD:-$TETHER_ROOT/.ci/DerivedData}"
mkdir -p "$TETHER_DD"

# Simulator destination: honour an override, otherwise the first available iPhone
# Do not hard-code a marketing name or an iOS version — those rotate every Xcode.
if [ -z "${TETHER_SIM_DEST:-}" ]; then
  TETHER_SIM_NAME="$(
    xcrun simctl list devices available -j \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
for rt,devs in d.get("devices",{}).items():
    if "iOS" not in rt: continue
    for dev in devs:
        if dev.get("isAvailable") and "iPhone" in dev.get("name",""):
            print(dev["name"]); raise SystemExit
'
  )"
  export TETHER_SIM_DEST="platform=iOS Simulator,name=${TETHER_SIM_NAME:?no available iPhone simulator}"
fi
echo "Using $TETHER_SIM_DEST"
```

List destinations when you need a UDID:

```sh
xcodebuild -showdestinations -scheme "$TETHER_SCHEME"
xcrun simctl list devices available
xcrun xctrace list devices
```

To pin a device for one run:

```sh
export TETHER_SIM_DEST='platform=iOS Simulator,name=iPhone 16 Pro'
```

---

## 4. Simulator checklist

Do these in order. Stop on the first fail unless the row is marked
`continue-on-fail` (infrastructure only).

### 4.1 Clean build

```sh
xcodebuild \
  -scheme "$TETHER_SCHEME" \
  -configuration Debug \
  -destination "$TETHER_SIM_DEST" \
  -derivedDataPath "$TETHER_DD" \
  -quiet \
  clean build
```

Treat new warnings introduced by the change as failures.

### 4.2 Unit + package tests

```sh
xcodebuild \
  -scheme "$TETHER_SCHEME" \
  -configuration Debug \
  -destination "$TETHER_SIM_DEST" \
  -derivedDataPath "$TETHER_DD" \
  test
```

If packages are tested independently:

```sh
for pkg in TetherPTY TetherRegistry TetherNative TetherClaude TetherFS TetherNet; do
  xcodebuild \
    -scheme "$pkg" \
    -destination "$TETHER_SIM_DEST" \
    -derivedDataPath "$TETHER_DD" \
    test
done
```

### 4.3 Boot a fresh simulator and install

```sh
# Clone a disposable sim so the gate does not touch a personal device.
# Device type + runtime are discovered; do not hard-code iPhone / iOS names.
SIM_DEVICE_TYPE="$(
  xcrun simctl list devicetypes -j \
    | python3 -c 'import json,sys
name=sys.argv[1]
types=json.load(sys.stdin)["devicetypes"]
hit=next((t["identifier"] for t in types if t.get("name")==name), None)
if not hit:
    hit=next((t["identifier"] for t in reversed(types) if "iPhone" in t.get("name","")), None)
print(hit or "")
' "${TETHER_SIM_DEST#*name=}"
)"
SIM_RUNTIME="$(
  xcrun simctl list runtimes -j \
    | python3 -c 'import json,sys
rts=json.load(sys.stdin)["runtimes"]
ios=[r for r in rts if r.get("isAvailable") and r.get("platform")=="iOS"]
print(ios[-1]["identifier"] if ios else "")
'
)"
test -n "$SIM_DEVICE_TYPE" && test -n "$SIM_RUNTIME"
xcrun simctl delete 'Tether-Gate' 2>/dev/null || true
SIM_UDID="$(xcrun simctl create 'Tether-Gate' "$SIM_DEVICE_TYPE" "$SIM_RUNTIME")"
xcrun simctl boot "$SIM_UDID" || true
xcrun simctl bootstatus "$SIM_UDID" -b

APP="$(find "$TETHER_DD/Build/Products/Debug-iphonesimulator" -name 'Tether.app' -maxdepth 2 | head -n1)"
test -n "$APP"
xcrun simctl install "$SIM_UDID" "$APP"
xcrun simctl launch --console-pty "$SIM_UDID" "$TETHER_BUNDLE"
```

`--console-pty` is the host's view of the app's stdout, not Tether's guest
PTY. Use it for launch failures only.

### 4.4 Interactive simulator rows

Type these *inside Tether* after launch. Expected results are in the
right-hand column.

```text
# identity
uname -a                          # Linux backend: Linux … aarch64; or a documented native uname
echo "$TERM"                      # xterm-256color (or the documented default)
stty size                         # matches the on-screen rows/cols

# PTY + UTF-8
printf 'caf\xc3\xa9\n'            # prints café, not cafÃ© or caf�
tput cols; tput lines             # integers; SIGWINCH after a rotate/split

# registry
tether-run --backend=native true  # exit 0
tether-run --backend=wasm   true  # exit 0 if a true module ships; else unsupported
tether-run --backend=linux  true  # exit 0
command -v claude-token           # resolves via registry to host_exec

# host_exec deny
tether-run --backend=native sh -c 'id'   # must fail; sh is not on the allow-list

# filesystem
pwd                               # inside the documented sandbox home
echo hi > /tmp/tether-gate.txt && cat /tmp/tether-gate.txt

# network (simulator)
curl -sI https://example.com | head -n1    # HTTP/2 200 or HTTP/1.1 200
```

Rotate the simulator (⌘←) and confirm `stty size` changes. That is the
winsize row; do not skip it.

### 4.5 Mocked OAuth on the simulator

The simulator cannot complete a production Anthropic login reliably (callback
scheme, Keychain access group, ITP). Use the P10 mock IdP:

```sh
# Starts a loopback authorize+token pair. P10 owns the script.
Scripts/mock-oauth.sh --port 8472

xcrun simctl openurl "$SIM_UDID" \
  'tether://oauth/callback?code=sim-code&state=STATE_FROM_UI'
```

Then, *inside Tether*:

```text
claude-token --mode access        # prints a non-empty token, nothing else
claude-logout                     # subsequent claude-token exits non-zero
```

Do **not** paste a real refresh token into a simulator log.

### 4.6 Tear down the gate simulator

```sh
xcrun simctl shutdown "$SIM_UDID" || true
xcrun simctl delete "$SIM_UDID" || true
```

Keep it only when you are iterating on a single failure.

### 4.7 Simulator sign-off checklist

Tick every box. A blank box is a failed gate, not a skip.

```text
# build
# [ ] §4.1 clean build exits 0
# [ ] no new compiler warnings introduced by this change
# [ ] §4.2 unit + package tests exit 0

# launch
# [ ] first prompt appears
# [ ] TERM is the documented default
# [ ] stty size matches the simulated display
# [ ] rotate (⌘←): stty size changes

# PTY
# [ ] printf 'caf\xc3\xa9\n' prints café
# [ ] Ctrl-C interrupts a yes-loop
# [ ] accessory bar sends Esc, Tab, arrows

# registry + backends
# [ ] tether-run --backend=native true  → 0
# [ ] tether-run --backend=linux  true  → 0
# [ ] tether-run --backend=wasm   true  → 0 or documented unsupported
# [ ] tether-run --backend=native sh -c 'id' is refused

# filesystem + network
# [ ] write + cat a file under /tmp
# [ ] curl -sI https://example.com returns HTTP/2 200 or HTTP/1.1 200

# mock OAuth
# [ ] claude-token before login → not-signed-in
# [ ] after mock callback, claude-token --mode access prints one line
# [ ] claude-logout then claude-token fails
# [ ] no access_token or refresh_token in simctl console output
```

---

## 5. Device checklist

Use a physical iPhone *and*, before the first TestFlight of a release train,
a physical iPad with a hardware keyboard.

### 5.1 Archive the same thing you will upload

```sh
xcodebuild \
  -scheme "$TETHER_SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$TETHER_DD" \
  -archivePath "$TETHER_ROOT/.ci/Tether.xcarchive" \
  clean archive

# Confirm versions match RELEASES.md
defaults read "$TETHER_ROOT/.ci/Tether.xcarchive/Info" ApplicationProperties
plutil -p "$TETHER_ROOT/.ci/Tether.xcarchive/Products/Applications/Tether.app/Info.plist" \
  | egrep 'CFBundleShortVersionString|CFBundleVersion|CFBundleIdentifier'
```

Export a development `.ipa` for the attached device, **or** install the
archive with Xcode's Organizer. Do not sideload a Debug build and call it the
device gate.

```sh
# If you use an export plist checked in by I3:
xcodebuild -exportArchive \
  -archivePath "$TETHER_ROOT/.ci/Tether.xcarchive" \
  -exportPath "$TETHER_ROOT/.ci/export-dev" \
  -exportOptionsPlist "$TETHER_ROOT/fastlane/ExportOptions-dev.plist"
```

### 5.2 Identity on the device

On the Mac, with the device unlocked and trusted:

```sh
DEVICE_UDID="${DEVICE_UDID:?set to the device UDID}"
xcrun devicectl list devices
xcrun devicectl device info details --device "$DEVICE_UDID"
```

Install and launch:

```sh
xcrun devicectl device install app --device "$DEVICE_UDID" \
  "$TETHER_ROOT/.ci/export-dev/Tether.ipa"

xcrun devicectl device process launch --device "$DEVICE_UDID" \
  --start-stopped=false \
  "$TETHER_BUNDLE"
```

### 5.3 Interactive device rows

Type these *inside Tether on the device*. Check every box.

```text
# launch
# [ ] first prompt appears in < 3s after splash on a warm start
# [ ] TERM and stty size match the display (notch / Dynamic Island safe area)

# keyboard
# [ ] software keyboard: Esc, Ctrl-C, Tab, arrows from the accessory bar
# [ ] hardware keyboard (iPad): Ctrl-C interrupts a yes-loop
# [ ] IME: type café and 日本語 without torn UTF-8

# lifecycle
# [ ] Home, wait 5s, return: session still alive
# [ ] Home, wait 15 minutes (or force a memory warning): restore UI offers a new session, no crash loop
# [ ] lock the device, unlock: Claude status is still "signed in" (or "unlock to use"), not a false sign-out

# host_exec
# [ ] claude-token without a login: stderr token `not-signed-in`, exit != 0
# [ ] files-pick: pick a file in Files, cat it in the session
# [ ] openurl https://example.com: in-app safari, not a crash
# [ ] pbcopy / pbpaste: round-trip a short string; a 5 MiB paste is refused

# deny
# [ ] host_exec of `sh` is refused
# [ ] writing outside the sandbox view is EACCES / a documented error

# network
# [ ] HTTPS curl to a public origin works on cell and on Wi-Fi
# [ ] a LAN SSH (if exercised) prompts for Local Network and then either connects or fails clearly
```

### 5.4 Real Claude OAuth on the device

Do this once per release train, not on every commit.

```text
# [ ] Sign in with Claude
# [ ] ASWebAuthenticationSession presents, completes, returns to Tether
# [ ] profile name appears
# [ ] claude-token --mode access prints one line
# [ ] kill the app from the app switcher, relaunch: still signed in
# [ ] sign out: Keychain item gone, claude-token fails, IdP session not assumed
# [ ] airplane mode, then claude-token: `network` (or a cached unexpired access token), never a deleted refresh token
```

Do not screenshot a token. Do not paste a token into a ticket.

### 5.5 Jetsam / memory smoke

```text
# [ ] start a Linux compile or a large `find` over the rootfs
# [ ] if the app is jetsammed, relaunch does not crash-loop
# [ ] overlay files that were fsync'd are still there; unsynced work may be gone
```

There is no pass threshold for “never jetsam.” The pass is “dies cleanly and
restores.”

### 5.6 Accessibility spot check

```text
# [ ] VoiceOver: sign-in button, tab strip, and palette are labelled
# [ ] Dynamic Type at the largest setting: chrome remains usable
# [ ] Reduce Motion: no required information lives only in an animation
```

The glyph grid a11y gap is [L-UI-06](LIMITATIONS.md#l-ui-06--voiceover-and-dynamic-type);
do not file it as a new regression unless chrome itself is unlabelled.

---

## 6. Focused fixtures

Small tests live next to the package they pin. Add one when you touch the
layer, do not only bump a broad gate.

| Area | Suggested path | Must cover |
| --- | --- | --- |
| PTY UTF-8 | `Tests/TetherPTY/UTF8ReassemblyTests.swift` | torn 2-, 3-, 4-byte sequences |
| winsize | `Tests/TetherPTY/WinsizeTests.swift` | `TIOCSWINSZ` + a fake `SIGWINCH` observer |
| registry | `Tests/TetherRegistry/ResolveTests.swift` | native/wasm/linux precedence, deny |
| host_exec | `Tests/TetherNative/HostExecPolicyTests.swift` | `sh` denied, path escape denied, cap exceeded |
| OAuth | `Tests/TetherClaude/PKCETests.swift` | S256, state mismatch, refresh single-flight |
| bookmarks | `Tests/TetherFS/BookmarkFailClosedTests.swift` | stale bookmark does not fallback to container |
| Linux ioctl bridge | P7 fixture next to the guest PTY | uncommon ioctl → `ENOTTY`, not a host crash |

A focused fixture should fail on the exact edge the change claims to handle
(aliasing, width, timeout, lock, first-unlock).

---

## 7. Optional Linux-host gate (P7)

Only when the userspace kernel or interpreter changed, and only on AArch64
Linux. This never replaces §4 or §5.

```sh
# P7 owns the exact Make/Ninja entry points. Shape:
cmake --build build-linux --target tether-linux-tests
ctest --test-dir build-linux --output-on-failure
```

A Linux-host pass with a failed device PTY bridge is a failed change.

---

## 8. Diagnostics

Safe to leave on during an investigation; **not** part of exact-output gates:

```sh
export TETHER_LOG=pty,registry,hostexec   # no token values
export TETHER_HOSTEXEC_TRACE=1            # names + exit + duration
```

Forbidden in CI logs:

- `access_token`, `refresh_token`, Authorization headers
- Keychain dumps
- the body of a `files-pick` document

If a log line would be enough to replay a user's Claude session, it is a
validation failure of the logging code, not just a redaction miss.

---

## 9. Before commit

Minimum, on the developer's Mac:

```sh
git diff --check
git status --short

xcodebuild \
  -scheme "$TETHER_SCHEME" \
  -destination "$TETHER_SIM_DEST" \
  -derivedDataPath "$TETHER_DD" \
  build test
```

Plus the focused fixture for the layer you touched.

Before a release commit, also run §5 on the archive and follow
[RELEASES.md](RELEASES.md).

---

## 10. Evidence

Write a short note when a gate is run for a release, not for every PR:

```text
docs/reports/YYYY-MM-DD-<gate>.md
```

Include revision, destination, pass/fail/unsupported table, and a pointer to
the artefact checksum. Do not paste tokens. Dated numbers in old reports are
not the current result.

P11 does not invent pass counts. I2 fills them in when the suite exists.
