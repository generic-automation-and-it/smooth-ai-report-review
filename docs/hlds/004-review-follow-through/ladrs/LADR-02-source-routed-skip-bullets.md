# LADR-02: Results Route by Source; Skip Areas Bullets Are Load-Bearing

**Status:** Accepted

## Context

- Copilot reviews expose inline threads that can be replied to and resolved.
- Other reviews have no thread model; their results belong in the PR description.
- The next review round learns that a finding was intentionally skipped from the Skip Areas bullets.
- A summary table alone does not propagate a skip, which caused the same finding to be re-raised.

## Decision

**Route** by the detected review source, passing the selected review's id so an older Copilot review
cannot misroute a newer non-Copilot review.

For Copilot, reply to and resolve each processed issue's thread and post one summary comment. For
every other source, append AI Review Notes and write every skipped item as a Skip Areas bullet with
its identifier and a skip reason, then re-fetch the PR body and verify those bullets inside the
Skip Areas section before reporting completion.

## Consequences

- Each result lands where its consumer will look for it.
- A skip without a verified bullet is treated as a failed run, not a formatting issue.
- The PR description becomes the durable cross-round record.
- Copilot threads and non-Copilot descriptions require separate verification paths.

## Related

- Canonical **LADR-083**, **LADR-101**, **LADR-122** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  runtime contract in [ai-review SKILL.md](../../../../.agents/skills/ai-review/SKILL.md).
