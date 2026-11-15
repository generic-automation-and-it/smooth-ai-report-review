# LADR-02: Missing Quoted Evidence Demotes Confidence, Never Severity

**Status:** Accepted

## Context

- A model can describe a defect in code it never actually saw.
- Severity expresses impact; evidence expresses whether the finding is real.
- Conflating the two lets a confident-sounding claim become a blocker.
- A standards claim without the rule the reviewer was given is unverifiable.

## Decision

**Require** the motivating line, at its location, before a finding may anchor at 75 or 100. A
finding without that evidence is demoted to 50 and counted; non-critical items below 75 are
suppressed, while Critical items keep their severity and can still block.

Confidence anchors are behavioural and discrete. A standards claim withdraws unless it names the
applicable rule the reviewer was actually given, quotes a short excerpt, and cites its source; the
citation never raises confidence or severity.

## Consequences

- Unverifiable claims cannot block a merge, but impact remains visible.
- Reviewers get an explicit count of demoted findings.
- Omissions are quoted by where the missing code belongs, not by a nearby mention.
- Generated-symbol claims can cite the generating construct, so a failed literal search is not proof.

## Related

- Canonical **LADR-055**, **LADR-119** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  standards-citation behavior in [root AGENTS.md](../../../../AGENTS.md).
