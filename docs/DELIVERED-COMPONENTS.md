# Delivered component ownership

| Component | Location | Product relationship |
|---|---|---|
| TetherCommands | `External/TetherCommands` | runtime dependency of TermXCore |
| TetherShellLang | `External/TetherShellLang` | parser/evaluator conformance dependency |
| tether-shim-v2 | `External/tether-shim-v2` | source-of-truth TJIP/2 suite; product copy in TermXNode |
| TetherFakefs | `Vendor/TetherFakefs` | validated storage library; awaits writable overlay |
| TetherNativeOffload | `Vendor/TetherNativeOffload` | validated reference registry; production uses manifest bridge |
| TetherWasm | `External/TetherWasm` | app runtime dependency |
| Linux harness | `Vendor/tether-linux-harness` | real guest behavior acceptance suite |
| TetherRiscv | `Vendor/TetherRiscv` | alternate-engine evidence/report |
| TetherTerminal | `External/TetherTerminal` | terminal conformance dependency |
| spawn fixtures | `External/tether-spawn-fixtures` | generic Node spawn protocol suite |
| Native tools | `Vendor/TetherNativeTools` | real upstream iOS build scripts |

Every directory is validated in place. Generated `.build`, `.swiftpm`, `.host`,
and transfer archive directories are not source and should not be committed.
