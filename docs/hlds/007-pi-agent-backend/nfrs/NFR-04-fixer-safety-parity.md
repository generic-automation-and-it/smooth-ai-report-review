# NFR-04: Fixer Safety Parity

**Status:** Draft

## Requirement

Under either backend, **zero** test, framework or evaluation edits are committed while test self-fix
is off, and **zero** pushes occur over a green-to-red regression, a timeout or an unavailable
baseline. The FIX/SKIP summary contract and the completeness pass are unchanged.

## Verification

Run the existing fence and test-gate suites against both backends with identical fixtures, including
a fix that edits a protected file and a fix that turns a passing suite red.

## Acceptance Criteria

- Protected edits are reverted before commit on both backends.
- A gate-blocked push is skipped with a reason on both backends.
- A withheld finding is still named in the summary.
- Summary columns and completeness behaviour are identical for the same model output.

## Applies To

Goal 5; the fixer path in the analyse workflow.
