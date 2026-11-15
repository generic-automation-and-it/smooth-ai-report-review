# LADR-04: The Plugin Manifest Is the Only Version Manifest

**Status:** Accepted

## Context

- Multiple manifests produce tags that disagree with what consumers actually install.
- A package-registry channel duplicated the skills and added a second release path.
- A major tag is what consumers reference; it must move with the release version.
- Marketplace metadata and the plugin manifest can drift independently.

## Decision

**Declare** the plugin manifest as the sole version source. The updater derives the floating major
tag (`vN`) from that version and moves it to the default-branch HEAD; it does not validate release
tags. The package channel is retired: no package manifest, no publish workflow, and no consumer
path depends on a registry.

Marketplace entries point at the same skill folders as every other channel.

## Consequences

- One version names every channel.
- The floating major tag follows the default-branch HEAD rather than a validated release tag.
- Releasing costs one version bump in one file.
- Consumers using a registry must migrate to a workflow or installer channel.

## Related

- Canonical **LADR-108** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md);
  version flow in [update-major-tag.yml](../../../../.github/workflows/update-major-tag.yml).
