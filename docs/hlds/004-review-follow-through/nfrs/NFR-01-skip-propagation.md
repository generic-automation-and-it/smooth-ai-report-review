# NFR-01: Skip Durability

**Status:** Accepted

## Requirement

Every skipped item from a non-Copilot review appears as a Skip Areas bullet in the live PR
description before the run reports completion. Verification reads only that section, and a missing
bullet fails the run rather than reporting success.

## Verification

After writing the description, re-fetch it, extract the Skip Areas section, and grep each bullet's
unique skip-reason tail. Re-fetch once to rule out read lag; if the bullet is still absent,
repeat the bullet update and verify again. Never report completion while any skipped item's
bullet remains absent from the live Skip Areas section.

**Test mapping:** `test-skip-bullet-format.sh` and `test-copilot-review.sh`.

## Acceptance Criteria

- Each skipped item has one bullet with its identifier, anchor and skip reason.
- A bullet absent from the live body blocks completion.
- Existing description sections are preserved verbatim.

## Applies To

Goal 2; the non-Copilot routing path of the human-driven `/ai-review execute`. Autonomous
`ai-analyse` skips are out of scope here; their recurrence is measured by HLD-006 NFR-04.
