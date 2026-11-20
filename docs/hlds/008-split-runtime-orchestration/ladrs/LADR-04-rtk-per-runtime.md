# LADR-04: RTK initializes per active runtime at its own floor

**Status:** Draft

## Context

- RTK is a token-optimization layer installed beside a runtime; its integration target is per CLI agent.
- The gate pinned RTK for one runtime only, so a second runtime would silently lose the optimization.
- RTK is an enhancement: its absence must never fail a review.

## Decision

**Initialize RTK for each active runtime through that runtime's own integration target.** The pi
runtime uses `rtk init --agent pi`; the incumbent runtime keeps its plugin initialization. Each is
initialized only at or above the floor that supports its target; below the floor the binary is retained,
initialization is skipped with one notice, and the review runs. RTK initialization stays best-effort.

## Consequences

- A hybrid run initializes both integrations; a failure in either is advisory.
- The RTK pin is checked against the target actually used, not assumed from the incumbent.
- RTK never becomes a precondition for a model call.

## Open

- The minimum RTK release that supports the pi target, and what that target installs — measured before
  this moves to Prototype.
