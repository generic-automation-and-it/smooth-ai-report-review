# NFR-02: Identifier Fidelity

**Status:** Accepted

## Requirement

Identifiers are reproduced exactly as posted: findings keep their ordered-list number, and residual
risks, testing gaps and pre-existing items keep their class prefix. No `#` plus digit appears in any
written text, and a copied finding link is stripped before writing.

## Verification

The mapped test is a static instruction guard: it checks that the skill specifies permalink removal
before writing Skip Areas bullets and summary-table rows. It does not process sample reviews or
validate written output.

Manually verify sample reviews and Skip Areas output for verbatim identifier form, absence of
auto-linking tokens, and removal of finding permalinks without changing identifier or skip text.

**Test mapping:** `test-skip-bullet-format.sh`.

## Acceptance Criteria

- No written identifier renders as a cross-referenced issue link.
- Class-prefixed identifiers are bolded and never renumber a finding.
- A stripped permalink changes no identifier or skip text.

Renderer-side identifier safety is owned by [003 NFR-03](../../003-findings-and-decisions/nfrs/NFR-03-identifier-safety.md);
this NFR covers identifiers the consumer writes.

## Applies To

Goal 2 and Goal 3; every table row and skip bullet the consumer writes.
