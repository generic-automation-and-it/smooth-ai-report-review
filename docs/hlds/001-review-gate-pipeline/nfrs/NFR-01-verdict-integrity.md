# NFR-01: Verdict Integrity

**Status:** Accepted

## Requirement

An incremental review never posts an approve verdict. Any run with at least one unresolved chunk
failure posts request-changes regardless of the model's recommendation. A full review may approve
only when coverage is complete and no Critical or High finding survives the evidence gate.

## Verification

Exercise the action matrix as automated cases: incremental-with-no-findings, full-with-no-findings,
full-with-Critical, full-with-a-failed-chunk, and all-models-failed. Assert both the posted state
and the header banner against the same failure count.

## Acceptance Criteria

- No incremental case yields approve.
- A failed chunk yields request-changes and a banner naming the failed count.
- A complete full review with no surviving Critical/High is eligible for approve when summary
  generation succeeds, or complete usable structured coverage allows deterministic recommendation
  sync to recover a summary-only failure. A deliberate comment verdict remains a comment.

## Applies To

Goals 3 and 4; the aggregation and posting flow.
