# LADR-05: The Workflow Owns Every Side Effect and Fences Its Own Tooling

**Status:** Accepted

## Context

- The model runs unattended and must not be able to commit, push or reach the network.
- The credential-bearing commit step executes repository tooling.
- Agent-editable tooling would let the model influence the step that publishes its own work.
- Workflow-file edits can change the loop that judges the edit.

## Decision

**Make** the model edit-only: no shell, no git, no network. The workflow owns scope extraction,
filters, commit, rebase, push, comment and artifact upload.

Before publishing, the workflow verifies that the fetched or in-repository tooling tree is
unmodified; a change fails the job. Auto-fix commits exclude workflow scratch and tooling paths, and
workflow-file edits are downgraded to a skipped push unless a workflow-scoped token is available.

## Consequences

- The model cannot execute the tooling that would publish its output.
- A tooling modification fails closed instead of being reviewed after publication.
- Workflow changes cannot silently alter the loop's own rules.
- Some legitimate workflow fixes wait for a human.

## Related

- Canonical **LADR-042** and **LADR-110** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  secret-handling rules in [skill-secret-handling](../../../../.github/instructions/skills/skill-secret-handling.instructions.scoped.md).
