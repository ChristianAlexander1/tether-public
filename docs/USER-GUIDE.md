# Tether user guide

## Workspaces

Choose a folder with **Add Folder**. Tether stores the security-scoped bookmark
and mounts that folder at `/work` inside Alpine. Shell commands start there.

## Linux packages

Tether uses the normal Alpine package manager:

```sh
apk update
apk add --no-cache git python3 py3-pip curl vim ripgrep jq gcc make
git --version
python3 -c 'print(6 * 7)'
```

Installed files are real Alpine x86-64 binaries interpreted by Blink. They
persist in the app’s `Documents/linux` rootfs and are available to every
workspace. Remove packages with `apk del NAME`; use the app’s Storage screen to
inspect or reset runtime storage.

## Node and npm

Node is embedded because iOS cannot load downloaded native runtimes. JavaScript
packages remain normal interpreted code:

```sh
node -e 'console.log(process.version)'
npm install
npm install -g typescript
npm list -g --depth=0
```

Local `node_modules` belongs to the selected workspace. Global packages live
under the app’s Node home. Child commands use Tether’s generic spawn protocol;
unsupported commands fail with a normal nonzero result rather than being
silently imitated.

## WASI

Copy a wasm32-wasi module into the workspace and run:

```sh
wasm tool.wasm argument
```

The module receives explicit arguments, environment and standard descriptors,
and is confined to the selected workspace.

## Browser and local servers

Programs may use normal desktop commands:

```sh
xdg-open https://example.com
open https://example.com
```

These open in Tether’s in-app Safari presentation. A server bound to Alpine
loopback is not the Mac Simulator host’s loopback; test it with `curl` inside
the terminal.

## Shell behavior

Pipelines, redirections, background jobs and Ctrl-C are handled by Alpine and
Blink:

```sh
printf 'one\ntwo\n' | wc -l
sleep 30 &
wait
```

Tether does not preconfigure a Git author, email or editor. Configure them as
you would on another Linux machine.

## Storage and privacy

- workspace files remain in the folder you selected;
- the Linux rootfs and global runtime packages stay in Tether’s app container;
- closing the app does not delete packages;
- deleting the app removes its private runtime storage but not an external
  workspace owned by Files/iCloud.

Use the Storage UI for destructive cleanup so the target and reclaimed size are
visible before deletion.
