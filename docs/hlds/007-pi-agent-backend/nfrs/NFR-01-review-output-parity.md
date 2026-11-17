# NFR-01: Review-Output Parity

**Status:** Draft

## Requirement

For the same chunk and scoped rule set, either backend must pass the gate's shape predicate and yield
a structurally valid findings document, with zero backend-specific post-processing. The complete
delivered instruction set — generated artifact plus native context — must be identical by hash across
backends, satisfy the corpus's must-catch and must-not-flag expectations, and show no precision or
recall regression beyond its tolerance.

## Verification

Run the labelled corpus and shape checker against both backends with the same chunks and rules;
compare the complete instruction-set hash per chunk, assert byte-identical post-processing for the
same answer, and compare precision/recall to the OpenCode baseline for that corpus revision.

## Acceptance Criteria

- The delivered instruction-set hash is identical for both backends.
- Both answers pass the shape predicate, with no backend exemption.
- Merge, numbering and coverage output are identical for the same answer text.
- Every must-catch sample is caught, every must-not-flag sample is respected, and precision/recall
  stay within the corpus tolerance.

## Applies To

Goal 1 and Goal 2; the review path in both packagings.
