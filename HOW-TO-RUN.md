# How to run and test Tether

## Run it

Set `DEVICE` to whichever simulator you want; the rest of the block is identical
for iPhone and iPad.

```bash
cd ~/Projects/tether

DEVICE="iPhone 17 Pro"          # iPhone
# DEVICE="iPad Pro 11-inch (M5)"  # iPad

# 1. (only after changing project.yml) regenerate the Xcode project
xcodegen generate

# 2. build
xcodebuild -project Tether.xcodeproj -scheme Tether \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -skipPackagePluginValidation -skipMacroValidation build

# 3. install + launch on the Simulator
open -a Simulator
xcrun simctl boot "$DEVICE" 2>/dev/null || true
APP=$(xcodebuild -project Tether.xcodeproj -scheme Tether \
  -destination "platform=iOS Simulator,name=$DEVICE" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR/{d=$3} /FULL_PRODUCT_NAME/{n=$3} END{print d"/"n}')
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.tether.app
```

`xcrun simctl list devices available` shows the exact names to put in `DEVICE`.

Or just open `Tether.xcodeproj` in Xcode and press ⌘R, choosing the device from the
run-destination menu.

### Extra icons on the Simulator home screen

Running the UI tests installs a test-runner app that shows up as its own icon next to
Tether. It is a build artifact, not part of the app, and it comes back every time the
UI tests run. To clear them out:

```bash
DEVICE="iPhone 17 Pro"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl uninstall "$DEVICE" com.tether.TetherUITests.xctrunner   # current runner
xcrun simctl uninstall "$DEVICE" com.termx.TermXUITests.xctrunner     # pre-rename leftover
```

Only `com.tether.app` is the app itself.

In the app: tap **Add Folder**, pick a folder, and the terminal opens inside it. Type with
the Mac keyboard (Simulator → I/O → Input → *Send Keyboard Input to Device*, or ⌘⇧K).

## Things to try

You are in **Alpine Linux** (workspace = `/work`). Install tools with `apk` like a container:

```sh
uname -a
apk update
apk add git python3
git --version
python3 -c 'print(6*7)'

# Host-backed (same prompt — look like normal commands):
node -e 'console.log(2+2)'
claude --version
claude login
```

**Temp debug:** toolbar clipboard icon copies the full terminal log (commands +
output + errors, ANSI stripped) so you can paste it into chat. Remove later.

Set `TERMX_LOG_OPEN=1` to also mirror browser-open lines to the Xcode console.

The **Copy log** button (toolbar clipboard) bundles everything needed for debugging:

- **format: 3** — app version, device/simulator, Claude/Linux runtime state
- **Browser / open debug** — every `which open`, `xdg-open`, spawn intercept, Safari present
- **Claude login checklist** — shown automatically when no open events were recorded yet
- **Terminal output** — your session text (ANSI stripped)

Paste the **entire** clipboard contents into chat. If `format: 3` is missing, ⌘R rebuild and
reinstall on the Simulator.

### Browser / OAuth / localhost

`xdg-open` and `python3 -m webbrowser` open **inside the Tether app** (in-app Safari
sheet), not on your Mac desktop.

| URL kind | What happens |
|---|---|
| `https://…` (normal sites) | In-app Safari sheet inside the Simulator |
| Google / Anthropic / GitHub login | In-app Safari sheet; OAuth redirects to host `127.0.0.1` reach the Node listener inside the app |
| `http://127.0.0.1:PORT/…` from Alpine (`python3 -m http.server`) | **Guest localhost preview** — Alpine’s 127.0.0.1 is not Simulator Safari’s; Tether fetches the page with `curl` inside Linux and shows it in-app |
| `http://127.0.0.1:…` from Claude/Node OAuth | In-app browser; redirect completes on the iOS loopback where Node listens |

**Do not use Mac Safari** to test `python3 -m http.server` from the Tether terminal — `http://127.0.0.1:9999` on your MacBook is your **Mac**, not the Alpine guest inside the app. Only `xdg-open` inside Tether hits the guest server.

**Guest localhost recipe** (order matters — server must be running *before* `xdg-open`):

```sh
apk add python3          # once
echo '<h1>hello from guest</h1>' > index.html
python3 -m http.server 9999 &
sleep 1
xdg-open http://127.0.0.1:9999/
```

New shells auto-run `pkill` for stale `http.server` jobs left over when the app was closed.
Check guest port: `ss -ltn | grep 9999` (inside Tether terminal).

**Copy log:** use the toolbar clipboard button. A good log includes
`log format: 2` and `=== Browser / open debug ===`. If those lines are missing, ⌘R
rebuild — you are on an old build.

`uname` shows hostname **`tether`** (not your MacBook name). Bare `claude` opens
the interactive UI; if it ever crashes, copy the log and paste it here.

Legacy host shell (debug only): launch with `TERMX_HOST_SHELL=1`.

## Where installed things are stored (and how to reclaim space)

Everything lives **inside the app's own sandbox** — nothing touches the rest of the device.
`$HOME` is the app container, and the layout is:

| What you install | Where it goes |
|---|---|
| `pip install …` | `$HOME/python/lib/python3.14/site-packages` |
| `npm install -g …` | `$HOME/node/lib/node_modules` (local installs go in the project folder) |
| `linux /sbin/apk add …` | `$HOME/Documents/linux/…` (the Alpine rootfs) |
| Files you create in the terminal | the folder **you picked** — your real files, untouched by the app |

Measured after installing git: the whole Alpine rootfs was **22 MB** (git itself is a
2.9 MB binary). The base rootfs before installing anything is ~3–5 MB.

**Does it persist when you close the Simulator?** Yes — quitting the Simulator or the app
changes nothing; it is ordinary storage on disk. It goes away only when you:

- delete the app (removes the whole sandbox, including everything installed), or
- `xcrun simctl uninstall "iPhone 17 Pro" com.tether.app`, or
- erase the simulator: `xcrun simctl erase "iPhone 17 Pro"`, or
- delete the folder yourself from the terminal, e.g. `rm -rf $HOME/Documents/linux`.

On a real iPhone it behaves the same way and the space shows up under Settings → General →
iPhone Storage → TermX. Nothing is written outside the app except in the folder you picked.

## Scripted testing (no typing)

DEBUG builds accept two env hooks, so you can run a batch and check the results:

```bash
D=$(xcrun simctl get_app_container "iPhone 17 Pro" com.tether.app data)/Documents
# Prefer a harness file for longer batches (avoids SIMCTL_CHILD env size limits).
cat > "$D/.termx-harness.sh" <<'EOF'
python3 -c "print(6*7)" > py.txt
node -e "console.log(2+2)" > node.txt
npm --version > npm.txt 2>&1
EOF
SIMCTL_CHILD_TERMX_AUTOWORKSPACE=1 \
SIMCTL_CHILD_TERMX_AUTOCOMMAND_FILE="$D/.termx-harness.sh" \
xcrun simctl launch "iPhone 17 Pro" com.tether.app
sleep 20 && cat "$D"/py.txt "$D"/node.txt "$D"/npm.txt
```

Short one-liners still work via `SIMCTL_CHILD_TERMX_AUTOCOMMANDS='…'`.
## Run the test suites

```bash
cd ~/Projects/tether
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  (cd Packages/$p && swift test); done
for p in TermXShellLang TermXCommands; do (cd External/$p && swift test); done
(cd External/termx-shim && npm test)
xcodebuild -scheme Tether -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation test
```

## Notes

- The session **is Alpine** (Blink x86-64). Use `apk add git python3 …` — those run as **guest
  ELFs**, not host hacks. Workspace files live at `/work`. Only manifest-listed stubs
  (`node`/`npm`/`claude`) and URL openers (`open`/`xdg-open`) cross to the host.
- **Platform contract:** `docs/GUEST-PLATFORM.md`
- **Laptop continuity:** `/work` is your real picked folder (including `.git`).
- **Parallel development:** hand off tracks from `docs/agent-briefs/` (one `.md` per agent).
- **After all zips:** `docs/agent-briefs/MERGE-AND-VERIFY.md`
- **Architecture & gaps:** `docs/GUEST-PLATFORM.md`, `docs/LIMITATIONS.md`, `docs/06-linux-emulation.md`.
