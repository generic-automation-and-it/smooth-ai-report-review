# NFR-03: Runtime Determinism

**Status:** Accepted

## Requirement

The same OpenCode pin yields a v2 runtime on every runner. A v1 binary is rejected whether it is
cached or found earlier on PATH. A managed config that is not confirmed loaded stops the run before
any model call. Requested model IDs are registered without mutating existing entries.

## Verification

Exercise cached-v1, PATH-shadowed-v1, successful-v2, foreign-config-binding, unreadable-binding and
missing-model-key cases. Assert the exit status and that the resolved config differs only by the
added keys.

## Acceptance Criteria

- v1 is rejected in every path.
- A foreign or unreadable binding exits with the fatal status.
- Registration adds only absent keys and preserves existing metadata and placeholders.

## Applies To

Goal 4; the toolchain install, config preparation and health flow.
