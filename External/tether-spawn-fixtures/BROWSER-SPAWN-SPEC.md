# Browser spawn specification

This fixture pack models the Linux CLI decision point before `@tether/shim` P3 receives a spawn request.

* Without `DISPLAY` and `WAYLAND_DISPLAY`, an opener may not spawn. The expected result is **no spawn** (or an explicitly documented CLI fallback such as a printed URL).
* With `DISPLAY=:0` (or a usable `WAYLAND_DISPLAY`), the CLI must spawn `$BROWSER` when it is set. Otherwise it may use `xdg-open`; `sensible-browser` is also represented as a fallback fixture.
* The URL must be a complete `https` URL whose path begins `https://claude.com/cai/oauth/authorize`. Do not send a host-relative or shortened URL.
* The P3 request is `{kind:"spawn",file:"...",args:[...],cwd:"/work",env:{...},interactive:false}`. Environment values are preserved; this pack uses `WAYLAND_DISPLAY=tether` for Tether.

These are request-shape fixtures, not actual browser launches.
