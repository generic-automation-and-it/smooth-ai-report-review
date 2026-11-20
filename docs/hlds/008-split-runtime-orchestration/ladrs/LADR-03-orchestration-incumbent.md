# LADR-03: Orchestration remains on the incumbent runtime

**Status:** Draft

## Context

- Semantic grouping and aggregation are two synthesis calls; the aggregation prompt forbids file
  verification, so runtime tool and discovery differences are inert.
- The gate's output shape and aggregation guards are tuned against the incumbent runtime's behaviour.
- No measured synthesis advantage exists for an alternative runtime.

## Decision

**Keep orchestration on the incumbent runtime by default.** An override may select another runtime for
experimentation, but the default stays incumbent until measured evidence shows an equal-or-better
synthesis result without changing posted bodies. Orchestration failure semantics — fall back to the
resolved review model — are unchanged.

## Consequences

- Posted bodies stay byte-identical under the default split.
- The incumbent runtime remains required for orchestration even when chunks move.
- An override carries the same evidence and failure obligations as any role.

## Open

- Which synthesis metric would justify an orchestration override — resolved by evaluation design, not
  by assumption.
