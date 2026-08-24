# Build and run Tether

## Prerequisites

- macOS with the selected Xcode toolchain
- `xcodegen`, Swift Package Manager, CMake, Node and npm
- Homebrew `libarchive` + `pkg-config` for the fakefs creation tests
- local `Frameworks/Blink.xcframework`, `NodeMobile.xcframework`, and
  `TermXPython.xcframework` (build scripts are in `Frameworks/`)

## Automated gates

From the repository root:

```sh
./scripts/validate.sh --quick    # packages, JS, C libraries, WASI, scripts
./scripts/validate.sh --network  # real Blink + Alpine download/apk acceptance
./scripts/validate.sh --ios      # regenerate and build for iOS Simulator
./scripts/validate.sh --all      # all three gates
```

`--network` intentionally downloads an Alpine minirootfs and packages. It is
separate from the deterministic quick gate.

## Simulator

```sh
xcodegen generate
xcodebuild -project Tether.xcodeproj -scheme Tether \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build
```

Boot the named simulator, install the built `Tether.app`, and launch
`com.tether.app`. `xcrun simctl get_app_container` locates the current sandbox;
do not persist an old application-container UUID.

Useful DEBUG launch variables use the `TETHER_` prefix:

- `TETHER_AUTOWORKSPACE=1`
- `TETHER_AUTOCOMMANDS='command1\ncommand2\n'`
- `TETHER_AUTOCOMMAND_FILE=/absolute/path/to/commands.sh`
- `TETHER_PTY_LOG=/absolute/path/to/output.log`
- `TETHER_HOST_SHELL=1` selects the host shell for debugging; Alpine is the
  default product path.

The app still reads the corresponding legacy `TERMX_` variables so existing
automation is not broken, but new automation should use `TETHER_`.

## Linux smoke sequence

Run these in one Tether terminal session:

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

The expected behavior is standard Linux behavior: `apk` installs real Alpine
packages, pipelines and signals stay inside the guest, and only manifest-listed
runtime launchers plus desktop opener commands cross to host services.

For an arbitrary WASI module copied into the selected workspace:

```sh
wasm module.wasm arg1 arg2
```

## Physical device

Use a development signing team, select an iPhone/iPad destination, and build the
same `Tether` scheme. Complete [docs/DEVICE-PASS.md](docs/DEVICE-PASS.md) before
release; account-backed OAuth cannot be certified by simulator-only automation.
