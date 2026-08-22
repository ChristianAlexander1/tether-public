# Implementation notes

The implementation preserves the frozen APIs rather than inventing component-specific interfaces. `WorkspaceStore` is the central virtual-to-real path resolver and balances security-scoped access counts. `CoreTerminalEngine` is the Swift boundary for the C engine. Runtime and Linux implementations are intentionally isolated so their native backends can be linked without changing the app-facing contracts.

The C implementation is portable on POSIX systems and supports asynchronous spawn, wait, signal, environment passing, working-directory selection, and descriptor wiring. It uses `/bin/sh -lc` as the host shell in the test harness; the iOS target must replace that backend with the in-process shell/ios_system dispatcher described in the master plan.
