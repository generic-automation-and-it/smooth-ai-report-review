# Skills installers

One-command installers for the review skills under `.agents/skills/`, for Claude Code, Codex and
OpenCode. They are built to the same recipe as the installers in
[smooth-devex-template](https://github.com/generic-automation-and-it/smooth-devex-template)
(`docs/wiki/installer-recipe.md` there) and
[smooth-ai-product-context-memory](https://github.com/generic-automation-and-it/smooth-ai-product-context-memory),
cut down to what this repo owns: **skills only**. Requirement IDs below (A1, B2, …) are the recipe's.

| Script | Platform | Needs |
|---|---|---|
| [`install-skills.sh`](install-skills.sh) | macOS, Linux | bash 3.2+, `git`, `python3` (JSON only) |
| [`install-skills.ps1`](install-skills.ps1) | Windows, or anywhere `pwsh` runs | PowerShell 7.2+, `git` |

## One-liners

```bash
curl -fsSL https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.sh | bash
curl -fsSL https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.sh | bash -s -- -g -a
```

```powershell
irm https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.ps1 | iex
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/scripts/install-skills.ps1))) -g -a
```

From a checkout: `scripts/install-skills.sh [-a] [-g [--uninstall]]`, `./scripts/install-skills.ps1 [-a] [-g [-Uninstall]]`.

| Switch | Effect |
|---|---|
| *(none)* | install the core skills into this repo |
| `-a` | also install the optional skills, and keep them on for later runs |
| `-g` | install once per machine and link into each tool |
| `--uninstall` / `-Uninstall` | with `-g` only: remove the links this installer made |

| Variable | Default | Purpose |
|---|---|---|
| `SKILLS_REPO` | the upstream GitHub repo | clone source (URL or local path) |
| `SKILLS_BRANCH` | `main` | branch or tag to clone (`v2` follows the reusable workflow's major tag); empty = remote default |
| `SKILLS_ROOT` | *(searched)* | force the per-repo skills folder; refused with `-g` |
| `SMOOTH_AI_REVIEW_HOME` | `~/.smooth-ai-review` | the `-g` store; must be absolute |
| `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `XDG_CONFIG_HOME` | `~/.claude` / `~/.codex` / `~/.config` | where `-g` finds each tool (the tools' own variables) |

## What is owned

| Set | Skills | Installed |
|---|---|---|
| core | `ai-review`, `git-commit-review-push` | by default |
| optional | `ai-review-report`, `ai-analyse` | only with `-a` (or `installed: true` in the manifest) |

A positive allowlist, matched as whole tokens, case-sensitively, kept identical in both ports and held
together by the harness (A1–A5). Anything else in a skills folder is never listed, copied or removed.

**Why the optional pair is opt-in.** The reusable review gate (`pipeline-code-review-report.yml`) runs a
local `.agents/skills/ai-review-report` when the checkout has one, instead of the tooling it fetches at
its pinned ref; the analyse workflow does the same when `ai-review-report`, `ai-analyse` and `ai-review`
are all present. A per-repo copy therefore takes over CI and drifts unless it is re-installed. The
installer warns when it puts `ai-review-report` into `.agents/skills` of a repo whose workflows call the
reusable gate or analyse workflow.

**What an installed copy leaves out:** the skill's own `AGENTS.md` (edit-time decision history, A6),
`test-*` files, `tests/`, `run-regressions.sh`, `requirements-test.txt`, `scripts/eval/` and
`__pycache__/`. Everything else ships — `assets/`, `references/`, `agents/`, `scripts/lib/` are runtime.
The skills contain no symlinks (the harness asserts it), so a copy is self-contained.

## Per-repo install

1. **Find the skills folder** — the first existing of `.agents/skills`, `.claude/skills`, `.codex/skills`.
   None → fail and create nothing (G1). `SKILLS_ROOT` overrides.
2. **Read** `<root>/_smooth-ai-review-shared/installation.json`. Missing → first install. Empty,
   whitespace-only, unparseable or not an object → hard error naming the file, never a reset (B2).
3. **Clone** `SKILLS_REPO` at `SKILLS_BRANCH`, shallow, once (G4).
4. **Reconcile** the manifest over the owned union of what the source offers and what is already on disk:
   a new core skill joins as `true`, a new optional one as `false` (`true` with `-a`); the operator's flag
   is kept, `false` included; `-a` turns the optional skills on; names no longer owned drop out (B1).
5. **Replace** each `installed: true` skill with a fresh copy, pruned as above. A symlink at the skill's
   path (the retired npm plugin linked skills there) is replaced by the copy; its target is untouched.
6. **Write the manifest last**, keys in fixed order, `updated` in ISO-8601 UTC (B3, B5, B6).

```json
{
  "updated": "2026-10-21T13:02:24Z",
  "skills": [
    { "name": "ai-analyse", "installed": false },
    { "name": "ai-review", "installed": true },
    { "name": "ai-review-report", "installed": false },
    { "name": "git-commit-review-push", "installed": true }
  ]
}
```

**Turning a skill off:** set its `installed` to `false` and re-run. It is no longer refreshed, so local
edits survive; it is not deleted (C1). Delete the folder yourself to remove it.

## Global install (`-g`)

The store is `~/.smooth-ai-review/skills/<name>`; each installed skill is symlinked into every tool whose
config folder exists. A missing tool is skipped, never created.

| Tool | Linked into |
|---|---|
| Claude Code | `~/.claude/skills/<name>` |
| Codex | `~/.codex/skills/<name>` (its `.system/` is never touched) |
| OpenCode | `~/.config/opencode/skills/<name>` |

`~/.smooth-ai-review/installation.json` holds `updated`, `harnesses`, `skills`, `links`:

- `harnesses` is exactly `{"claude-code", "codex", "opencode"}`; a missing key joins as `true`, unknown
  keys drop (D1). `false` links nothing into that tool and removes every link there that points into the
  store — found on disk, so a lost record cannot leave a live link (D2, D3). A real folder, or a link to
  anywhere else, is never touched (D4).
- `links` records `{type, path, detail, enabled}`; `detail` is the link target and `enabled` is a status
  recomputed every run (link present and pointing at `detail`), not a control (D7).
- A link is created only when nothing is at the path. An existing correct link is kept and re-recorded;
  anything else gets a warning and is left alone.
- `--uninstall` removes every recorded link that still points where recorded, clears `links`, and keeps
  the store, the flags and `harnesses` (F8). Delete `~/.smooth-ai-review` to reclaim the space.

**No tool config file is edited.** This repo owns no rules or hooks, so there is no Codex `AGENTS.md`
block, `hooks.json` merge or `opencode.json` `instructions` entry — and nothing to snapshot or restore
(recipe section 7 does not apply). If a rule or hook is ever owned, port that machinery from
smooth-ai-product-context-memory's installer rather than writing it again.

**Sharing a machine with the sibling installers.** smooth-devex-template uses `~/.smooth-ai-devex` and
smooth-ai-product-context-memory uses `~/.smooth-ai-mimisbrunnr`. Each purges only links into its own
store, and the owned skill sets do not overlap, so all three coexist.

**Sibling skills.** `ai-review --usedecisions` resolves `../../ai-review-report` from its own folder, so
under `-g` it finds the scorer only when `-a` linked `ai-review-report` beside it; without it, it says so
and continues without recommendations.

**Reviewing from a `-g` install.** `local-review.sh` reviews the work tree it is installed in; installed
outside any repo it reviews the current directory's work tree (`lib/resolve-repo-root.sh`).
`OPENCODE_REVIEW_REPORT_REPO_ROOT` overrides both.

**Claude Code plugin users.** The marketplace plugins and a `-g` install both register the same skill
names; pick one per tool, or set `harnesses.claude-code` to `false`.

## Windows

Directory links fall back to a junction when symlinks are not permitted. The PowerShell port has been run
on macOS only; replay it on Windows before relying on it there. OpenCode's Windows config folder is
assumed to be `%USERPROFILE%\.config\opencode`.

## Testing

```bash
bash scripts/test-install-skills.sh
```

No network: the clone source is a fixture repository built from this checkout's working tree. Every case
runs in a throwaway `HOME` with the tool-location variables cleared. The bash port runs under `/bin/bash`
(3.2 on macOS). The `.ps1` and cross-port parity cases are skipped with a stated reason when `pwsh` is
absent, as on the `ubuntu-latest` runner of the blocking `opencode-v2-regressions` job. Verified: 101/101
on macOS (bash 3.2, pwsh 7.6), 53/53 in `ubuntu:24.04` without pwsh. Load-bearing lines (the on-disk purge,
`enabled` recompute, flag preservation, corrupt-manifest refusal, pruning, uninstall's target check) were
each broken in a copy and a case went red.
