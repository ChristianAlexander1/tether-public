# External Framework Inputs

The following signed arm64 device and arm64 simulator xcframeworks are required for a release build and are intentionally not fabricated in this source archive:

| Framework | Purpose | Required source |
|---|---|---|
| TermXCoreNative | In-process native command engine and C API | TermXCore implementation |
| TermXPython | Embedded Python interpreter (CPython/BeeWare) | `Packages/TermXPython/Scripts/build-termx-python-xcframework.sh` |
| NodeMobile | Embedded Node.js runtime | Run `Frameworks/build-nodejs-mobile.sh` (fetches digidem nodejs-mobile v24.19.0-1 **full** xcframework) |
| Blink | Interpreted Linux-compatible guest | ISC-licensed Blink build |

Verify every binary’s architecture, code signature, and license notice before adding it to the Xcode target. Do not use `dlopen` on downloaded libraries or execute downloaded native code.
