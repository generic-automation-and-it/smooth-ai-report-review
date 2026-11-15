# NFR-02: Push Safety

**Status:** Accepted

## Requirement

No push occurs when an auto-detected suite passes at HEAD and fails after the edits. Auto-detected
failures confirmed at HEAD do not block. Timeouts, exhausted budgets and unavailable baselines
fail closed. An explicit test command uses absolute gating: any nonzero exit blocks publication.
A test-gate-blocked run skips the push with a reason. Its summary publishes up to 30,000 bytes of
tracked-file diff and lists newly created file names; new file contents and a complete recovery patch
are not preserved in the run artifact.

## Verification

Exercise auto-detected green-to-red, red-before-and-after and all-green cases, plus timeouts,
exhausted budgets, unavailable baselines and failed explicit commands. Assert the push outcome
and the skip reason. Manually verify the workflow summary's capped tracked-file diff and new-file
name list; the mapped test covers the test gate, not publication or complete fix recovery.

**Test mapping:** `test-run-test-gate.sh`.

## Acceptance Criteria

- Green-to-red and timeout cases never push.
- Auto-detected suites confirmed already red at HEAD are reported without blocking.
- Failed explicit commands, exhausted budgets and unavailable baselines never push.
- Test-gate-blocked cases expose the reason, up to 30,000 bytes of tracked-file diff, and new-file
  names, not a guaranteed complete recovery patch.

## Applies To

Goal 3; the test-gate and publication path.
