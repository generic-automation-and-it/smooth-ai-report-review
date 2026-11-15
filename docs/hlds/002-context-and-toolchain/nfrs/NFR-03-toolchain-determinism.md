# NFR-03: Runtime Determinism

**Status:** Accepted

## Requirement

The same OpenCode pin yields a v2 runtime on every runner. A v1 binary is rejected whether it is
cached or found earlier on PATH. A foreign managed-config binding stops the run before any model
call. An unreadable binding also stops the run unless the liveness probe fails in the same run;
that combined diagnostic failure is advisory in CI. Requested model IDs are registered without
mutating existing entries.

## Verification

Exercise cached-v1, PATH-shadowed-v1, successful-v2, foreign-config-binding with either liveness
result, unreadable-binding with successful liveness, combined unreadable-binding and failed-liveness,
and missing-model-key cases. Assert the exit status and that the resolved config differs only by the
added keys.

## Acceptance Criteria

- v1 is rejected in every path.
- A foreign binding, or an unreadable binding with successful liveness, exits with fatal status 3.
- An unreadable binding plus failed liveness exits with advisory status 1 in CI.
- Registration adds only absent keys and preserves existing metadata and placeholders.

## Applies To

Goal 4; the toolchain install, config preparation and health flow.
