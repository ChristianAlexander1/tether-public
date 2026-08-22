# Tether — User Guide

Everything you can do in the terminal, how to install and remove things, and where they
are stored. Verified on the iPhone 17 Pro Simulator, 2026-08-22.

---

## 1. Opening a workspace

Tether only touches folders you choose. Tap **Add Folder**, pick one (local, iCloud Drive,
or any Files provider), and a shell opens inside it. That grant is remembered, so the
folder is still there next time you launch.

On the Simulator, enable **I/O → Input → Send Keyboard Input to Device** (⌘⇧K) to type
with your Mac keyboard.

---

## 2. What is already installed

These run natively and are always available — no installation needed:

**Files & navigation** `ls cd pwd cp mv rm mkdir rmdir touch ln find tree du df stat
readlink basename dirname realpath file mktemp`

**Text** `cat head tail wc sort uniq cut tr grep sed awk diff rev tac nl paste fold
expand unexpand comm join split shuf printf echo tee xxd hexdump base64 md5sum shasum`

**Search** `rg` (ripgrep) `fd` `jq`

**Shell** pipes `|`, redirects `> >> < 2>&1`, `&&` `||` `;` `&`, globs, `$VAR`, `$(cmd)`,
`$((math))`, `if/elif/else/fi`, `while`, `until`, `case`, functions, `for`, here-docs
`<<EOF`, `${VAR:-default}`, history, job control (`jobs`, `kill`, `fg`, `bg`)

**Languages** `python3` (CPython 3.14), `pip`, `node` (Node.js), `npm`, `npx`

**Other** `env export unset alias which type test [ true false sleep date uname
whoami id printenv hostname timeout expr seq yes clear history`

Type `help` to see the list on device.

---

## 3. Installing things

### Python packages — `pip`

```sh
pip install rich requests          # install
pip list                           # list what you installed
pip show rich                      # details for one package
pip uninstall rich                 # remove
pip install --upgrade rich         # upgrade
```
Installed into `$HOME/python/lib/python3.14/site-packages`.

### JavaScript packages — `npm`

```sh
npm install express                # into ./node_modules of the current folder
npm install -g typescript          # global, into $HOME/node
npm list                           # list local packages
npm list -g --depth=0              # list global packages
npm uninstall express              # remove local
npm uninstall -g typescript        # remove global
npm cache clean --force            # reclaim cache space
```

### Everything else — `apk` (Alpine Linux, ~24,000 packages)

This is Tether's equivalent of Homebrew. It runs in the built-in Linux guest.

```sh
linux /sbin/apk update             # refresh the package index (do this first)
linux /sbin/apk add git            # install
linux /sbin/apk add curl vim gcc make python3
linux /sbin/apk info               # list every installed package
linux /sbin/apk info -s git        # size of one package
linux /sbin/apk del git            # uninstall
linux /sbin/apk search nginx       # search for a package
linux /sbin/apk upgrade            # upgrade everything
```

Once installed, a program runs **by bare name** — no `linux` prefix needed:

```sh
apk add git        # (still needs the linux prefix: apk itself lives in the guest)
git --version      # → git version 2.45.4   ✅ works directly
```

---

## 4. Storage: where things live and how to reclaim space

Everything stays inside Tether's own sandbox; nothing else on the device is touched.

| What | Where | Typical size |
|---|---|---|
| Python packages | `$HOME/python/` | a few MB each |
| Node global packages | `$HOME/node/` | a few MB each |
| Node local packages | `./node_modules` in your project folder | varies |
| Alpine/`apk` packages | `$HOME/Documents/linux/` | ~5 MB base, 22 MB with git |
| Your files | the folder **you picked** | yours |

Check and clean up:

```sh
du -sh $HOME/Documents/linux        # how big is the Linux install
du -sh $HOME/python $HOME/node      # runtimes
rm -rf $HOME/Documents/linux        # wipe the Linux guest entirely (re-bootstraps next use)
rm -rf node_modules                 # wipe a project's JS packages
```

**Closing the app or the Simulator deletes nothing.** Installed packages persist. They are
removed only if you delete them yourself, delete the app, or erase the simulator
(`xcrun simctl erase "iPhone 17 Pro"`). On a real device the space shows under
Settings → General → iPhone Storage → Tether.

---

## 5. Useful recipes

```sh
# find and count
rg "TODO" -n .                       # search text fast
fd ".swift$"                         # find files by name
ls | wc -l                           # count entries
du -sh * | sort -rh | head           # biggest items here

# text processing
awk '{print NR, $1}' file.txt
sed -i 's/old/new/g' file.txt        # edit in place
cat data.json | jq '.items[0]'

# scripting
for f in *.txt; do echo "== $f"; head -3 "$f"; done
i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done
cat > run.sh <<'EOF'
#!/bin/sh
echo hello from a script
EOF
sh run.sh

# python / node
python3 -c 'print(6*7)'
python3 script.py
node -e 'console.log(process.version)'
npm init -y && npm install express
```

---

## 6. Known limits (honest list)

- **`git` runs through the Linux guest.** It works by bare name, but it is an emulated
  x86-64 binary, so it is slower than native, and **writing into your picked folder from
  guest programs is not wired up yet** — `git init` inside a workspace currently fails
  with "Read-only file system". Use it for read-only commands (`git --version`,
  `git log` in an existing guest folder) until the workspace bridge lands.
- **The guest shell form `linux /bin/sh -c "…"` is unreliable** and can hang. Run guest
  programs directly (`linux /sbin/apk add git`, `git --version`) instead.
- **`claude` is not yet exercised end to end** — Node works, but a real Anthropic login
  has not been tested.
- Native `git` (libgit2) is not built yet; it is on the roadmap.
- Guest programs are x86-64 interpreted; native commands, Python and Node run at full
  speed.

---

## 7. Frequently asked questions

### Why are Python and Node built into the app instead of downloaded on demand?

Because Apple requires it. App Store rule 2.5.2 forbids an app from downloading and
executing **native compiled code**. Python and Node are native ARM64 binaries, so they must
ship inside the signed app bundle — an app that downloaded them at runtime would be
rejected, and iOS would refuse to load them anyway.

What *may* be downloaded at runtime is code that something else interprets, which is
exactly why the rest works:

- `pip install …` — Python source packages, interpreted by the embedded Python ✅
- `npm install …` — JavaScript, interpreted by the embedded Node ✅
- `apk add …` — Alpine x86-64 binaries, **interpreted by Blink**, never run natively ✅

So `git` arrives through `apk` rather than being bundled: it is emulated, not executed.

### How big is the app, and can it be smaller?

The Debug Simulator build is ~211 MB, broken down as Node 110 MB, Python stdlib 56 MB,
app code 13 MB, Python framework 11 MB, extension frameworks ~12 MB.

A shipping build is much smaller, and two easy wins remain:

| Saving | Why |
|---|---|
| ~half of Node's 110 MB | the Simulator build is a fat x86_64 + arm64 binary; a device build carries arm64 only |
| ~36 MB of the Python stdlib | it currently includes CPython's own `test/` suite, which users never need |
| more, automatically | Release builds are stripped, and the App Store applies app thinning and compression to the download |

Realistically that lands near ~90 MB installed. Making Python or Node *optional downloads*
is not possible for the reason above; the achievable path is trimming what ships.

### If I install git in one folder, is it still there in another folder?

Yes. Installed tools are **app-wide, not per-folder**:

- `apk add git` → `$HOME/Documents/linux/` — available in every workspace
- `pip install …` → `$HOME/python/` — available everywhere
- `npm install -g …` → `$HOME/node/` — available everywhere

The one exception is a plain `npm install` (no `-g`), which by design creates
`node_modules` **inside the current project folder**, exactly as it does on a desktop. So
switching folders never makes you reinstall git; it only changes which project's local
`node_modules` you see.

### How do I see and reclaim storage?

Two ways.

**In the app:** open the menu in the terminal's toolbar → **Storage**. It lists the Linux
guest, pip packages, npm packages and caches with their real sizes, gives each a delete
button with a plain-language warning, and offers *Clear all caches* (which removes only
cached downloads, never installed packages). The menu also has **Files**, which browses the
folder the terminal is working in.

**From the terminal:**

```sh
du -sh $HOME/Documents/linux $HOME/python $HOME/node   # sizes
linux /sbin/apk info                                   # list Linux packages
pip list                                               # list Python packages
npm list -g --depth=0                                  # list global Node packages
linux /sbin/apk del git                                # uninstall one
pip uninstall rich
npm uninstall -g typescript
rm -rf $HOME/Documents/linux                           # wipe the Linux guest entirely
```
