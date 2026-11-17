# NFR-04: Measurement Visibility

**Status:** Accepted

## Requirement

Self-review measurements are visible and honest, and never gate a run:

- Every autonomous `ai-analyse` skip that reappears as a finding in the next gate review is counted.
  A skip row with no file, with no matching finding or with more than one match is counted in
  `unmatched_skips`, never dropped and never double-counted. When either side of the join is
  unavailable, the result is `unavailable`, never zero.
- Graph-hint uptake (findings citing `graph_evidence`) and accuracy (graph-cited test-gap claims
  accepted in recall fixtures versus rejected in precision fixtures) are reported after the eval
  verdict and never change it.
- A harvested human label records the graph hint kind the reviewer was shown for the finding's file,
  or `none` with `attribution_unavailable` when the run artifact has no slice to check.

## Verification

Join a synthetic PR timeline with one known reappearing skip, one ambiguous row and one row with no
file; assert one reappearance, two unmatched rows, and `unavailable` when either side is removed.
Resolve hint kinds from a synthetic run artifact with and without the chunk's slice. Assert that the
eval runner prints the hint counters after its verdict.

**Test mapping:** `test-graph-self-review.sh`.

## Acceptance Criteria

- No measurement reports zero when its input was missing.
- Every skip row lands in exactly one of `reappeared` or `unmatched_skips`.
- No measurement series changes an exit code, a verdict or a posted state.

## Applies To

Goal 3; the eval runner, the real-findings harvester and the skip-recurrence measurement.
