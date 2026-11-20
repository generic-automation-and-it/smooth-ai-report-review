# AGENTS.md - Split Runtime

## TL;DR

Read [`README.md`](./README.md) first — the split-runtime design, its LADRs and its NFRs live there.

## Non-Negotiables

- **Per-role selection is routing, not a behaviour switch.** A role's runtime may change; its prompt,
  contract and failure taxonomy may not.
- **Chunk evidence parity is a precondition.** A chunk runtime that cannot deliver the same generated
  artifact, start-set and on-read nested context is not selectable — see
  [LADR-02](./ladrs/LADR-02-chunk-evidence-parity.md).
- **RTK initializes per runtime target.** The pi target (`rtk init --agent pi`) and the incumbent
  plugin are separate integrations with separate floors; neither may block a review.

## Changelog

| Date | Change | Ref |
| :---- | :---- | :---- |
| 2026-11-20 | Scaffolded; six goals, six LADRs, four NFRs | — |
