# TetherCommands P1 handoff

## Final requirement audit

| Requirement | Status | Verification |
|---|---|---|
| Isolated Swift package only; no app/iOS code | Implemented | Archive contains only `TetherCommands/` package sources, tests, license, and handoff |
| Tether naming everywhere | Implemented | Package/product/target/folders/types use `Tether`; case-insensitive former-name scan returns zero matches |
| Exact package name and layout | Implemented | `Package.swift` is named `TetherCommands`; sources and tests are in the requested target folders |
| Exact public command interface | Implemented | `CommandIO`, `CommandResult: Equatable`, `TetherCommand`, and `TetherCommandRegistry` are declared in `CommandIO.swift`/`Registry.swift` |
| In-process execution only | Implemented | No `Process`, `fork`, `exec`, `posix_spawn`, or `system` calls; nested execution dispatches through `TetherCommandRegistry` |
| 40+ commands | Implemented | 41 command implementations in 41 command files and 41 registry entries |
| All 38 named commands | Implemented | Automated registry/source audit found no missing named command |
| Man-page/coreutils-style behavior | Implemented | Options and behavior are summarized below; final audit added validation and edge-case handling for empty fields, binary split/dump, negative sequences, effective identity, recursive `du`, directory link targets, and generic timeout deadlines |
| At least 80 tests, at least two per command, plus integration | Implemented | 100 XCTest cases; original suite has two per each of 41 commands plus integration, with 14 final-audit regression tests |
| T1 `cut -d: -f1` | Implemented/tested | `testCutFieldT1` expects `a\n` |
| T2 `tr a-z A-Z` | Implemented/tested | `testTrRangesT2` expects `HI` |
| T3 `test -f missing` | Implemented/tested | `testFileMissingT3` expects exit 1 |
| T4 `sort -r` | Implemented/tested | `testSortReverseT4` checks reversed lines |
| T5 `basename /a/b/c` | Implemented/tested | `testBasenameT5` expects `c\n` |
| Real temporary directories | Implemented | Filesystem tests create UUID-named directories under `FileManager.default.temporaryDirectory` and remove them in teardown |
| Error handling and usage status | Implemented | Commands return structured stdout/stderr/status; invalid options/operands are covered throughout the suite |
| MIT license | Implemented | `LICENSE` contains the MIT License |
| `swift test` all green | Implemented | Clean build executed 100 tests with zero failures; full output is included below |
| Handoff command table and full test output | Implemented | Included in this document |
| Zip name | Implemented | Delivered as `TetherCommands-P1.zip` |

The clean test and release build were run on Linux with Swift 6.0.3 in Swift 5 language mode (`swift-tools-version: 5.9`). The package declares macOS 12 support and has Darwin-specific conditional imports, but a macOS runner is not available in this environment.

## Command table

| Command | Main implemented behavior/options |
|---|---|
| `xargs` | Shell-like stdin word parsing; validated `-n`, `-I`, `-r`; invokes registered commands in-process |
| `tee` | Copy stdin to stdout/files; `-a` |
| `cut` | Delimited fields and character positions; `-d`, `-f`, `-c`, `-s`; lists and bounded/unbounded ranges |
| `tr` | Character/range translation; deletion and standalone/translated squeezing with `-d`, `-s` |
| `uniq` | Adjacent duplicate filtering; `-c`, `-d`, `-u`, `-i` |
| `sort` | Lexical/numeric sorting; `-r`, `-n`, `-u`, `-f`; files or stdin |
| `which` | PATH executable-file lookup; `-a`; excludes directories |
| `type` | Registry and PATH command classification |
| `test` | String, integer, file, symlink, negation, parentheses, AND/OR predicates, and `[` argv form |
| `env` | Ordered `-i`, `-u`, `--unset`, assignments, sorted display, and in-process command invocation |
| `printenv` | Full environment or selected variable values |
| `id` | UID/GID identity; `-u`, `-g`, `-un`, `-gn` |
| `whoami` | Effective username lookup independent of spoofable environment variables |
| `uname` | Native `uname(2)` data; `-s`, `-n`, `-r`, `-v`, `-m`, `-p`, `-i`, `-o`, `-a` |
| `date` | Current/epoch date; `-u`, `-r`, `TZ`, common `+FORMAT` directives and literal-safe rendering |
| `split` | Binary-safe line/byte chunks; `-l`, `-b`, `-a`, `-d`; suffix exhaustion checks |
| `paste` | Parallel/serial line merge; `-d`, `-s` |
| `join` | Join two files by fields; `-1`, `-2`, `-t` |
| `od` | Binary-safe multi-file octal, hex, or character dump; `-A`/`-An`, `-x`, `-c`, `-b`, `-t` |
| `strings` | Printable-run extraction from stdin or binary files; `-n`, `-NUMBER` |
| `file` | Directory, symlink, empty, ELF, PNG, UTF-8, and generic data identification; `-b` |
| `stat` | Size/type/mode/time output; `-c`/`-f` format with `%n`, `%s`, `%F`, `%A`, `%Y` |
| `readlink` | Link target; `-f`/`-e`, `-n` |
| `realpath` | Canonical paths; `-m` |
| `basename` | Final component; suffix operand and `-s` |
| `dirname` | Parent component for one or more operands |
| `mktemp` | Randomized file/directory creation; `-d`, `-q`, `-p` |
| `ln` | Hard and symbolic links; `-s`, `-f`; directory targets use source basename |
| `du` | Recursive directory rows or `-s` summary; `-h`, `-b`, `-k` |
| `sleep` | Fractional durations and `s`/`m`/`h`/`d` suffixes with finite-value validation |
| `timeout` | In-process registry command deadline; cooperative `sleep` timeout and generic asynchronous deadline; exit 124 |
| `yes` | Repeated line output with finite-result control; validated `-n COUNT`, `TETHER_MAX_OUTPUT_LINES` |
| `seq` | One-, two-, and three-operand ascending/descending sequences, including negative operands; `-s`, `-w`, `-f` |
| `expr` | Integer arithmetic, precedence, parentheses, and comparisons |
| `printf` | Repeated format use; strings, characters, integers, floats, `%b`, and escapes |
| `echo` | `-n`, `-e`, `-E` |
| `true` | Exit 0 |
| `false` | Exit 1 |
| `pwd` | Logical/physical cwd; `-L`, `-P` |
| `cat` | Stdin/files and `-n` line numbering |
| `wc` | Lines, words, bytes, characters; `-l`, `-w`, `-c`, `-m`; read failures go to stderr |

`pwd`, `cat`, and `wc` are the three commands beyond the 38 explicitly listed in the brief, bringing the total to 41.

## Finite-result and in-process constraints

`xargs`, `env`, and `timeout` dispatch only commands in `TetherCommandRegistry`; they never launch an OS executable. `timeout` returns at its deadline; an arbitrary synchronous implementation has no safe force-cancellation primitive in the required protocol, although `sleep` is handled cooperatively to avoid a lingering sleeper. Because the required return type stores stdout as a finite `String`, an actually infinite `yes` result cannot be represented: it defaults to 1,000 lines and supports explicit control through `-n COUNT` or `TETHER_MAX_OUTPUT_LINES`.

## Full clean `swift test` output

```text
Building for debugging...
[0/13] Write sources
[2/13] Write swift-version--413BBEA0737331CC.txt
[4/36] Emitting module TetherCommands
[5/58] Compiling TetherCommands BasenameCommand.swift
[6/58] Compiling TetherCommands CatCommand.swift
[7/58] Compiling TetherCommands CommandIO.swift
[8/58] Compiling TetherCommands CutCommand.swift
[9/58] Compiling TetherCommands DateCommand.swift
[10/58] Compiling TetherCommands DirnameCommand.swift
[11/58] Compiling TetherCommands DuCommand.swift
[12/58] Compiling TetherCommands EchoCommand.swift
[13/58] Compiling TetherCommands EnvCommand.swift
[14/58] Compiling TetherCommands ExprCommand.swift
[15/58] Compiling TetherCommands FalseCommand.swift
[16/58] Compiling TetherCommands FileCommand.swift
[17/58] Compiling TetherCommands IdCommand.swift
[18/58] Compiling TetherCommands JoinCommand.swift
[19/58] Compiling TetherCommands LnCommand.swift
[20/58] Compiling TetherCommands MktempCommand.swift
[21/58] Compiling TetherCommands OdCommand.swift
[22/58] Compiling TetherCommands PasteCommand.swift
[23/58] Compiling TetherCommands PrintenvCommand.swift
[24/58] Compiling TetherCommands PrintfCommand.swift
[25/58] Compiling TetherCommands PwdCommand.swift
[26/58] Compiling TetherCommands ReadlinkCommand.swift
[27/58] Compiling TetherCommands RealpathCommand.swift
[28/58] Compiling TetherCommands Registry.swift
[29/58] Compiling TetherCommands SeqCommand.swift
[30/58] Compiling TetherCommands SleepCommand.swift
[31/58] Compiling TetherCommands SortCommand.swift
[32/58] Compiling TetherCommands SplitCommand.swift
[33/58] Compiling TetherCommands StatCommand.swift
[34/58] Compiling TetherCommands StringsCommand.swift
[35/58] Compiling TetherCommands TeeCommand.swift
[36/58] Compiling TetherCommands TestCommand.swift
[37/58] Compiling TetherCommands TimeoutCommand.swift
[38/58] Compiling TetherCommands TrCommand.swift
[39/58] Compiling TetherCommands TrueCommand.swift
[40/58] Compiling TetherCommands TypeCommand.swift
[41/58] Compiling TetherCommands UnameCommand.swift
[42/58] Compiling TetherCommands UniqCommand.swift
[43/58] Compiling TetherCommands Utilities.swift
[44/58] Compiling TetherCommands WcCommand.swift
[45/58] Compiling TetherCommands WhichCommand.swift
[46/58] Compiling TetherCommands WhoamiCommand.swift
[47/58] Compiling TetherCommands XargsCommand.swift
[48/58] Compiling TetherCommands YesCommand.swift
[49/59] Wrapping AST for TetherCommands for debugging
[51/61] Emitting module TetherCommandsTests
[52/61] Compiling TetherCommandsTests TetherCommandsTests.swift
[53/62] /home/user/TetherCommands/.build/x86_64-pc-linux-gnu/debug/TetherCommandsPackageDiscoveredTests.derived/all-discovered-tests.swift
[54/62] Write sources
[55/62] Wrapping AST for TetherCommandsTests for debugging
[57/64] Emitting module TetherCommandsPackageDiscoveredTests
[58/64] Compiling TetherCommandsPackageDiscoveredTests TetherCommandsTests.swift
[59/65] Compiling TetherCommandsPackageDiscoveredTests all-discovered-tests.swift
[60/66] /home/user/TetherCommands/.build/x86_64-pc-linux-gnu/debug/TetherCommandsPackageTests.derived/runner.swift
[61/66] Write sources
[62/66] Wrapping AST for TetherCommandsPackageDiscoveredTests for debugging
[64/68] Compiling TetherCommandsPackageTests runner.swift
[65/68] Emitting module TetherCommandsPackageTests
[66/69] Wrapping AST for TetherCommandsPackageTests for debugging
[67/69] Write Objects.LinkFileList
[68/69] Linking TetherCommandsPackageTests.xctest
Build complete! (13.37s)
Test Suite 'All tests' started at 2026-08-24 02:57:12.948
Test Suite 'debug.xctest' started at 2026-08-24 02:57:12.949
Test Suite 'TetherCommandsTests' started at 2026-08-24 02:57:12.949
Test Case 'TetherCommandsTests.testAuditBracketTestInvocation' started at 2026-08-24 02:57:12.949
Test Case 'TetherCommandsTests.testAuditBracketTestInvocation' passed (0.002 seconds)
Test Case 'TetherCommandsTests.testAuditCutPreservesSelectedEmptyField' started at 2026-08-24 02:57:12.951
Test Case 'TetherCommandsTests.testAuditCutPreservesSelectedEmptyField' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testAuditDatePreservesLiteralText' started at 2026-08-24 02:57:12.952
Test Case 'TetherCommandsTests.testAuditDatePreservesLiteralText' passed (0.004 seconds)
Test Case 'TetherCommandsTests.testAuditDuSummarizeSuppressesChildRows' started at 2026-08-24 02:57:12.956
Test Case 'TetherCommandsTests.testAuditDuSummarizeSuppressesChildRows' passed (0.004 seconds)
Test Case 'TetherCommandsTests.testAuditEnvAcceptsOptionsInSequence' started at 2026-08-24 02:57:12.960
Test Case 'TetherCommandsTests.testAuditEnvAcceptsOptionsInSequence' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testAuditLnUsesBasenameInsideTargetDirectory' started at 2026-08-24 02:57:12.960
Test Case 'TetherCommandsTests.testAuditLnUsesBasenameInsideTargetDirectory' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testAuditOdReadsBinaryFiles' started at 2026-08-24 02:57:12.961
Test Case 'TetherCommandsTests.testAuditOdReadsBinaryFiles' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testAuditSeqAcceptsNegativeFirstOperand' started at 2026-08-24 02:57:12.962
Test Case 'TetherCommandsTests.testAuditSeqAcceptsNegativeFirstOperand' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testAuditSplitPreservesBinaryFileBytes' started at 2026-08-24 02:57:12.963
Test Case 'TetherCommandsTests.testAuditSplitPreservesBinaryFileBytes' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testAuditTrSqueezesWithoutTranslation' started at 2026-08-24 02:57:12.964
Test Case 'TetherCommandsTests.testAuditTrSqueezesWithoutTranslation' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testAuditWcReportsReadErrorsOnStderr' started at 2026-08-24 02:57:12.964
Test Case 'TetherCommandsTests.testAuditWcReportsReadErrorsOnStderr' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testAuditWhichRejectsDirectories' started at 2026-08-24 02:57:12.965
Test Case 'TetherCommandsTests.testAuditWhichRejectsDirectories' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testAuditXargsRejectsZeroGroupSize' started at 2026-08-24 02:57:12.966
Test Case 'TetherCommandsTests.testAuditXargsRejectsZeroGroupSize' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testAuditYesRejectsInvalidCount' started at 2026-08-24 02:57:12.966
Test Case 'TetherCommandsTests.testAuditYesRejectsInvalidCount' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testBasenameSuffix' started at 2026-08-24 02:57:12.966
Test Case 'TetherCommandsTests.testBasenameSuffix' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testBasenameT5' started at 2026-08-24 02:57:12.967
Test Case 'TetherCommandsTests.testBasenameT5' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testCatFile' started at 2026-08-24 02:57:12.967
Test Case 'TetherCommandsTests.testCatFile' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testCatStandardInput' started at 2026-08-24 02:57:12.967
Test Case 'TetherCommandsTests.testCatStandardInput' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testCutCharacters' started at 2026-08-24 02:57:12.968
Test Case 'TetherCommandsTests.testCutCharacters' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testCutFieldT1' started at 2026-08-24 02:57:12.968
Test Case 'TetherCommandsTests.testCutFieldT1' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testDateCustomFormat' started at 2026-08-24 02:57:12.969
Test Case 'TetherCommandsTests.testDateCustomFormat' passed (0.003 seconds)
Test Case 'TetherCommandsTests.testDateEpochYearUTC' started at 2026-08-24 02:57:12.971
Test Case 'TetherCommandsTests.testDateEpochYearUTC' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testDirnameBareName' started at 2026-08-24 02:57:12.973
Test Case 'TetherCommandsTests.testDirnameBareName' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testDirnamePath' started at 2026-08-24 02:57:12.973
Test Case 'TetherCommandsTests.testDirnamePath' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testDuBytes' started at 2026-08-24 02:57:12.973
Test Case 'TetherCommandsTests.testDuBytes' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testDuMissing' started at 2026-08-24 02:57:12.973
Test Case 'TetherCommandsTests.testDuMissing' passed (0.101 seconds)
Test Case 'TetherCommandsTests.testEchoNoNewline' started at 2026-08-24 02:57:13.075
Test Case 'TetherCommandsTests.testEchoNoNewline' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testEchoWords' started at 2026-08-24 02:57:13.075
Test Case 'TetherCommandsTests.testEchoWords' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testEnvEmpty' started at 2026-08-24 02:57:13.075
Test Case 'TetherCommandsTests.testEnvEmpty' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testEnvSetsForCommand' started at 2026-08-24 02:57:13.075
Test Case 'TetherCommandsTests.testEnvSetsForCommand' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testExprAdds' started at 2026-08-24 02:57:13.075
Test Case 'TetherCommandsTests.testExprAdds' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testExprPrecedence' started at 2026-08-24 02:57:13.076
Test Case 'TetherCommandsTests.testExprPrecedence' passed (0.1 seconds)
Test Case 'TetherCommandsTests.testFalseFailure' started at 2026-08-24 02:57:13.176
Test Case 'TetherCommandsTests.testFalseFailure' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testFalseIgnoresOperands' started at 2026-08-24 02:57:13.176
Test Case 'TetherCommandsTests.testFalseIgnoresOperands' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testFileDirectory' started at 2026-08-24 02:57:13.177
Test Case 'TetherCommandsTests.testFileDirectory' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testFileMissingT3' started at 2026-08-24 02:57:13.177
Test Case 'TetherCommandsTests.testFileMissingT3' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testFileUTF8Text' started at 2026-08-24 02:57:13.178
Test Case 'TetherCommandsTests.testFileUTF8Text' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testIdDefault' started at 2026-08-24 02:57:13.179
Test Case 'TetherCommandsTests.testIdDefault' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testIdUserNumber' started at 2026-08-24 02:57:13.179
Test Case 'TetherCommandsTests.testIdUserNumber' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testIntegerComparison' started at 2026-08-24 02:57:13.179
Test Case 'TetherCommandsTests.testIntegerComparison' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testIntegrationCutThenTranslate' started at 2026-08-24 02:57:13.180
Test Case 'TetherCommandsTests.testIntegrationCutThenTranslate' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testIntegrationEnvInvokesPrintenv' started at 2026-08-24 02:57:13.181
Test Case 'TetherCommandsTests.testIntegrationEnvInvokesPrintenv' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testIntegrationRegistryHasFortyPlusCommands' started at 2026-08-24 02:57:13.181
Test Case 'TetherCommandsTests.testIntegrationRegistryHasFortyPlusCommands' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testIntegrationXargsInvokesPrintf' started at 2026-08-24 02:57:13.181
Test Case 'TetherCommandsTests.testIntegrationXargsInvokesPrintf' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testJoinCustomSeparator' started at 2026-08-24 02:57:13.182
Test Case 'TetherCommandsTests.testJoinCustomSeparator' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testJoinDefaultField' started at 2026-08-24 02:57:13.182
Test Case 'TetherCommandsTests.testJoinDefaultField' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testLnHardLink' started at 2026-08-24 02:57:13.183
Test Case 'TetherCommandsTests.testLnHardLink' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testLnSymbolicLink' started at 2026-08-24 02:57:13.183
Test Case 'TetherCommandsTests.testLnSymbolicLink' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testMktempDirectory' started at 2026-08-24 02:57:13.184
Test Case 'TetherCommandsTests.testMktempDirectory' passed (0.103 seconds)
Test Case 'TetherCommandsTests.testMktempFile' started at 2026-08-24 02:57:13.286
Test Case 'TetherCommandsTests.testMktempFile' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testOdHex' started at 2026-08-24 02:57:13.287
Test Case 'TetherCommandsTests.testOdHex' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testOdOctal' started at 2026-08-24 02:57:13.288
Test Case 'TetherCommandsTests.testOdOctal' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPasteColumns' started at 2026-08-24 02:57:13.288
Test Case 'TetherCommandsTests.testPasteColumns' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testPasteSerial' started at 2026-08-24 02:57:13.289
Test Case 'TetherCommandsTests.testPasteSerial' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPrintenvMissing' started at 2026-08-24 02:57:13.289
Test Case 'TetherCommandsTests.testPrintenvMissing' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPrintenvValue' started at 2026-08-24 02:57:13.289
Test Case 'TetherCommandsTests.testPrintenvValue' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPrintfRepeatsFormat' started at 2026-08-24 02:57:13.289
Test Case 'TetherCommandsTests.testPrintfRepeatsFormat' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPrintfStringAndInteger' started at 2026-08-24 02:57:13.290
Test Case 'TetherCommandsTests.testPrintfStringAndInteger' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPwdInvalidOption' started at 2026-08-24 02:57:13.290
Test Case 'TetherCommandsTests.testPwdInvalidOption' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testPwdLogical' started at 2026-08-24 02:57:13.290
Test Case 'TetherCommandsTests.testPwdLogical' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testReadlinkNotLink' started at 2026-08-24 02:57:13.291
Test Case 'TetherCommandsTests.testReadlinkNotLink' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testReadlinkTarget' started at 2026-08-24 02:57:13.291
Test Case 'TetherCommandsTests.testReadlinkTarget' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testRealpathExisting' started at 2026-08-24 02:57:13.291
Test Case 'TetherCommandsTests.testRealpathExisting' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testRealpathMissingAllowed' started at 2026-08-24 02:57:13.292
Test Case 'TetherCommandsTests.testRealpathMissingAllowed' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSeqDescending' started at 2026-08-24 02:57:13.292
Test Case 'TetherCommandsTests.testSeqDescending' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSeqSimple' started at 2026-08-24 02:57:13.293
Test Case 'TetherCommandsTests.testSeqSimple' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSleepInvalid' started at 2026-08-24 02:57:13.293
Test Case 'TetherCommandsTests.testSleepInvalid' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSleepZero' started at 2026-08-24 02:57:13.293
Test Case 'TetherCommandsTests.testSleepZero' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSortNumeric' started at 2026-08-24 02:57:13.293
Test Case 'TetherCommandsTests.testSortNumeric' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSortReverseT4' started at 2026-08-24 02:57:13.293
Test Case 'TetherCommandsTests.testSortReverseT4' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSplitBytes' started at 2026-08-24 02:57:13.294
Test Case 'TetherCommandsTests.testSplitBytes' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testSplitLines' started at 2026-08-24 02:57:13.294
Test Case 'TetherCommandsTests.testSplitLines' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testStatMissing' started at 2026-08-24 02:57:13.294
Test Case 'TetherCommandsTests.testStatMissing' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testStatSizeFormat' started at 2026-08-24 02:57:13.295
Test Case 'TetherCommandsTests.testStatSizeFormat' passed (0.001 seconds)
Test Case 'TetherCommandsTests.testStringsExtractsPrintableRuns' started at 2026-08-24 02:57:13.296
Test Case 'TetherCommandsTests.testStringsExtractsPrintableRuns' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testStringsMinimumLength' started at 2026-08-24 02:57:13.296
Test Case 'TetherCommandsTests.testStringsMinimumLength' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTeeAppends' started at 2026-08-24 02:57:13.296
Test Case 'TetherCommandsTests.testTeeAppends' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTeeCopiesStandardInput' started at 2026-08-24 02:57:13.296
Test Case 'TetherCommandsTests.testTeeCopiesStandardInput' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTimeoutSleep' started at 2026-08-24 02:57:13.297
Test Case 'TetherCommandsTests.testTimeoutSleep' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTimeoutTrue' started at 2026-08-24 02:57:13.297
Test Case 'TetherCommandsTests.testTimeoutTrue' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTrDeletes' started at 2026-08-24 02:57:13.298
Test Case 'TetherCommandsTests.testTrDeletes' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTrRangesT2' started at 2026-08-24 02:57:13.298
Test Case 'TetherCommandsTests.testTrRangesT2' passed (0.101 seconds)
Test Case 'TetherCommandsTests.testTrueIgnoresOperands' started at 2026-08-24 02:57:13.399
Test Case 'TetherCommandsTests.testTrueIgnoresOperands' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTrueSuccess' started at 2026-08-24 02:57:13.399
Test Case 'TetherCommandsTests.testTrueSuccess' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTypeKnowsBuiltin' started at 2026-08-24 02:57:13.399
Test Case 'TetherCommandsTests.testTypeKnowsBuiltin' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testTypeMissing' started at 2026-08-24 02:57:13.400
Test Case 'TetherCommandsTests.testTypeMissing' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testUnameMachine' started at 2026-08-24 02:57:13.400
Test Case 'TetherCommandsTests.testUnameMachine' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testUnameSystem' started at 2026-08-24 02:57:13.400
Test Case 'TetherCommandsTests.testUnameSystem' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testUniqAdjacentLines' started at 2026-08-24 02:57:13.400
Test Case 'TetherCommandsTests.testUniqAdjacentLines' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testUniqCounts' started at 2026-08-24 02:57:13.401
Test Case 'TetherCommandsTests.testUniqCounts' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testWcLines' started at 2026-08-24 02:57:13.401
Test Case 'TetherCommandsTests.testWcLines' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testWcWords' started at 2026-08-24 02:57:13.401
Test Case 'TetherCommandsTests.testWcWords' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testWhichFindsExecutable' started at 2026-08-24 02:57:13.401
Test Case 'TetherCommandsTests.testWhichFindsExecutable' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testWhichMissing' started at 2026-08-24 02:57:13.402
Test Case 'TetherCommandsTests.testWhichMissing' passed (0.101 seconds)
Test Case 'TetherCommandsTests.testWhoamiIgnoresSpoofedEnvironment' started at 2026-08-24 02:57:13.502
Test Case 'TetherCommandsTests.testWhoamiIgnoresSpoofedEnvironment' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testWhoamiSystemLookup' started at 2026-08-24 02:57:13.503
Test Case 'TetherCommandsTests.testWhoamiSystemLookup' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testXargsEchoesWords' started at 2026-08-24 02:57:13.503
Test Case 'TetherCommandsTests.testXargsEchoesWords' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testXargsMaxArguments' started at 2026-08-24 02:57:13.503
Test Case 'TetherCommandsTests.testXargsMaxArguments' passed (0.0 seconds)
Test Case 'TetherCommandsTests.testYesCount' started at 2026-08-24 02:57:13.504
Test Case 'TetherCommandsTests.testYesCount' passed (0.101 seconds)
Test Case 'TetherCommandsTests.testYesDefaultWord' started at 2026-08-24 02:57:13.604
Test Case 'TetherCommandsTests.testYesDefaultWord' passed (0.0 seconds)
Test Suite 'TetherCommandsTests' passed at 2026-08-24 02:57:13.605
	 Executed 100 tests, with 0 failures (0 unexpected) in 0.653 (0.653) seconds
Test Suite 'debug.xctest' passed at 2026-08-24 02:57:13.605
	 Executed 100 tests, with 0 failures (0 unexpected) in 0.653 (0.653) seconds
Test Suite 'All tests' passed at 2026-08-24 02:57:13.605
	 Executed 100 tests, with 0 failures (0 unexpected) in 0.653 (0.653) seconds
◇ Test run started.
↳ Testing Library Version: 6.0.3
✔ Test run with 0 tests passed after 0.001 seconds.
```
