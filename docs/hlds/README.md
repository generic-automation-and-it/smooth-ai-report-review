# High-Level Designs

Design records for the review gate solution, one per owned feature group. Each folder follows the
same contract: a README with intent and goals, strategic LADRs, measurable NFRs, and a C1 diagram.
None contains an implementation plan; execution lives in the issue tracker.

These records describe delivered systems, so each README's status is `Accepted (as built)` — an
extension of the create-hld status vocabulary for an as-built design.

Eval corpus and harness assets are owned by the `ai-review-report` skill; the platform layer governs
their gating and release role. See [eval AGENTS.md](../../.agents/skills/ai-review-report/scripts/eval/AGENTS.md).

HLD-local `LADR-NN` numbers are scoped to their folder; canonical `LADR-001..122` identifiers live in
the skill `AGENTS.md` files. Source precedence: canonical skill `SKILL.md`/`AGENTS.md` and root
`AGENTS.md` outrank these records; when they change, update the affected HLD in the same commit or PR.
Adding an HLD requires a manual index row and a structural validation run; `scaffold-hld.sh` does not
create the row.

| HLD | Owner | Scope |
|---|---|---|
| [001 PR Review Gate Pipeline](./001-review-gate-pipeline/README.md) | `ai-review-report` | Diff scope, no-review gates, chunking, review chain, coverage, verdict and posting |
| [002 Context Delivery and Toolchain](./002-context-and-toolchain/README.md) | `ai-review-report` | Scoped context, runtime `AGENTS.md`, provider transport, graph hints, pinned OpenCode v2 |
| [003 Findings Integrity and Decision Scoring](./003-findings-and-decisions/README.md) | `ai-review-report` (consumed by both consumers) | Evidence gate, merge and numbering, decision judge, presentation |
| [004 Review Follow-Through](./004-review-follow-through/README.md) | `ai-review` + `git-commit-review-push` | Analysis and execution, source routing, skip bullets, commit trigger |
| [005 Autonomous Low and Medium Fixer](./005-autonomous-fixer/README.md) | `ai-analyse` | Scope, oracle fences, test gate, bounded push loop |
| [006 Distribution and Evaluation](./006-distribution-and-evals/README.md) | Repository platform | Consumption channels, installer contract, layered evals, versioning |
