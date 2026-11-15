# NFR-02: Evaluation Independence

**Status:** Accepted

## Requirement

The blocking regression suite completes with no secret and no model endpoint call, and returns a
check result for every relevant pull request, including drafts and forks. The paid model-evaluation
job never blocks.

## Verification

Run the blocking job in a fork-like context with no secrets, and in a path that does not match its
relevance rules; assert completion and a check result in both. Confirm the paid job is configured as
report-only.

## Acceptance Criteria

- The blocking job succeeds without secrets or network model calls.
- Every relevant PR receives a result, including drafts and forks.
- The paid job cannot block branch protection.

## Applies To

Goal 3; the evaluation harness workflow.
