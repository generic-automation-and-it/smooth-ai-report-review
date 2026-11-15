# NFR-02: Evaluation Independence

**Status:** Accepted

## Requirement

The `opencode-v2-regressions` job completes with no secret and no model endpoint call, and returns a
check result for every relevant pull request, including drafts and forks. The paid `llm-evals` job
never blocks.

## Verification

Run `opencode-v2-regressions` in a fork-like context with no secrets, and in a path that does not
match its relevance rules; assert completion and a check result in both. Confirm `llm-evals` is
configured as report-only.

**Test mapping:** `eval/test-evals.sh` and `run-regressions.sh`.

## Acceptance Criteria

- `opencode-v2-regressions` succeeds without secrets or network model calls.
- Every relevant PR receives a result, including drafts and forks.
- `llm-evals` cannot block branch protection.

## Applies To

Goal 3; the evaluation harness workflow.
