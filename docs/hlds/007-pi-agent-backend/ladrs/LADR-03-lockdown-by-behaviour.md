# LADR-03: Tool Lockdown Is a Role Contract Proven by Behaviour

**Status:** Draft

## Context

- The reviewer must be read-only with no shell and no network.
- The fixer must be edit-only, with tooling, context, temp, VCS and credential paths denied.
- One backend expresses this as a declarative permission matrix. The second has no permission
  language: its tool set is an allow-list, and per-call policy exists only through an in-process
  extension hook.
- A configuration format shared across backends would either be ignored or silently weaken one side.

## Decision

**Define lockdown as a behaviour contract per role** — which tool classes exist, which paths are
writable — and implement it with each backend's native mechanism. Parity is judged by negative tests
that attempt a denied action and observe it blocked, never by comparing configuration files.

Where a backend can only enforce a policy through executable extension code, that code is treated as
a pinned, verified part of the toolchain, not as model-editable content.

## Consequences

- Neither backend is forced into a foreign configuration format.
- One behavioural definition can be tested identically on both runtimes.
- Two implementations must be kept aligned; drift is a real maintenance cost.
- The extension-based side adds an executable component inside the model process, so it must be
  pinned and verified like any other tool.

## Open

- Whether read-path denial (credential and VCS paths) is required for the reviewer on both backends
  is a security decision pending review of current OpenCode behaviour.

## Related

- **LADR-04** — where policy configuration is sourced.
