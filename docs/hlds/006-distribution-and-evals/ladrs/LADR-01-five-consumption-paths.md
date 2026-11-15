# LADR-01: Five Consumption Paths Share One Source of Truth

**Status:** Accepted

## Context

- Consumers differ in policy: some allow a cross-organization reusable workflow, some do not.
- Some teams install skills into an AI tool; others want a repository-level gate only.
- Every extra copy of gate logic is a place for behavior to drift silently.
- A consumer must be able to pin what it runs.

## Decision

**Support** five channels: the reusable workflow with side-checked pinned tooling, a local-job caller
that checks out this repository at a pinned commit, the skills installer, the Claude Code
marketplace plugin, and the documented copy-install.

Gate-running channels resolve the same entrypoint; skill channels resolve the same skill folders.
The installer and marketplace deliver skills only, never the CI gate. The reusable workflow resolves
its tooling from the job's workflow ref, never from the caller's commit, because the caller's commit
does not exist in this repository. RTK pins are not uniform: the reusable workflow's `rtk_version`
input wins over the `OPENCODE_TOOL_RTK_VERSION` Variable, while the local-job packaging reads only
the Variable.

## Consequences

- A consumer can adopt the gate or its skills under several organizational policies without a fork.
- A behavior change lands once and reaches every channel through the same source.
- Each channel owns its own pin discipline; only the artifacts are shared.
- The local-job channel runs the same third-party code the policy is meant to gate, so it needs
  explicit security sign-off.

## Related

- Canonical **LADR-037**, **LADR-108** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  installer contract in [SKILLS_INSTALLER.md](../../../../scripts/SKILLS_INSTALLER.md).
