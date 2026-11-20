# NFR-01: Per-chunk evidence parity

**Status:** Draft

## Requirement

For the same chunk and fixed graph data, the resolved runtime pair delivers byte-identical prompt input
and content-equal delivered instruction sets — generated chunk artifact, start-set context, and on-read
nested context — with no context file delivered twice.

## Verification

A deterministic offline pairing test runs one chunk through both role paths with stub runtimes and fixed
fixtures, comparing prompt hashes and the delivered-context line set; a real-runtime case proves the
on-read attachment once per directory. No model call is required.

## Acceptance Criteria

- Prompt hashes are equal for both runtimes on the same chunk.
- Delivered context line sets are equal and contain each exact context file once.
- The consumed rule-source set is identical; no additional rule directory is discovered.

## Applies To

Goal 2; chunk role; both runtimes.
