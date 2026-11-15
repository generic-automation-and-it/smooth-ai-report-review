# NFR-02: Enrichment Availability

**Status:** Accepted

## Requirement

No enrichment failure blocks, fails or softens a review. A missing or failed graph, provenance
digest or version check omits only its own block. Each network version check is capped at five
seconds, and each graph slice respects its byte cap including the truncation marker.

## Verification

Inject a missing graph, a failed build, a malformed slice and an unreachable version endpoint;
assert the review proceeds, the verdict is unchanged, and metadata records enrichment availability
separately from review coverage.

## Acceptance Criteria

- Every injected failure still yields a posted review.
- No enrichment failure changes severity, confidence or the recommendation.
- Version checks complete within their bound and never fail the job.

## Applies To

Goal 3; the graph, provenance and version-notice passes.
