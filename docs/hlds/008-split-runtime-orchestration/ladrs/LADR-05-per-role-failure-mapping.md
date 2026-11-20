# LADR-05: Failure mapping is per role, not per runtime

**Status:** Draft

## Context

- The gate's failure taxonomy is a behavioural contract: chunk failures fail closed, orchestration
  failures fall back.
- Runtimes expose different raw signals (exit codes, empty output, truncation markers), so classification
  cannot be delegated to them.
- A per-runtime mapping would let the same failure mean different things in one run.

## Decision

**Classify failures by role.** Each runtime's raw result is normalized into the role's existing outcomes:
a failed attempt, a shape-rejected answer, or a completed answer. Chunk failures keep the fail-closed
channel; orchestration failures keep the fallback chain. No runtime-specific failure outcome is added.

## Consequences

- The failure contract survives a runtime swap unchanged.
- Each runtime adapter must normalize its signals; a missing signal is a failed attempt, not a success.
- Tests pin the mapping per role, not per runtime pair.
