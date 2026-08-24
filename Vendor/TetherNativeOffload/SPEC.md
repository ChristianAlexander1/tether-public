# Tether Native Offload Registry Specification

## 1. Scope

This component maps a guest program request to a host-provided C callback. It is
an isolated registry: it does not parse a manifest, launch processes, or depend
on application/platform code.

## 2. Rule types

- **Guest-path rule:** an exact, case-sensitive match of the complete `prog`
  string. Its selector must be non-empty and contain `/`.
- **Basename rule:** a case-sensitive match of the last component of `prog`.
  Its selector must be non-empty and contain no `/`.

For example, the basename rule `node` matches `node`, `/usr/bin/node`, and
`./node`. It does not match `nodejs`. A trailing slash has an empty final
component and therefore cannot match a basename rule.

If both kinds match, the exact guest-path rule wins. Duplicate registration of
the same selector and kind atomically replaces its callback and context.

## 3. Ownership and lifetime

The registry copies selector strings. The callback and opaque context pointer
are borrowed. The integrator must keep callback code and context data valid
until the rule is replaced, unregistered, or the registry is cleared. A
callback is invoked without the registry lock held.

`argv`, `envp`, and the file descriptors passed to a callback are borrowed for
the callback's duration. The library does not close descriptors or modify
arrays.

## 4. API behavior

Registration returns `TETHER_OFFLOAD_OK`, `TETHER_OFFLOAD_EINVAL`, or
`TETHER_OFFLOAD_ENOMEM`. A callback must be non-null.

`tether_offload_resolve()` returns the callback or null. Because the minimum
three-function API cannot return `ctx`, integrations that invoke callbacks
should use `tether_offload_resolve_entry()` or `tether_offload_execute()`.

`tether_offload_resolve_entry()` clears its output before lookup and returns
`TETHER_OFFLOAD_ENOENT` when no rule matches. `tether_offload_execute()` returns
a lookup error or the callback's return value unchanged.

The registry is process-global and its operations are thread-safe. Resolution
copies callback/context under the lock; callback execution occurs after the
lock is released. Concurrent removal does not manage the lifetime of borrowed
context, so the embedding application must coordinate context destruction.

## 5. Manifest format

The manifest is UTF-8 JSON with one top-level member:

```json
{
  "offloads": [
    {"guest": "/usr/bin/node", "host": "node-mobile"},
    {"guest": "claude", "basename": true}
  ]
}
```

Each `offloads` element is an object:

| Field | Type | Required | Meaning |
|---|---|---:|---|
| `guest` | string | yes | Guest selector. Non-empty. |
| `host` | string | no | Host handler/program identifier interpreted by the embedding application. If omitted, it defaults to `guest`. |
| `basename` | boolean | no | If `true`, register a basename rule. Defaults to `false` (exact guest path). |

For `basename: true`, `guest` must contain no `/`. Otherwise `guest` must contain
`/`. Unknown fields should be rejected by strict consumers. Duplicate entries
are applied in document order, so the last duplicate wins. The C library does
not parse JSON or interpret `host`; a host integration validates this document,
selects a callback/context for each `host`, and calls the corresponding
registration function.

## 6. Portability

The implementation uses ISO C11, including `<stdatomic.h>`, and the C standard
library. It has no POSIX runtime dependency and is intended for Linux and macOS
hosts.
