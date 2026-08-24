# Guest platform contract

Every program installed with `apk` receives the same platform. Fixes belong in
the filesystem, syscall, PTY, networking, mount or dispatch layer—not in a list
of application names.

## Guaranteed routing rules

1. Guest ELF is the default for `execve`.
2. Only manifest-listed packaged runtimes cross the host runtime boundary.
3. Common desktop opener commands share one resolver for HTTP(S) URLs and
   workspace paths.
4. `/work` is the selected host workspace; mappings outside approved roots are
   rejected.
5. Ctrl-C for ordinary Linux work is delivered to the guest. Embedded runtime
   cancellation does not tear down the entire Blink session.
6. Linux identity and utility output are not rewritten to look like Tether.

## Guest environment

Tether supplies standard session configuration: `PATH`, `HOME`, `USER`,
`LOGNAME`, `SHELL`, `TMPDIR`, `TERM`, `LANG`, `PWD`, `DISPLAY`,
`WAYLAND_DISPLAY`, and `BROWSER`. It does not set Git author/committer identity,
editors, email, CPU counts, kernel versions or hostname output.

## Browser behavior

`open`, `xdg-open`, `gnome-open`, `kde-open`, `sensible-browser`, `wslview`,
and `gio open` are platform services. Resolution depends on the command shape,
not the requesting application or URL host. OAuth classification affects
presentation metadata only; it does not create a separate execution route.

## Diagnostics

When a guest package fails:

| Symptom | Correct layer |
|---|---|
| download/index failure | DNS, socket, TLS, CA or apk filesystem behavior |
| executable not found | guest package, PATH or rootfs |
| syscall error | Blink syscall/VFS implementation |
| terminal corruption | PTY transport or terminal renderer |
| Node child failure | generic child-process executor |
| browser failure | opener environment, resolver or iOS presentation |

Do not add the failing package name to host dispatch.
