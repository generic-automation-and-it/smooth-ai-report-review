# NFR-02: Enrichment Availability

**Status:** Accepted

## Requirement

No enrichment failure blocks, fails or softens a review. A missing or failed graph or provenance
digest omits its corresponding context. Failed version lookups leave the latest version unknown;
detected installed-version lines remain visible. Each network version check is capped at five
seconds, and each graph slice respects its byte cap including the truncation marker.

Degradation is visible: an enabled graph feature the installed graph cannot deliver (churn
unavailable, a version below the feature's floor) is named in one Coverage line, and a disabled
feature or an unknown version adds none.

## Verification

Inject a missing graph, a failed build, a malformed slice and an unreachable version endpoint;
assert the review proceeds, the verdict is unchanged, and metadata records enrichment availability
separately from review coverage.

**Test mapping:** `test-code-graph.sh`, `test-graph-signals-slice.sh`, `test-graph-signals-artifact.sh`, `test-check-versions.sh` and `test-blame-digest.sh`.

## Acceptance Criteria

- Every injected failure still yields a posted review.
- No enrichment failure changes severity, confidence or the recommendation.
- Version checks complete within their bound and never fail the job.
- A degraded enabled feature produces exactly one Coverage line; a healthy run produces none.

## Applies To

Goal 3; the graph, provenance and version-notice passes.
