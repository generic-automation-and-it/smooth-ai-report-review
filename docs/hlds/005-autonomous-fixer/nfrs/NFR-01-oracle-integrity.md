# NFR-01: Oracle Integrity

**Status:** Accepted

## Requirement

With the self-fix flag off, no committed fix changes a test file, the test framework or any
evaluation asset. With the flag on, evaluation assets remain protected. Every reverted path appears
in the summary comment.

## Verification

Feed a staged fix that edits a test, a framework file and an evaluation manifest; assert each is
reverted before staging and named in the summary. Repeat with the flag on and assert only test and
framework edits survive while evaluation edits are still reverted.

**Test mapping:** `test-filter-test-self-fix.sh`.

## Acceptance Criteria

- The committed diff contains zero protected paths when the flag is off.
- Evaluation paths are never committed, even with the flag on.
- Every reverted path is reported.

## Applies To

Goals 1 and 2; the filter and commit path.
