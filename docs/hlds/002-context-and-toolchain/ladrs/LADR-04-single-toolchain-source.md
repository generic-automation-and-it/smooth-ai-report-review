# LADR-04: One Install Source per Tool with a Hard v2 Floor

**Status:** Accepted

## Context

- v1 and v2 share the same command name, so an unpinned run can silently use the wrong major.
- A long-lived background service binds the config it saw at startup, not the current one.
- A pin can name a model the committed roster does not contain.
- A plugin can require a newer tool version than the one installed.

## Decision

**Require** every install path to delegate to one installer library per tool. OpenCode must be
major version 2 or newer both for a cached binary and after installation. Every CI entrypoint stops
the service after preparing the managed config, and health verification confirms that the managed
config is the one loaded.

Requested model IDs absent from the config are registered as empty entries at runtime, without
touching existing metadata. The RTK plugin is initialized only when the installed version meets the
shared compatibility floor.

## Consequences

- A host carrying v1 cannot short-circuit an install or shadow the installed v2.
- A foreign config binding fails loudly instead of producing misleading reviews.
- New model IDs work without editing committed rosters.
- An older pinned RTK keeps working with review enrichment; only plugin initialization is skipped.

## Related

- Canonical **LADR-048**, **LADR-054**, **LADR-087**, **LADR-107** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
- Secret handling for config placeholders and workflow env mapping: [skill-secret-handling](../../../../.github/instructions/skills/skill-secret-handling.instructions.scoped.md).
