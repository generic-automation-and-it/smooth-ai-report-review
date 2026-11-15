# LADR-02: The Installer Owns Its Own State and Installs Skills Only

**Status:** Accepted

## Context

- Sibling installers place skills into the same AI tool folders.
- A shared installer that rewrites another's config can break unrelated tooling.
- Two language ports can drift if their owned lists or rules diverge.
- A per-repository copy of the gate skill changes which tooling the gate runs.

## Decision

**Keep** the installer scoped to its own store, manifest and owned skills. It writes per repository
or machine-wide, links only into tool folders that already exist, and purges only links whose
target is inside its own store.

Both ports implement one contract with identical owned lists. The report and analyse skills install
only behind an explicit flag, because an in-repository copy changes the tooling the gate and fixer
would otherwise run. The manifest is written last, and a corrupt manifest is a hard error.

## Consequences

- Installing this repo's skills cannot disturb another installer's state.
- The two ports stay interchangeable and parity is testable.
- Consumers who want the CI gate get it from a workflow channel or the documented workflow copy,
  never from an installed skill copy.
- One documented profile edit remains, with its own snapshot and uninstall path.

## Related

- Canonical **LADR-108** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  operator contract in [SKILLS_INSTALLER.md](../../../../scripts/SKILLS_INSTALLER.md).
