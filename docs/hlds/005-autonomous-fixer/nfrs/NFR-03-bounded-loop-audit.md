# NFR-03: Boundedness and Audit

**Status:** Accepted

## Requirement

The loop performs at most the configured number of incremental cycles per review epoch and ends
early on a cycle with no edits. It never processes a fork, a stale artifact or a non-actionable
review. Every run uploads an audit artifact only after redaction succeeds.

## Verification

Exercise cap-reached, no-edit, fork, stale-artifact and redaction-failure cases. Assert the cycle
count, the stop reason, and the artifact presence or absence.

**Test mapping:** `test-soft-items-workflow.sh`, `test-select-ai-analyse-artifact.sh` and `test-analyse-tooling-verify.sh`.

## Acceptance Criteria

- No epoch exceeds the configured cycle cap.
- A no-edit cycle ends the loop without a further run.
- No artifact is uploaded when redaction fails.

## Applies To

Goal 4; the workflow trigger, loop control and artifact upload.
