# How to run and test TermX

## Run it

```bash
cd ~/Projects/terminal/TermX

# 1. (only after changing project.yml) regenerate the Xcode project
xcodegen generate

# 2. build
xcodebuild -project TermX.xcodeproj -scheme TermX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation build

# 3. install + launch on the Simulator
open -a Simulator
APP=$(xcodebuild -project TermX.xcodeproj -scheme TermX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR/{d=$3} /FULL_PRODUCT_NAME/{n=$3} END{print d"/"n}')
xcrun simctl install "iPhone 17 Pro" "$APP"
xcrun simctl launch "iPhone 17 Pro" com.termx.app
```

Or just open `TermX.xcodeproj` in Xcode and press ⌘R.

In the app: tap **Add Folder**, pick a folder, and the terminal opens inside it. Type with
the Mac keyboard (Simulator → I/O → Input → *Send Keyboard Input to Device*, or ⌘⇧K).

## Things to try

```sh
# shell
echo hi > a.txt ; cat a.txt ; ls | wc -l
printf "b\na\nc\n" > l.txt ; sort l.txt | head -2
if [ -f a.txt ]; then echo yes; fi
i=0; while [ $i -lt 3 ]; do echo n$i; i=$((i+1)); done
echo count=$(ls | wc -l)

# text tools
awk '{print NR, $1}' l.txt
sed 's/a/A/g' l.txt
diff a.txt l.txt

# Python  (real CPython 3.14)
python3 -c 'print(6*7)'
python3 -c 'import ssl, sqlite3; print("ok")'
pip install rich          # installs into $HOME/python

# Node (real Node.js)
node -e 'console.log(2+2)'
npm install express       # installs into ./node_modules of the current folder

# Linux lane — this is where you install anything else
linux /sbin/apk update
linux /sbin/apk add git
linux /usr/bin/git --version      # → git version 2.45.4  (verified)
linux /sbin/apk add python3 curl vim gcc make
linux /bin/sh                     # a full Alpine shell
```

**Verified working:** `apk update` reports **24,181 packages available**, and
`apk add git` installed 13 packages and ran `git version 2.45.4`.

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
- `xcrun simctl uninstall "iPhone 17 Pro" com.termx.app`, or
- erase the simulator: `xcrun simctl erase "iPhone 17 Pro"`, or
- delete the folder yourself from the terminal, e.g. `rm -rf $HOME/Documents/linux`.

On a real iPhone it behaves the same way and the space shows up under Settings → General →
iPhone Storage → TermX. Nothing is written outside the app except in the folder you picked.

## Scripted testing (no typing)

DEBUG builds accept two env hooks, so you can run a batch and check the results:

```bash
D=$(xcrun simctl get_app_container "iPhone 17 Pro" com.termx.app data)/Documents
SIMCTL_CHILD_TERMX_AUTOWORKSPACE=1 \
SIMCTL_CHILD_TERMX_AUTOCOMMANDS='python3 -c "print(6*7)" > py.txt
node -e "console.log(2+2)" > node.txt
linux /usr/bin/git --version > git.txt 2>&1' \
xcrun simctl launch "iPhone 17 Pro" com.termx.app
sleep 20 && cat "$D"/py.txt "$D"/node.txt "$D"/git.txt
```

## Run the test suites

```bash
cd ~/Projects/terminal/TermX
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  (cd Packages/$p && swift test); done
for p in TermXShellLang TermXCommands; do (cd External/$p && swift test); done
(cd External/termx-shim && npm test)
xcodebuild -scheme TermX -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation test
```

## Notes / current limits

- **`git` is not a built-in command yet** — use the Linux lane (`linux /usr/bin/git …`).
  A native `git` (libgit2) is still on the roadmap.
- The Linux lane is an **x86-64 interpreter**, so guest programs are slower than native
  ones. Native `python3`/`node` and the built-in commands run at full speed.
- `claude` needs a real Anthropic login (task T4), which has not been exercised yet.
