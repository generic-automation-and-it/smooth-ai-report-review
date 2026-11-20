# LADR-03: A Bounded Two-Tier Chain with One Retry per Chunk

**Status:** Accepted

## Context

- Provider outages, quotas and slow responses are normal operating conditions.
- A single model per chunk turns one transient failure into a failed review.
- A fixed timeout against variable prompt size fails honest long chunks.
- Retrying forever hides a dead endpoint and doubles a doomed run.

## Decision

**Adopt** a primary-then-secondary chain per chunk. The chunk budget is a floor that scales with
prompt size up to a ceiling, and the budget is split across the chain once there is enough room for
both stages. A chunk whose stderr stream stops growing for the stall threshold is killed early
as a routing event, not as a slow success. Streaming stderr text counts as progress even without
tool events.

A failed chunk gets at most one retry with the same scaled budget; the retry drops the split
because a retry that cannot differ is not a retry. A chunk that fails twice stays failed. When every
chunk of a multi-chunk PR fails, the sweep is skipped: that is a dead endpoint. The sweep is also
skipped once the opt-in total-run deadline has been reached, including for chunks that failed
before it (canonical LADR-121). A chunk the provider's content filter refused on every call is not
retried either: the retry would send the same prompt for the same refusal. It still fails closed,
and its failure reason names the refusal (canonical LADR-123).

## Consequences

- Transient failures usually resolve without human action.
- Slow-but-honest chunks are not fail-closed by a fixed clock.
- Budget splitting requires enough total time before it arms, so common budgets keep older behavior.
- Retry cost is bounded at one extra attempt per failed chunk.

## Related

- Canonical **LADR-002**, **LADR-065**, **LADR-081**, **LADR-082**, **LADR-084**, **LADR-102**, **LADR-121**, **LADR-123** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
