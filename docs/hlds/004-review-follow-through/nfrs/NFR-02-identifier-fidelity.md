# NFR-02: Identifier Fidelity

**Status:** Accepted

## Requirement

Identifiers are reproduced exactly as posted: findings keep their ordered-list number, and residual
risks, testing gaps and pre-existing items keep their class prefix. No `#` plus digit appears in any
written text, and a copied finding link is stripped before writing.

## Verification

Run the formatting guard over sample reviews and Skip Areas writes, asserting the identifier form
and the absence of an auto-linking token. Include a finding line carrying a permalink and assert the
link is removed.

## Acceptance Criteria

- No written identifier renders as a cross-referenced issue link.
- Class-prefixed identifiers are bolded and never renumber a finding.
- A stripped permalink changes no identifier or skip text.

## Applies To

Goal 2 and Goal 3; every table row and skip bullet the consumer writes.
