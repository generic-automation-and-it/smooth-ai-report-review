# LADR-02: Test and Evaluation Edits Are Off by Default and Reverted Deterministically

**Status:** Accepted

## Context

- A fix that also rewrites its test can hide its own regression.
- An evaluation manifest carries the must-catch label, so editing it can turn a failing eval green.
- Model instructions alone cannot guarantee a protected file stays untouched.
- A consumer's production code may legitimately live under a directory named `eval`.

## Decision

**Forbid** edits to tests and test frameworks unless the self-fix flag is truthy, which stays off by
default, and forbid edits to evaluation assets unconditionally. Enforcement is a deterministic
filter that reverts protected edits before staging, not a prompt request.

Evaluation protection matches the directory segment deliberately broadly, so a production path is
also protected. Every reverted path is named in the summary comment.

## Consequences

- The suite remains an independent oracle for every autonomous fix.
- A fix that needs a test change ends in skip and waits for a human.
- A production file under an `eval` segment is never auto-edited; the cost is a skipped fix.
- Reverted edits are visible rather than silent.

## Related

- Canonical **LADR-045** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  enforcement notes in [ai-analyse AGENTS.md](../../../../.agents/skills/ai-analyse/AGENTS.md).
