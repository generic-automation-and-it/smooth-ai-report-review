# NFR-02: Chunk coverage under the split runtime

**Status:** Draft

## Requirement

On the same corpus revision, the split runtime's chunk execution reports an unreviewed or timed-out chunk
rate no worse than the incumbent runtime's baseline for the same corpus, with per-chunk latency recorded.

## Verification

Run the evaluation harness once per runtime on the same revision and compare the per-fixture RESULTS
tables: counts of unreviewed/failed chunks, per-chunk latency, and the corpus's existing precision and
recall bars. The comparison is report-only and never changes a verdict.

## Acceptance Criteria

- Split-runtime unreviewed/timed-out chunk rate is ≤ the incumbent baseline.
- Precision and recall stay within the corpus's existing bars.
- Per-chunk latency is recorded for both runtimes.

## Applies To

Goal 3; chunk role; the evaluation harness.
