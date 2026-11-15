# NFR-02: Push Safety

**Status:** Accepted

## Requirement

No push occurs when an auto-detected suite passes at HEAD and fails after edits. Auto-detected
failures confirmed at HEAD do not block. Timeouts, exhausted budgets and unavailable baselines fail
closed. An explicit test command blocks on any nonzero exit. A blocked run skips the push with a
reason; its summary publishes up to 30,000 bytes of tracked diff and new-file names, not new-file
contents or a complete recovery patch.

## Verification

Exercise green-to-red, red-before-and-after, all-green, timeout, exhausted-budget,
unavailable-baseline and failed-command cases. Assert the push outcome and skip reason. Manually
verify the capped tracked-file diff and new-file names; the mapped test covers the gate, not
complete recovery.

**Test mapping:** `test-run-test-gate.sh`.

## Acceptance Criteria

- Green-to-red and timeout cases never push.
- Auto-detected suites confirmed already red at HEAD are reported without blocking.
- Failed explicit commands, exhausted budgets and unavailable baselines never push.
- Test-gate-blocked cases expose the reason, up to 30,000 bytes of tracked-file diff, and new-file
  names, not a guaranteed complete recovery patch.

## Applies To

Goal 3; the test-gate and publication path.
