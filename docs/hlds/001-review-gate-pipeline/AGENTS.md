# AGENTS.md - PR Review Gate Pipeline

## TL;DR

Read [`README.md`](./README.md) first — the gate's goals, LADRs and NFRs live there.

## Non-Negotiables

- **This HLD is the contract, not the runtime reference.** Env-var names, prompt rules and knob
  defaults live in [ai-review-report SKILL.md](../../../.agents/skills/ai-review-report/SKILL.md);
  change behaviour there and keep this document at intent level.
- **The reviewed repository is untrusted input.** Never re-enable web access, point
  `OPENCODE_CONFIG` at the repo's config, or interpolate author notes outside the fence; canonical
  LADRs 094, 103, 118, 025, 029 and 043 in
  [ai-review-report AGENTS.md](../../../.agents/skills/ai-review-report/AGENTS.md) own those boundaries.

## Changelog

| Date | Change | Ref |
| :---- | :---- | :---- |
| 2026-11-15 | Authored from the delivered gate contract | — |
