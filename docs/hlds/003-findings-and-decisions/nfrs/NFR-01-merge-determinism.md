# NFR-01: Merge Determinism

**Status:** Accepted

## Requirement

The same chunk documents produce the same merged document, ordering and numbering. Duplicate
findings merge conservatively, and coverage counts every merged chunk with each missing chunk named.

## Verification

Run the merge twice over a fixed fixture set containing duplicates, conflicting severities and a
missing chunk; compare the full JSON and rendered numbering. Include a partial-coverage fixture and
assert the missing chunk appears in the coverage block.

## Acceptance Criteria

- Repeated merges are byte-identical.
- Duplicate fields resolve to the conservative value.
- Coverage never counts a chunk as covered when it contributed nothing; every such chunk is named.

## Applies To

Goal 2; the merge, numbering and coverage-rendering flow.
