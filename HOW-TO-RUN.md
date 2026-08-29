# Build and run Tether

Run commands from the repository root.

## Requirements

- macOS with Xcode and an installed iOS Simulator runtime
- XcodeGen: `brew install xcodegen`
- Swift Package Manager, CMake, Node and npm
- `brew install cmake libarchive pkgconf` for the complete validation suite
- local `Frameworks/Blink.xcframework`, `Frameworks/NodeMobile.xcframework`,
  and `Frameworks/TermXPython.xcframework`

If a required framework is missing, build or fetch it with:

```sh
./Frameworks/build-blink.sh
./Frameworks/build-nodejs-mobile.sh
./Packages/TermXPython/Scripts/build-termx-python-xcframework.sh
```

The framework scripts may download their pinned upstream inputs.

## One-command Simulator run

This generates the project, boots the Simulator, builds Tether into the local
ignored `build/` directory, installs the app, launches it, and opens Simulator:

```sh
./scripts/run-simulator.sh
```

This performs a data-preserving Simulator upgrade. Before installation it makes
a temporary backup of Tether's data container; if CoreSimulator assigns a new
container UUID, the script restores the backup before launch. The Linux rootfs,
installed Alpine packages, Claude download, authentication, and workspace files
therefore survive rebuilds. To deliberately delete that app data and start from
a fresh install, use:

```sh
./scripts/run-simulator.sh --reset-data
```

The default destination is `iPhone 17 Pro`. To use another installed device:

```sh
TETHER_SIMULATOR_NAME='iPhone 16 Pro' ./scripts/run-simulator.sh
```

List available destinations with:

```sh
xcrun simctl list devices available
```

## Equivalent manual build

```sh
xcodegen generate
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null || true
xcrun simctl bootstatus 'iPhone 17 Pro' -b

xcodebuild \
  -project Tether.xcodeproj \
  -scheme Tether \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$PWD/build/ios-simulator/DerivedData" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

xcrun simctl install 'iPhone 17 Pro' \
  "$PWD/build/ios-simulator/DerivedData/Build/Products/Debug-iphonesimulator/Tether.app"
xcrun simctl launch 'iPhone 17 Pro' com.tether.app
open -a Simulator
```

## Remove Tether build caches

This removes this repository's `.build`/`.swiftpm` directories, its local
`build/` output, `Frameworks/.build`, and only Xcode DerivedData directories
whose names begin with `Tether-`:

```sh
./scripts/clean-builds.sh
```

Also uninstall Tether and its data from the currently booted Simulator:

```sh
./scripts/clean-builds.sh --simulator
```

The cleanup does not delete shared Xcode caches, other Simulator apps/devices,
the source tree, or the required xcframeworks. `Frameworks/.build` contains the
rebuildable host Blink output; rerun `Frameworks/build-blink.sh` before host
Linux/network acceptance after cleaning.

## Validation gates

```sh
./scripts/validate.sh --quick    # Swift, JS and native component suites
./scripts/validate.sh --network  # real Blink/Alpine download and apk tests
./scripts/validate.sh --ios      # regenerate and compile the Simulator app
./scripts/validate.sh --all      # all gates
```

`--network` downloads an Alpine minirootfs and packages. `--ios` uses temporary
DerivedData and removes it when the gate exits; use `run-simulator.sh` when you
want the built app retained for installation.

## Linux smoke sequence

Run inside one Tether terminal session:

```sh
uname -a
apk update
apk add --no-cache git python3 ripgrep build-base
git --version
python3 -c 'print(6 * 7)'
rg --version
gcc --version
printf 'hello\n' | wc -l
xdg-open https://example.com
node -e 'console.log(6 * 7)'
```

These are real Alpine packages and guest commands. Only manifest-declared
platform runtimes and desktop opener capabilities cross into app services.

Install or refresh Claude from Storage, then authenticate from the terminal
with the current CLI contract:

```sh
claude --version
claude auth status
claude auth login
```

Login presents the authorization URL through Tether's in-app browser bridge.
`claude login` is not an authentication subcommand; current Claude releases
interpret it as prompt text.

Run an arbitrary WASI module from the selected workspace with:

```sh
wasm module.wasm arg1 arg2
```

## Debug launch variables

- `TETHER_UI_TEST_MODE=1` is required before any automation-only workspace or
  command variable below is honored
- `TETHER_AUTOWORKSPACE=1`
- `TETHER_AUTOCOMMANDS='command1\ncommand2\n'`
- `TETHER_AUTOCOMMAND_FILE=/absolute/path/to/commands.sh`
- `TETHER_PTY_LOG=1` mirrors debug PTY bytes to the app-owned
  `Documents/.tether-pty.log`
- `TETHER_HOST_SHELL=1` selects the host shell; Alpine is the product default

TJIP/2 is the only Node IPC lane: per-fd `isTTY` from the protocol handshake,
real PTY geometry pushed on resize, true colour depth, live stdin over
`tty.stdin`, and `spawn.kill`. The v1 newline-JSON lane is gone.

Legacy `TERMX_` aliases remain readable for existing automation, but new usage
should use `TETHER_`.

### Checking the TJIP/2 lane by hand

```bash
SIMCTL_CHILD_TETHER_UI_TEST_MODE=1 SIMCTL_CHILD_TETHER_AUTOWORKSPACE=1 \
SIMCTL_CHILD_TETHER_PTY_LOG=1 \
SIMCTL_CHILD_TETHER_AUTOCOMMANDS='node -e "console.log(process.stdout.columns, process.stdout.getColorDepth())"' \
xcrun simctl launch 'iPhone 17 Pro' com.tether.app
```

Then read `Documents/.tether-pty.log` inside the app container
(`xcrun simctl get_app_container 'iPhone 17 Pro' com.tether.app data`). The size
must match the on-screen terminal, not 80x24, and the depth must be 24.

## Physical device

Set a development signing team, select the iPhone/iPad destination, and build
the same `Tether` scheme. Complete [docs/DEVICE-PASS.md](docs/DEVICE-PASS.md)
before release; confirm signed-device and account OAuth results on hardware in
addition to the Simulator build.
