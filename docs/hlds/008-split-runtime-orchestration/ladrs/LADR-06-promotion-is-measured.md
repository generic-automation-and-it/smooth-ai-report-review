# LADR-06: Promoting pi chunks to default is measured

**Status:** Draft

## Context

- The split runtime is opt-in; defaults preserve the incumbent runtime.
- Throughput and prompt-headroom advantages do not by themselves prove review quality.
- Review quality is measurable on a fixed corpus at a fixed revision.

## Decision

**Gate any promotion of an alternative runtime to default on measured evidence.** Promotion requires the
per-chunk evidence parity to hold and the coverage and quality bars to be met against the incumbent
baseline on the same corpus revision. Until then the alternative remains an explicit selection.

## Consequences

- No default changes without evidence.
- The measurement is report-only; it never changes a verdict.
- A failed bar keeps the incumbent default and is recorded, not rationalized.

## Open

- The exact sample size and quality bars — resolved when the evaluation corpus for the split runtime is
  registered.
