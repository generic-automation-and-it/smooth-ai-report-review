# AGENTS.md - PR Review Gate Pipeline

## TL;DR

Read [`README.md`](./README.md) first — the gate's goals, LADRs and NFRs live there.

## Non-Negotiables

- **This HLD is the contract, not the runtime reference.** Env-var names, prompt rules and knob
  defaults live in [ai-review-report SKILL.md](../../../.agents/skills/ai-review-report/SKILL.md);
  change behaviour there and keep this document at intent level.

## Changelog

| Date | Change | Ref |
| :---- | :---- | :---- |
| 2026-11-15 | Authored from the delivered gate contract | — |
