# NFR-01: Review-Output Parity

**Status:** Draft

## Requirement

For the same chunk and the same scoped rule set, either backend must produce an answer that passes
the gate's shape predicate and yields a structurally valid findings document, with **zero
backend-specific post-processing**. The complete delivered instruction set — generated artifact plus
natively loaded context — must be identical by hash across backends. It must also satisfy the
labelled corpus's must-catch and must-not-flag expectations without a precision or recall regression
beyond the corpus tolerance.

## Verification

Run the labelled review corpus and the shape checker against both backends with the same chunks and
rules; compare the complete delivered instruction set's hash per chunk, and assert that the same
model answer yields byte-identical post-processing. Run the corpus's must-catch and must-not-flag
fixtures against both backends and compare precision and recall to the OpenCode baseline recorded for
that corpus revision.

## Acceptance Criteria

- The per-chunk delivered instruction set hash (generated artifact plus native context) is identical
  for both backends.
- Both backends' answers satisfy the shape predicate on the corpus, with no backend-specific
  exemption.
- Findings merge, numbering and coverage output are identical for the same answer text.
- Every must-catch sample is caught and every must-not-flag sample is not flagged, and precision and
  recall are no worse than the OpenCode baseline beyond the corpus's recorded tolerance.

## Applies To

Goal 1 and Goal 2; the review path in both the reusable and local packagings.
