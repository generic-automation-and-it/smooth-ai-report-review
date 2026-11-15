# NFR-03: Identifier Safety

**Status:** Accepted

## Requirement

No posted review body contains `#` followed by digits. Identifiers are reproduced verbatim: findings
as ordered-list numbers, and residual risks, testing gaps and pre-existing items as bolded
class-prefixed tokens. Permalinks never change a parsed identifier.

## Verification

Render fixture reviews containing every item class and scan the output for `#` plus a digit. Parse
the same body with links enabled and disabled and compare the extracted identifiers.

## Acceptance Criteria

- The scan finds zero auto-linking identifier tokens.
- Every item class keeps its own sequence.
- Link stripping changes no extracted identifier.

## Applies To

Goal 4; the renderer and every consumer that writes review text.
