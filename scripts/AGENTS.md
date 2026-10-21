# scripts/

Repo-root scripts for consumers: the one-command skills installers. Operator contract:
[`SKILLS_INSTALLER.md`](SKILLS_INSTALLER.md). Decision: LADR-108 in
`.agents/skills/ai-review-report/AGENTS.md`.

## Non-Negotiables

- **Two ports, one contract.** Every behaviour change goes into `install-skills.sh` **and**
  `install-skills.ps1` in the same commit, with a case in `test-install-skills.sh`. The owned lists
  (`OWNED_CORE` / `OWNED_OPTIONAL`, `$OwnedCore` / `$OwnedOptional`) must stay identical — the harness
  compares them.
- **Skills only.** No owned rules or hooks, so neither port edits a tool config file. Adding one means
  porting smooth-ai-product-context-memory's config-edit machinery (markers, snapshots, uninstall that
  removes only its own entries), not improvising it.
- **`ai-review-report` and `ai-analyse` stay behind `-a`.** A per-repo `.agents/skills/ai-review-report`
  makes the reusable gate and the analyse workflow run that copy instead of their pinned tooling.
- **Own state, never a sibling's.** Store `~/.smooth-ai-review`, per-repo state
  `_smooth-ai-review-shared/`. Purge only links whose target is under our store.
- **Corrupt manifest = hard error; manifest written last.** Never reset flags from defaults.
- **The bash port stays bash 3.2-safe** (`/bin/bash` on macOS): no `${v,,}`, `mapfile`, associative
  arrays; `"${arr[@]+…}"` for possibly-empty arrays under `set -u`.
- **The skills ship no symlinks**; a copy is plain `cp -R`. Adding one needs the sibling installers'
  link materialisation first (the harness fails until then).

## Test References

| Tier | Path | Covers |
|---|---|---|
| L0 | `test-install-skills.sh` | both ports per-repo and `-g`, ownership, manifest reconcile/corruption, pruning, harness flags, uninstall, cross-port parity, `lib/resolve-repo-root.sh` |

Registered in the blocking `opencode-v2-regressions` array in `.github/workflows/llm-eval-harness.yml`;
`run-regressions.sh` runs the same list locally. `.ps1` cases skip without `pwsh`.
