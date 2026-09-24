# AI Review Report

## TL;DR

Automated, AI-driven pull-request code review. A GitHub Actions gate diffs each PR, splits the changes into context-aware chunks, and runs them through the [OpenCode](https://opencode.ai/) CLI — the provider-agnostic model transport — which calls the configured LLM at whatever endpoint the selected provider points to: a LiteLLM proxy, a provider's native API (Google Gemini, OpenAI, Anthropic), or OpenCode's own gateway (OpenCode Go). The gate then posts one consolidated review back to the PR — an executive summary plus collapsible per-chunk detail, with findings categorized by priority (Critical / High / Medium / Low). Runs automatically on PRs and on demand via `/ai-review`.

Three review skills back it:
- **`ai-review-report`** — generates the review (the CI gate; also runnable locally).
- **`ai-review`** — consumes a posted review and applies fix/skip decisions (`/ai-review`).
- **`ai-analyse`** — autonomous CI fixer for gate-authored low/medium findings (`/ai-analyse` when used interactively).

Implementation details and decisions live in [`.agents/skills/ai-review-report/SKILL.md`](.agents/skills/ai-review-report/SKILL.md).

<p align="center">
  <img src="docs/images/pipeline-overview.svg" alt="Automated AI Code Review Pipeline" width="960"/>
</p>

## Five ways to consume this repo

| Channel | What you get | Best for |
|---|---|---|
| [Reusable workflow](#use-as-a-reusable-workflow) | The CI gate via a ~80-line caller workflow; scripts fetched at run time, version-pinned | Repos that want the gate with minimal footprint and easy upgrades (`@v2`) |
| [Local-job packaging](#local-job-packaging-allowed-actions-restricted-consumers) | A consumer-side job whose only `uses:` entries are `actions/checkout` and `actions/cache` (both GitHub-owned); the gate's code is fetched at a pinned SHA. Same behavior as the reusable workflow. | Repos under `allowed_actions: "selected"` whose `generic-automation-and-it` is not on the allow-list |
| [Claude Code plugins](#install-as-a-claude-code-plugin) | A core plugin (`ai-review`, `git-commit-review-push`) plus optional plugins for `ai-review-report` and `ai-analyse` — **not** the CI gate | Developers who want the follow-up workflows by default and can opt into the heavier report/analyse skills only when needed |
| [opencode plugin (npm)](#install-as-an-opencode-plugin-npm) | The same four skills for **opencode** users — linked into `.agents/skills/` at startup, nothing vendored (GitHub Packages registry: needs a one-time `read:packages` PAT per developer) | Repos/developers driving the skills from opencode instead of Claude Code |
| [npm package in GitHub Actions](#use-in-github-actions-via-npm) | The **same npm package**, but `npm install`ed in a GHA job and run straight from `node_modules/` (no vendoring, no side checkout) | Repos that want to run the review generator in CI pinned via a package manager / lockfile |
| [Copy-install](#copy-install-vendor-everything) | Workflow + skills copied into the repo; everything editable in place | Repos that customize the gate or vendor everything |

The channels coexist: a repo can use the reusable workflow for CI while developers install the plugin for `/ai-review`. To set up a repo end-to-end (gate + skills + credentials), follow [Install into another repo (AI-agent driven)](#install-into-another-repo-ai-agent-driven) — its default path is the reusable workflow + the plugin at project scope.

## Use as a reusable workflow

Instead of copy-installing the 1,400-line gate, call it as a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows). Copy [`.docs/examples/code-review-caller.yml`](.docs/examples/code-review-caller.yml) into your repo as `.github/workflows/pipeline-code-review-report.yml` — it carries the triggers, permissions, concurrency, and the `model_preset` dispatch dropdown, and delegates the job:

```yaml
jobs:
  review:
    uses: generic-automation-and-it/smooth-ai-report-review/.github/workflows/pipeline-code-review-report.yml@v2
    with:
      pr_number: ${{ inputs.pr_number || '' }}
      model: ${{ inputs.model || '' }}
      model_preset: ${{ inputs.model_preset || '(repository default)' }}
      disable_claude_code: ${{ inputs.disable_claude_code || vars.OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE || '1' }}
      disable_agents_md_check: ${{ inputs.disable_agents_md_check || vars.OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK || '0' }}
      bypass_mandatory_context_file: ${{ inputs.bypass_mandatory_context_file || vars.OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE || '' }}
      run_on_draft: ${{ inputs.run_on_draft || vars.OPENCODE_REVIEW_REPORT_RUN_ON_DRAFT || 'false' }}
    # Explicit mapping works same-org AND cross-org. The template lists all seven keys;
    # only the selected provider's needs to exist. Same-org callers may instead use
    # `secrets: inherit`, but that fails at startup when the gate is in another org.
    secrets:
      OPENCODE_OPENAI_API_KEY: ${{ secrets.OPENCODE_OPENAI_API_KEY }}
      # … plus the other provider keys (see code-review-caller.yml)
```

How it works:
- **Scripts are fetched, not installed.** The called workflow detects that your repo has no `ai-review-report` skill and checks out this repo into a `.smooth-ai-review-tools/` side path, locked by default to the exact commit of the workflow file you called (`github.job_workflow_sha`). If your repo *does* have the skill installed (copy-install), the local copy wins — no fetch.
- **Overriding the tooling ref.** Use the `tools_ref` input or the `SMOOTH_AI_REVIEW_TOOLS_REF` Variable, and give it either a **full commit SHA** for supply-chain pinning or a **trusted floating ref** such as `main`, `latest`, or `v2` to track releases. Avoid arbitrary or untrusted branches.
- **Secrets**: map the provider keys explicitly under `secrets:` (the [caller template](.docs/examples/code-review-caller.yml) lists all seven `OPENCODE_*_API_KEY` names; only the selected provider's must exist). The explicit form works whether your repo is in the **same** org as the gate or a **different** one. `secrets: inherit` is a shorter shortcut but GitHub only honors it **same-org/enterprise** — a cross-org caller using `inherit` fails immediately with a "workflow file issue" startup error.
- **Variables**: `vars.OPENCODE_REVIEW_REPORT_*` resolve against **your** repo/org automatically — configure them exactly as in [GitHub configuration](#github-configuration); Steps 3–4 of the installer section apply unchanged. If you also copy in the optional autonomous analyse workflow, it reads `OPENCODE_ANALYSE_PROVIDER`, `OPENCODE_ANALYSE_MODEL`, `OPENCODE_ANALYSE_MAX_INCREMENTAL`, `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX`, and `OPENCODE_ANALYSE_RUN_ON_DRAFT` from the consuming repo too.
- **Inputs**: `runner` (default `ubuntu-latest`; set `self-hosted` for private-network gateways), `tools_ref`, `mandatory_context_files` / `agents_md_exempt_paths` (override the context lists without editing any workflow), `disable_claude_code`, `disable_agents_md_check`, `bypass_mandatory_context_file`, `opencode_config` (repo-relative custom `opencode.json`, LADR-047), `rtk_version`, `file_limit`, `exclude_deleted`, `exclude_generated_paths`, `run_on_draft` (review PRs while still in DRAFT — default `false`; set truthy, or set the `OPENCODE_REVIEW_REPORT_RUN_ON_DRAFT` Variable, to opt in), plus the dispatch passthroughs `pr_number` / `model` / `model_preset`.
- **Versioning**: pin `@v2` (floating major) or an exact tag/SHA. v2 is the OpenCode-v2 breaking line; v1 consumers stay on the former CLI/context/plugin contracts. The source repo maintains the floating major tag via `.github/workflows/update-major-tag.yml` on every merge to `main` (and via manual dispatch when a repair/repoint is needed) — the tag name is derived automatically from the major component of `package.json`'s version. The `model_preset` dropdown options in your caller must match the preset mapping in the called workflow — when a release adds presets, update your caller to expose them.

## Local-job packaging (allowed-actions-restricted consumers)

Some consumers cannot call the reusable workflow. GitHub Actions has two orthogonal third-party controls: an **allow-list** (`allowed_actions: "selected"`) that names which `actions/*`, `github/*`, composite, and reusable-workflow `uses:` refs are accepted, and **SHA pinning** (`sha_pinning_required: true`) that constrains the ref format. A cross-org reusable-workflow call must satisfy *both*. The allow-list is evaluated per owner/repo — `generic-automation-and-it/smooth-ai-report-review` is third-party by default, and an org admin must explicitly add it to the allow-list. A consumer that runs under `allowed_actions: "selected"` with `generic-automation-and-it` not on its list sees `startup_failure` (0 jobs) for every cross-org reusable-workflow call, even when SHA-pinning is satisfied — the two checks are independent.

If your org admin has refused or stalled the request to add `generic-automation-and-it/smooth-ai-report-review@*` to the allow-list, you need a **local-job** caller. The example [`.docs/examples/code-review-local.yml`](.docs/examples/code-review-local.yml) is a consumer-side workflow whose only `uses:` entries are `actions/checkout@<sha>` (already allow-listed by every org with `github_owned_allowed: true`), and which checks out this repo at a pinned SHA into `.review-tools/` before invoking the same [`run-review.sh`](.agents/skills/ai-review-report/scripts/run-review.sh) entrypoint the reusable-workflow packaging uses. The job body:

```yaml
jobs:
  review:
    # See the full gating in .docs/examples/code-review-local.yml
    # (dependabot + draft + /ai-review on PR + OWNER/MEMBER/COLLABORATOR).
    # This inline snippet omits the `if:` block for brevity — copy the
    # full `if:` expression from that example rather than from here.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>            # the PR
      - uses: actions/checkout@<sha>            # the gate, pinned SHA
        with:
          repository: generic-automation-and-it/smooth-ai-report-review
          ref: <pinned-sha>
          path: .review-tools
      - name: Run review gate
        env:
          REVIEW_SKILL_DIR: .review-tools/.agents/skills/ai-review-report
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}     # required — bare run: shells do not auto-inject
          # OPENCODE_REVIEW_REPORT_PROVIDER, the seven OPENCODE_*_API_KEY Secrets,
          # the per-provider URL Variables, OPENCODE_REVIEW_REPORT_MODEL_{PRIMARY,
          # SECONDARY,ORCHESTRATOR} — model IDs, one per tier. The reusable
          # caller's model_preset dropdown is not available here; set the IDs
          # directly as Variables (see Environment variables below).
          # MANDATORY_CONTEXT_FILES, AGENTS_MD_EXEMPT_PATHS,
          # OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE,
          # OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK,
          # OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE,
          # OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT,
          # OPENCODE_CLI_VERSION,
          # OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION,
          # OPENCODE_TOOL_RTK_VERSION,
          # OPENCODE_REVIEW_REPORT_CONFIG (LADR-047). See the full env:
          # block in .docs/examples/code-review-local.yml.
        run: bash "$REVIEW_SKILL_DIR/scripts/run-review.sh"
```

How it works:
- **Same behaviour, two packagings.** `run-review.sh` is the gate's single source of truth. The reusable workflow's job body is now a thin wrapper around it (checkout PR head → fetch review tooling into `.smooth-ai-review-tools/` → call `run-review.sh`). The local-job caller is the same wrapper minus the wrapping — both resolve the same env-var contract and post the same reviews.
- **`uses:` level only.** The allow-list checks `uses:` references (not the git URLs a script subsequently `git clone`s, and not action inputs). The two `actions/checkout` steps pass the allow-list; the gate's own code arrives via the second `actions/checkout`'s `ref:` (the SHA you pin) — exactly the supply-chain surface the policy is meant to govern.
- **SHA-pin everything.** The whole point of the local-job packaging is to preserve the supply-chain guarantee. Pin both `actions/checkout@<sha>` and the upstream `ref: <pinned-sha>`. The example pins the upstream ref to a specific commit; bump it in lockstep with upstream releases you want to consume. **Do not use a floating tag (`@v2`) here** — that would defeat the point.
- **Same config as the reusable caller.** `OPENCODE_REVIEW_REPORT_PROVIDER`, the seven `OPENCODE_*_API_KEY` Secrets, the per-provider URL Variables, the `OPENCODE_REVIEW_REPORT_MODEL_{PRIMARY,SECONDARY,ORCHESTRATOR}` Variables, `MANDATORY_CONTEXT_FILES`, `AGENTS_MD_EXEMPT_PATHS`, `OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE`, `OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK`, `OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE`, `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT`, `OPENCODE_REVIEW_REPORT_EXCLUDE_DELETED`, `OPENCODE_REVIEW_REPORT_EXCLUDE_GENERATED_PATHS`, `OPENCODE_CLI_VERSION`, `OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION`, `OPENCODE_TOOL_RTK_VERSION`, and `OPENCODE_REVIEW_REPORT_CONFIG` (LADR-047) are all set in the job `env:` block the same way as the reusable-workflow caller. The reusable-workflow `runner`, `tools_ref`, `mandatory_context_files`, `agents_md_exempt_paths`, and `opencode_config` inputs map to the same names as Variables — set the corresponding GitHub Variables (see [Environment variables](#environment-variables) for the full reference, e.g. `OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK`) in your repo/org; the local-job caller has no `inputs:` contract for them.
- **Three trigger shapes still supported.** The entrypoint reads `$GITHUB_EVENT_PATH` (a JSON payload GitHub writes automatically) rather than from expression interpolation, so `pull_request`, `issue_comment` with `/ai-review`, and `workflow_dispatch` all work the same way as in the reusable workflow.

### ⚠️ Security sign-off required

The local-job packaging is **technically compliant** with `allowed_actions: "selected"` and `sha_pinning_required: true` — the `uses:` references are `actions/checkout` and the third-party code is fetched at a pinned SHA. But the policy's *purpose* is to make third-party code reviewable, and a local job that fetches the same third-party code via an allow-listed `actions/checkout` step runs exactly what the policy meant to gate. The local-job packaging is **contrary to the spirit of the allow-list policy**, even though it passes the letter. Before adopting it:

- Confirm with your org/enterprise admin that adding `generic-automation-and-it/smooth-ai-report-review@*` to the allow-list is not an option (the allow-list exists for reviewability; this packaging opts out of that reviewability).
- Document the deviation in your security sign-off: the upstream repo, the pinned SHA, the audit trail for the pin choice, and the monitoring story for upstream changes.
- Pin the upstream `ref:` to a **specific commit SHA**, not a tag — and bump it as a deliberate, reviewable change rather than auto-updating.

If your org admin can add the allow-list entry, prefer the [reusable workflow](#use-as-a-reusable-workflow) — it is materially easier to audit (one `uses:` line, one org-level review) and matches the policy's intent.

## Install as a Claude Code plugin

This repo's Claude marketplace is intentionally split:
- **`smooth-ai-review`** is the default/core plugin and includes `ai-review` plus `git-commit-review-push`.
- **`smooth-ai-review-report`** is an optional add-on for the review generator / local driver.
- **`smooth-ai-analyse`** is an optional add-on for the autonomous low/medium fixer.

Install the marketplace, then install the core plugin:

```
/plugin marketplace add generic-automation-and-it/smooth-ai-report-review
/plugin install smooth-ai-review@smooth-ai-report-review
```

Optional installs when you want the heavier review-generator skills inside Claude Code too:

```bash
/plugin install smooth-ai-review-report@smooth-ai-report-review
/plugin install smooth-ai-analyse@smooth-ai-report-review
```

That installs at **user scope** (your machine, all repos). To tie the default follow-up skills to one repo for every collaborator instead, enable the core plugin at **project scope** in that repo's `.claude/settings.json` — see [Step 2 of the installer](#step-2--enable-the-skills-repo-locally-plugin-project-scope). Add the optional plugins there too only if that repo wants local report generation and/or `/ai-analyse`.

Notes:
- The plugin installs **skills only** — it does **not** install the CI gate. Pair it with the [reusable workflow](#use-as-a-reusable-workflow) (or the copy-installer) for PR-gate coverage.
- When running from the plugin, skill scripts live under the plugin install dir: substitute `${CLAUDE_PLUGIN_ROOT}/.agents/skills/<skill>` wherever a skill doc says `.agents/skills/<skill>` (the `ai-review` skill documents this in its SKILL.md).
- The marketplace entries load skills straight from `.agents/skills/` (the canonical location) via explicit `skills` paths in `.claude-plugin/marketplace.json` — no `skills/` symlink involved, so the plugin install works on Windows without symlink support.

## Install as an opencode plugin (npm)

OpenCode has no skill marketplace — it discovers skills only from fixed directories (`.agents/skills/`, `.claude/skills/`, `.opencode/skills/`) — but it auto-installs npm plugins. The package **`@generic-automation-and-it/smooth-ai-review` v2** implements the OpenCode v2 plugin contract: at startup it links the four skills into your repo's `.agents/skills/`, so native discovery (and every `.agents/skills/...` path the skill docs reference) just works, with nothing vendored. It ships **skills only and declares no dependencies** — it does not install or bundle the opencode CLI, which you install yourself. Package major v1 is for OpenCode v1 and does not execute on OpenCode v2.

The package is hosted on the **GitHub Packages npm registry**, which [requires authentication even for public packages](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry) — each developer needs a one-time setup:

1. Create a GitHub personal access token (classic) with the **`read:packages`** scope.
2. Add the registry mapping + token to your **user** `~/.npmrc` (not the repo's — the token must never be committed):

   ```ini
   @generic-automation-and-it:registry=https://npm.pkg.github.com
   //npm.pkg.github.com/:_authToken=ghp_YOUR_TOKEN
   ```

Then add one line to the consuming repo's `opencode.json`:

```json
{ "plugins": ["@generic-automation-and-it/smooth-ai-review"] }
```

How it works:
- opencode `bun install`s the package at startup (cached in `~/.cache/opencode/`) — Bun honors the `~/.npmrc` registry + token mapping. The plugin then creates `.agents/skills/{ai-review-report,ai-review,ai-analyse,git-commit-review-push}` as directory links into that cache (junction links — no admin rights needed on Windows).
- **Vendored copies always win**: if a skill already exists as a real directory (copy-install), the plugin never touches it. Stale links (e.g. after a package update moved the cache) are re-pointed automatically.
- Your `git status` stays clean: the link paths are appended to `.git/info/exclude` (local-only — your `.gitignore` is never edited).
- The package ships the skills **without** the eval harness (`scripts/eval/` is excluded).
- Like the Claude Code plugin, this installs **skills only** — pair it with the [reusable workflow](#use-as-a-reusable-workflow) for the CI gate (the gate itself never needs this plugin; in reusable mode it fetches its own scripts).
- If the skills don't appear in the very first session after install, restart opencode once — the links are created at session init.

## Use in GitHub Actions via npm

The [opencode plugin package](#install-as-an-opencode-plugin-npm) `@generic-automation-and-it/smooth-ai-review` ships the full skill trees (`.agents/skills/…`, minus the eval harness) in its tarball — not just the opencode startup hook. That means you can `npm install` it in a GitHub Actions job and run the review scripts straight out of `node_modules/`, with **nothing vendored** into your repo and **no side checkout**. This is a distinct consumption path from the [reusable workflow](#use-as-a-reusable-workflow) (which fetches scripts into `.smooth-ai-review-tools/` at run time); the reusable workflow stays the recommended default and needs no registry auth.

Ready-to-copy workflow: [`.docs/examples/npm-review-report-gha.yml`](.docs/examples/npm-review-report-gha.yml). It installs the package + the opencode CLI, then runs the `ai-review-report` generator (`local-review.sh --pr <n> --post`) against the PR.

Key points specific to the npm-in-CI path:
- **Registry auth.** The package lives on the GitHub Packages npm registry, which requires a token even though it's public. Same-org runs can use the run-scoped `GITHUB_TOKEN` (grant `packages: read` in the workflow's `permissions:`). Cross-org runs must supply a classic PAT with the `read:packages` scope as a secret — the example reads `PACKAGES_READ_TOKEN` and falls back to `GITHUB_TOKEN`.
- **Repo-root override.** The scripts normally derive the repo under review from their own location. Run from `node_modules/`, that would point at the package, so set **`OPENCODE_REVIEW_REPORT_REPO_ROOT: ${{ github.workspace }}`** (see the [Environment variables](#environment-variables) table). The example does this.
- **Prerequisites** match [Using Local Report](#using-local-report): install the OpenCode v2 CLI through the shared `lib/install-opencode.sh` used by the ready-to-copy workflow, plus `jq` and `gh` (both preinstalled on `ubuntu-latest`) and the selected provider's credentials/model vars — configure them exactly as for the gate.
- **Versioning.** Pin an exact v2 version (`npm i @generic-automation-and-it/smooth-ai-review@2.0.0`) for reproducible reviews; the runtime publish numbering makes every published version immutable.
- **`ai-analyse`** ships in the same tarball (its `SKILL.md`/`AGENTS.md` plus the shared `ai-review-report/scripts/lib/` helpers it reuses — it has no standalone scripts of its own). Its autonomous fix loop is orchestrated by `.github/workflows/pipeline-ai-analyse.yml`, so consume it by copy-installing that workflow rather than a single CLI entrypoint.
- Like the plugins, this installs **review tooling only** — it does not register the `/ai-review` or `/ai-analyse` skills into Claude Code/opencode; use the plugin channels for that.

## Install into another repo (AI-agent driven)

These steps are written for an **AI coding agent running in the _target_ repo**. Point it at this README — best via the **raw** URL (`https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/README.md`), which returns clean Markdown; a `blob/…#install-into-another-repo-ai-agent-driven` link also works but serves HTML.

The default install vendors **nothing**: the CI gate comes in as a thin [reusable-workflow](#use-as-a-reusable-workflow) caller, and the skills come in as the [Claude Code plugin](#install-as-a-claude-code-plugin) enabled **repo-locally** (project scope — the skills follow the repo for every collaborator, not one developer's machine). To copy the full workflow and skill trees into the repo instead, use [Copy-install (vendor everything)](#copy-install-vendor-everything).

> **If you are that AI agent and the operator said "install this":** execute Steps 1–2 below **now**, in the current repository — do not merely summarize them. Run them from the repo root. Do **not** enter any API key yourself: stop at Step 3, ask the operator which provider to use, and output the exact Secret/Variable names for them to set.

**Source repo:** `generic-automation-and-it/smooth-ai-report-review` (branch `main`).

**What gets installed:**
1. **Remote report**: a ~80-line caller workflow → `.github/workflows/pipeline-code-review-report.yml`, delegating to this repo's reusable gate at `@v2` (the floating major tag is maintained from this repo's `main` branch; review scripts are fetched at run time — no skill trees land in the repo).
2. **Local follow-up tooling**: the `smooth-ai-review` plugin (the core `ai-review` + `git-commit-review-push` skills) enabled at **project scope** in `.claude/settings.json` — collaborators who trust the repo folder are prompted to install it automatically.
3. **Optional local extras**: if the repo also wants the local review generator and/or autonomous fixer in Claude Code, enable `smooth-ai-review-report` and/or `smooth-ai-analyse` from the same marketplace.

**Choosing a different channel:** Steps 1–2 are the default (reusable workflow + plugin). If the target repo needs a different shape — an allow-list-restricted org, an opencode-driven team, or a package-manager-pinned CI job — pick the channel from [Five ways to consume this repo](#five-ways-to-consume-this-repo) first; each row links a ready-to-copy example under `.docs/examples/`.

### Step 1 — install the review gate (reusable-workflow caller)

Run this **from the target repo's root**. If a previous **copy-installed** gate exists (the full 1,400-line workflow), it is stashed for diffing and replaced by the caller:

```bash
set -e
command -v git >/dev/null || { echo "✗ git not found"; exit 1; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ run this inside the target git repository"; exit 1; }
cd "$ROOT"

WF=".github/workflows/pipeline-code-review-report.yml"

# Stash any prior gate (copy-installed or older caller) for delta analysis and
# remember its runs-on so a self-hosted runner choice survives the migration.
PREV_SAVE="$(git rev-parse --git-dir)/ci-prev-workflow.yml"
OLD_RO=""
if [ -f "$WF" ]; then
  cp "$WF" "$PREV_SAVE"
  OLD_RO="$(grep -m1 -E '^[[:space:]]*runs-on:' "$PREV_SAVE" | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//')"
fi

mkdir -p .github/workflows
curl -fsSL "https://raw.githubusercontent.com/generic-automation-and-it/smooth-ai-report-review/main/.docs/examples/code-review-caller.yml" -o "$WF"

grep -q 'smooth-ai-report-review/.github/workflows/pipeline-code-review-report.yml@' "$WF" \
  && echo "✓ caller workflow installed at $WF" \
  || { echo "✗ caller download failed or incomplete"; exit 1; }

case "$OLD_RO" in
  ''|ubuntu-latest|*'{{'*) ;;  # nothing to carry over
  *) echo "↻ previous gate ran on '$OLD_RO' — set \"runner: $OLD_RO\" under the caller's with: block" ;;
esac
```

**If the caller fails at startup with a workflow-file error**, the target org almost certainly runs `allowed_actions: "selected"` without `generic-automation-and-it/*` on the allow-list — GitHub refuses the cross-org `uses:` before the job starts, so nothing in the gate ever executes and there is no log to read. Two routes: ask the org admin to allow-list `generic-automation-and-it/smooth-ai-report-review@*`, or switch to the [local-job packaging](#local-job-packaging-allowed-actions-restricted-consumers) — [`.docs/examples/code-review-local.yml`](.docs/examples/code-review-local.yml), same review behaviour, whose only `uses:` entries are `actions/checkout` and `actions/cache`, with the gate's code fetched at a pinned SHA. Replace `$WF` with that file instead of the caller and bump its pinned SHA to the ref you want.

**If `$PREV_SAVE` was created**, the repo is migrating from a copy-install: show the operator `diff -u "$PREV_SAVE" "$WF"`, re-express any prior workflow customizations as caller inputs (`runner`, `tools_ref`, `mandatory_context_files`, `agents_md_exempt_paths`, `disable_agents_md_check`, `bypass_mandatory_context_file`), and offer to delete the now-redundant vendored skill trees (`<skills-dir>/ai-review-report` and `<skills-dir>/ai-review`) — the reusable gate fetches its own scripts. Leaving them in place also works: same-repo PRs prefer a local skill tree over the fetched one, while fork PRs force pinned fetched tooling. The same local-then-fetched precedence applies to `pipeline-ai-analyse.yml` when it is copied into the consumer repo.

### Step 2 — enable the skills repo-locally (plugin, project scope)

Register the marketplace and enable the plugin in the target repo's `.claude/settings.json` so the skills are tied to the repo — every collaborator who trusts the folder is prompted to install them:

```bash
set -e
command -v jq >/dev/null || { echo "✗ jq needed to merge .claude/settings.json"; exit 1; }
mkdir -p .claude
SETTINGS=.claude/settings.json
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq '.extraKnownMarketplaces["smooth-ai-report-review"] =
      {"source":{"source":"github","repo":"generic-automation-and-it/smooth-ai-report-review"}}
    | .enabledPlugins["smooth-ai-review@smooth-ai-report-review"] = true' \
  "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "✓ smooth-ai-review plugin enabled at project scope ($SETTINGS)"
```

Notes:
- Interactive equivalent (from inside Claude Code in the repo): `/plugin marketplace add generic-automation-and-it/smooth-ai-report-review`, then `claude plugin install smooth-ai-review@smooth-ai-report-review --scope project`.
- Optional project-scope add-ons: `claude plugin install smooth-ai-review-report@smooth-ai-report-review --scope project` and `claude plugin install smooth-ai-analyse@smooth-ai-report-review --scope project`.
- For a **global** (all-repos, single-developer) install use user scope instead — see [Install as a Claude Code plugin](#install-as-a-claude-code-plugin). Project scope is the default here because the review skills belong with the repo.
- Commit both artifacts: the caller workflow and `.claude/settings.json`.

### Step 2b — local report behavior for AI agents

This is the local counterpart to the remote CI report. The generator is **`ai-review-report`**, not `/ai-review` (which consumes an already-posted review).

If the operator asks for a local/localized report, invoke:

```text
ai-review-report --local
```

Bare `--local` is fully specified. Do **not** ask for a PR number, provider, post mode, or base branch unless the operator explicitly asks for a non-default. It means:
- review HEAD/current branch against `main`
- do not post back to GitHub
- use `OPENCODE_REVIEW_REPORT_PROVIDER` from the shell if set, otherwise `OPENAI`
- use the local runner's model defaults unless `--model` or model env vars are supplied

For direct shell execution in a copy-installed repo, the equivalent is:

```bash
.agents/skills/ai-review-report/scripts/local-review.sh
```

Local reports need local credentials and tools. At minimum for the default OpenAI provider:

```bash
export OPENCODE_OPENAI_API_KEY="..."
export OPENCODE_REVIEW_REPORT_OPENAI_URL="https://api.openai.com/v1"
```

Also ensure `opencode` and `jq` are installed locally. `gh` is only needed for local `--pr NUMBER` metadata fetches or `--post`.

For a non-default local provider, export `OPENCODE_REVIEW_REPORT_PROVIDER`, the selected provider's API key, gateway URL when applicable, and three model variables listed in [Step 3](#step-3--ask-which-provider-then-output-the-config-to-add), but as shell environment variables instead of GitHub Secrets/Variables.

### Copy-install (vendor everything)

Use this **instead of Steps 1–2** only when the target repo must edit the gate or skills in place. It copies the full workflows plus the three review skills out of this repo; Steps 3–4 below apply afterwards exactly the same.

**What gets installed:**
1. The gate workflow → `.github/workflows/pipeline-code-review-report.yml`.
2. The autonomous analyse workflow → `.github/workflows/pipeline-ai-analyse.yml`.
3. The `ai-review-report` skill → `<skills-dir>/ai-review-report/`, **excluding `scripts/eval/`** (the eval harness is for developing this skill, not for running the gate).
4. The `ai-review` skill → `<skills-dir>/ai-review/` (the local `/ai-review` companion that **consumes** a posted review and applies fix/skip decisions).
5. The `ai-analyse` skill → `<skills-dir>/ai-analyse/` (the autonomous low/medium fixer used by the analyse workflow and discoverable as `/ai-analyse`).

> **One skills dir, no per-agent copies or symlinks.** All review skills install into a single `<skills-dir>`, chosen by priority — the first existing of `.agents/skills`, `.ai/skills`, `.claude/skills`, `.codex/skills`; if none exist, `.agents/skills`. Because the workflows call scripts by path, when `<skills-dir>` is **not** `.agents/skills` the script repoints hardcoded `.agents/skills/ai-review…` and `.agents/skills/ai-analyse…` references to the chosen dir; target-repo context paths (`.agents/rules/…`, `.docs/…`, `code-review-standards`) are left untouched. The scripts find their own siblings by relative path, so they work unchanged from any of these dirs.

Run this **from the target repo's root**. It refuses to run anywhere else, detects whether the gate already exists (→ `update`) or not (→ `install`), copies the files, and verifies the result — failing loudly on a partial copy. On **update** it finds a prior gate under either the canonical `pipeline-…` or the legacy `pipline-…` filename, carries over your existing `runs-on`, replaces the legacy name with the canonical one, and prints the old→new workflow diff for review.

```bash
set -e

# Preflight: must be inside the target git repo, with git available.
command -v git >/dev/null || { echo "✗ git not found"; exit 1; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ run this inside the target git repository"; exit 1; }
cd "$ROOT"

WF=".github/workflows/pipeline-code-review-report.yml"    # canonical gate name
ANALYSE_WF=".github/workflows/pipeline-ai-analyse.yml"    # autonomous low/medium fixer
WF_OLD=".github/workflows/pipline-code-review-report.yml" # legacy typo'd name from older installs

# Pick the ONE skills dir to install into, by priority: the first that already
# exists, else .agents. No per-agent copies or symlinks are created.
DEST=".agents"
for d in .agents .ai .claude .codex; do
  if [ -d "$d/skills" ]; then DEST="$d"; break; fi
done
echo "Skills dir: $DEST/skills"

# Find an existing gate (canonical OR legacy name) and stash it for delta analysis.
PREV=""
for w in "$WF" "$WF_OLD"; do [ -f "$w" ] && { PREV="$w"; break; }; done
PREV_SAVE="$(git rev-parse --git-dir)/ci-prev-workflow.yml"
[ -n "$PREV" ] && cp "$PREV" "$PREV_SAVE"

# Detect install vs update: update if a prior gate OR skill tree exists.
if [ -n "$PREV" ] || [ -d "$DEST/skills/ai-review-report" ] || [ -d "$DEST/skills/ai-review" ] || [ -d "$DEST/skills/ai-analyse" ]; then
  MODE="update"
else
  MODE="install"
fi
echo "Mode: $MODE"

# Fetch the source (public repo; --depth 1 is enough).
SRC="$(mktemp -d)"
git clone --depth 1 https://github.com/generic-automation-and-it/smooth-ai-report-review.git "$SRC"

# On update, remove existing skill trees first so files deleted upstream don't linger.
if [ "$MODE" = update ]; then
  rm -rf "$DEST/skills/ai-review-report" "$DEST/skills/ai-review" "$DEST/skills/ai-analyse"
fi

# 1) workflows → canonical names; drop any legacy typo'd gate so there's exactly one gate.
mkdir -p .github/workflows
cp "$SRC/$WF" "$WF"
cp "$SRC/$ANALYSE_WF" "$ANALYSE_WF"
[ -f "$WF_OLD" ] && rm -f "$WF_OLD"

# 2) the three review skills — into the chosen dir
mkdir -p "$DEST/skills"
cp -R "$SRC/.agents/skills/ai-review-report" "$DEST/skills/"
cp -R "$SRC/.agents/skills/ai-review"        "$DEST/skills/"
cp -R "$SRC/.agents/skills/ai-analyse"       "$DEST/skills/"

# exclude the eval harness — not needed to run the gate
rm -rf "$DEST/skills/ai-review-report/scripts/eval"

# 3) when NOT installing under .agents, repoint the gate's hardcoded skill paths
#    (the workflow's refs + prepare-opencode-config.sh's opencode.json path) at $DEST.
#    Scoped to the literal '.agents/skills/ai-review' so target-repo context paths
#    (.agents/rules/…, .docs/…, code-review-standards) are left untouched.
if [ "$DEST" != ".agents" ]; then
  command -v perl >/dev/null || { echo "✗ perl needed to repoint paths for $DEST/skills"; exit 1; }
  # The 'unless' guard skips the workflow's reusable-mode lines (the
  # .smooth-ai-review-tools side-checkout path) — dead code in a copy-install,
  # and rewriting them would corrupt the fetched-tooling path.
  find "$WF" "$ANALYSE_WF" "$DEST/skills/ai-review-report" "$DEST/skills/ai-review" "$DEST/skills/ai-analyse" -type f \
    -exec perl -i -pe "unless (m{\.smooth-ai-review-tools}) { s{\.agents/skills/ai-review}{$DEST/skills/ai-review}g; s{\.agents/skills/ai-analyse}{$DEST/skills/ai-analyse}g; }" {} +
fi

# 4) update only: carry over the previous gate's runs-on (e.g. self-hosted) and show the delta
#    so the agent can ask the operator which other prior customizations to re-introduce.
if [ "$MODE" = update ] && [ -n "$PREV" ]; then
  command -v perl >/dev/null || { echo "✗ perl needed to preserve runs-on"; exit 1; }
  OLD_RO="$(grep -m1 -E '^[[:space:]]*runs-on:' "$PREV_SAVE" | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//')"
  if [ -n "$OLD_RO" ]; then
    OLD_RO="$OLD_RO" perl -i -pe 'if(!$d && /^(\s*)runs-on:/){$_="$1runs-on: $ENV{OLD_RO}\n";$d=1}' "$WF"
    echo "↻ carried over previous runs-on: $OLD_RO"
  fi
  echo "=== Δ previous gate ($PREV) → new gate (runs-on already merged) ==="
  diff -u "$PREV_SAVE" "$WF" || true
  echo "(previous workflow saved at $PREV_SAVE)"
fi

rm -rf "$SRC"

# Verify — fail loudly on a partial copy instead of reporting success.
# Assert a deep runtime script too (not just SKILL.md): the gate's first call is
# prepare-opencode-config.sh, so a truncated copy must fail HERE, not on the runner.
test -f "$WF" \
 && test -f "$ANALYSE_WF" \
 && test -f "$DEST/skills/ai-review-report/SKILL.md" \
 && test -f "$DEST/skills/ai-review/SKILL.md" \
 && test -f "$DEST/skills/ai-analyse/SKILL.md" \
 && test -f "$DEST/skills/ai-review-report/scripts/lib/prepare-opencode-config.sh" \
 && test ! -e "$DEST/skills/ai-review-report/scripts/eval" \
 && echo "✓ $MODE complete ($DEST/skills)" || { echo "✗ install incomplete — check output above"; exit 1; }
```

**Then message the operator using `$MODE`:**
- `install` → "**Installed** the AI review gate and analyse workflow (`ai-review-report`, `ai-review`, and `ai-analyse` under `$DEST/skills`)."
- `update` → "**Updated** the existing AI review gate." The block printed an old→new workflow **diff** and already carried over your previous `runs-on`. **Present that diff to the operator as a table** — columns `id | change` — and **ask which of the remaining old customizations to re-introduce** into the new workflow before committing (the freshly-copied file is canonical otherwise; a legacy `pipline-…` gate is replaced by the canonical `pipeline-…` name). Then have them review `git diff` before committing — an update can change workflow steps, scripts, or the `opencode.json` provider config.

> The workflow's `MANDATORY_CONTEXT_FILES` list points at product-repo paths (e.g. `.docs/nfr/…`, `.agents/rules-scoped/backend/…`). Any that don't exist in the target **warn-and-skip** — the gate still runs. To match the target repo's real context files, pass the `mandatory_context_files` input (reusable call or manual dispatch) rather than editing the workflow — or `none` when the repo has no mandatory context files. The local-job packaging reads the `MANDATORY_CONTEXT_FILES` Variable instead, which accepts the same values.

### Step 3 — ask which provider, then output the config to add

Applies to both the default install and the copy-install. **Ask the operator which model provider to use**, then tell them exactly which GitHub **Secrets** and **Variables** to add under **Settings → Secrets and variables → Actions**. Resolve their answer against this matrix:

| Provider chosen | Add Secret (API key) | Add Variables |
|---|---|---|
| **OpenAI** _(default)_ | `OPENCODE_OPENAI_API_KEY` | **`OPENCODE_REVIEW_REPORT_OPENAI_URL` is required** (e.g. `https://api.openai.com/v1`, or your LiteLLM proxy) — the model chain already defaults to `gpt-5.6-sol` / `gpt-5.5` / `gpt-5.6-terra`, so no `OPENCODE_REVIEW_REPORT_MODEL_*` Variable is needed unless you retune |
| **Gemini** | `OPENCODE_GEMINI_API_KEY` | `OPENCODE_REVIEW_REPORT_PROVIDER=GEMINI`; `OPENCODE_REVIEW_REPORT_GEMINI_URL` (e.g. `https://generativelanguage.googleapis.com/v1beta/openai`); `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=gemini-3.1-pro-preview`; `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=gemini-2.5-pro`; `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=gemini-3-flash-preview` |
| **Anthropic** | `OPENCODE_ANTHROPIC_API_KEY` | `OPENCODE_REVIEW_REPORT_PROVIDER=ANTHROPIC`; `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=claude-opus-4-8`; `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=claude-sonnet-4-6`; `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=claude-haiku-4-5` — **no URL Variable** (base URL hardcoded) |
| **OpenCode Go — OpenAI** | `OPENCODE_GO_OPENAI_API_KEY` | `OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-OPENAI`; `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=deepseek-v4-pro`; `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=deepseek-v4-flash`; `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=glm-5.1` — **no URL Variable** (base URL hardcoded) |
| **OpenCode Go — Anthropic** | `OPENCODE_GO_ANTHROPIC_API_KEY` | `OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-ANTHROPIC`; `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=qwen3.7-plus`; `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=minimax-m2.7`; `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=minimax-m3` — **no URL Variable** (base URL hardcoded) |
| **OpenCode Go — Responses** | `OPENCODE_GO_OPENAI_API_KEY` | `OPENCODE_REVIEW_REPORT_PROVIDER=OPENCODE-GO-RESPONSES`; `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=gpt-5.6-luna`; `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=grok-4.6`; `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=muse-spark-1.3-contributor` — **no URL Variable** (base URL hardcoded) |
| **OpenRouter** | `OPENCODE_OPENROUTER_API_KEY` | `OPENCODE_REVIEW_REPORT_PROVIDER=OPEN_ROUTER`; `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY=deepseek/deepseek-v4-pro`; `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY=qwen/qwen3.7-plus`; `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR=deepseek/deepseek-v4-flash` — **no URL Variable** (base URL hardcoded). Models use a `vendor/` prefix; no Anthropic/OpenAI models declared. |

The agent must state these rules when emitting the config:
- **API keys are Secrets; everything else is a Variable.** Never store a key as a Variable (Variables are plaintext and printable in logs).
- **Any non-OpenAI provider MUST set all three `OPENCODE_REVIEW_REPORT_MODEL_*` Variables.** The defaults are OpenAI model IDs and the run **fails fast** if a mismatched model is left on another provider.
- **`GEMINI`, `COPILOT` and `OPENAI` each require their `OPENCODE_REVIEW_REPORT_<P>_URL` Variable.** Only `ANTHROPIC`, the OpenCode Go surfaces and `OPEN_ROUTER` have a hardcoded base; for the other three an unset URL Variable aborts the run at preflight.
- Offer the equivalent `gh` commands rather than only describing the UI — copy-paste blocks per provider below (run inside the target repo, or add `--repo <owner>/<repo>`; `gh secret set` without a value prompts for it).

  **OpenAI** _(default)_
  ```bash
  gh secret set OPENCODE_OPENAI_API_KEY
  # required — OPENAI has no hardcoded base URL:
  gh variable set OPENCODE_REVIEW_REPORT_OPENAI_URL --body "https://api.openai.com/v1"
  # the model chain already defaults to gpt-5.6-sol / gpt-5.5 / gpt-5.6-terra;
  # set these only to retune:
  # gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body gpt-5.6-sol
  # gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body gpt-5.5
  # gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body gpt-5.6-terra
  ```

  **Gemini**
  ```bash
  gh secret set OPENCODE_GEMINI_API_KEY
  gh variable set OPENCODE_REVIEW_REPORT_PROVIDER --body GEMINI
  gh variable set OPENCODE_REVIEW_REPORT_GEMINI_URL --body "https://generativelanguage.googleapis.com/v1beta/openai"
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body gemini-3.1-pro-preview
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body gemini-2.5-pro
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body gemini-3-flash-preview
  ```

  **Anthropic**
  ```bash
  gh secret set OPENCODE_ANTHROPIC_API_KEY
  gh variable set OPENCODE_REVIEW_REPORT_PROVIDER --body ANTHROPIC
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body claude-opus-4-8
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body claude-sonnet-4-6
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body claude-haiku-4-5
  # no URL Variable — the Anthropic base URL is hardcoded
  ```

  **OpenCode Go — OpenAI**
  ```bash
  gh secret set OPENCODE_GO_OPENAI_API_KEY
  gh variable set OPENCODE_REVIEW_REPORT_PROVIDER --body OPENCODE-GO-OPENAI
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body deepseek-v4-pro
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body deepseek-v4-flash
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body glm-5.1
  # no URL Variable — the Zen base URL is hardcoded
  ```

  **OpenCode Go — Anthropic**
  ```bash
  gh secret set OPENCODE_GO_ANTHROPIC_API_KEY
  gh variable set OPENCODE_REVIEW_REPORT_PROVIDER --body OPENCODE-GO-ANTHROPIC
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body qwen3.7-plus
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body minimax-m2.7
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body minimax-m3
  # no URL Variable — the Zen base URL is hardcoded
  ```

  **OpenCode Go — Responses**
  ```bash
  gh secret set OPENCODE_GO_OPENAI_API_KEY
  gh variable set OPENCODE_REVIEW_REPORT_PROVIDER --body OPENCODE-GO-RESPONSES
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body gpt-5.6-luna
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body grok-4.6
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body muse-spark-1.3-contributor
  # no URL Variable — the Zen base URL is hardcoded
  ```

  **OpenRouter**
  ```bash
  gh secret set OPENCODE_OPENROUTER_API_KEY
  gh variable set OPENCODE_REVIEW_REPORT_PROVIDER --body OPEN_ROUTER
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_PRIMARY --body deepseek/deepseek-v4-pro
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_SECONDARY --body qwen/qwen3.7-plus
  gh variable set OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR --body deepseek/deepseek-v4-flash
  # no URL Variable — the OpenRouter base URL is hardcoded
  ```

### Step 4 — repo settings (one-time)

- **Settings → Actions → General → Workflow permissions → enable "Allow GitHub Actions to create and approve pull requests."** Without it, a clean full review fails when the gate tries to approve. (An org-level policy can force this off and override the repo toggle.)
- The chosen provider's gateway must be **reachable from GitHub-hosted `ubuntu-latest`** — publicly routable, not VPN-only. For a private-network gateway, use a `self-hosted` runner: the caller's `runner:` input (default install) or the workflow's `runs-on` (copy-install).

Then open a PR (or comment `/ai-review` on one) to trigger the gate. Full variable reference is in [Environment variables](#environment-variables); per-provider detail in [Providers](#providers).

## Review states

| State | When it happens | Outcome |
|---|---|---|
| **Full review** | First review on a PR, an `/ai-review` comment, a re-requested review, or a manual dispatch | Reviews the entire diff against the merge base. Can **approve**, **request changes**, or comment — and clears any prior blocking state. |
| **Incremental review** | Later pushes to an already-reviewed PR | Reviews only the new commits since the last reviewed commit. **Never approves** — posts comments only. |
| **Full review blocked — documentation gate failed** | A full-review PR adds/modifies **no** `*AGENTS.md`, `README.md`, or `SKILL.md`, or introduces a new `*AGENTS.md` that fails the naming/template rules (all changed files exempt-path is excused) | The gate blocks instead of reviewing and posts guidance describing the missing or invalid documentation. |
| **Review bypassed — changes already requested** | The bot already has an open *changes requested* review | Incremental reviews skip (the existing block stands until addressed). A new **full** review still runs and can clear it. |

For a one-run scope override, comment on the PR: `/ai-review --file-limit 5 --exclude-deleted --exclude-generated generated/`. Repeat `--exclude-generated` for additional exact paths or directory prefixes. These trusted-comment switches override repository Variables only for that run.

## Requirements

- A GitHub-hosted `ubuntu-latest` runner. The model gateway for the selected provider (e.g. `OPENCODE_REVIEW_REPORT_GEMINI_URL`) must be reachable from GitHub-hosted runners — i.e. publicly routable, not VPN-only. (If the gateway is private-network only, switch the workflow's `runs-on` back to `self-hosted`.)
- **Allow GitHub Actions to approve PRs.** Enable repo (or org) **Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests."** Without it, a clean full review fails when the gate tries to approve (`GitHub Actions is not permitted to approve pull requests`). An org-level policy can force this off and overrides the repo toggle.
- Gateway config for the selected provider (default `OPENAI`): the API key as a GitHub **Secret** (`OPENCODE_OPENAI_API_KEY`) and the gateway URL as a **Variable** (`OPENCODE_REVIEW_REPORT_OPENAI_URL`); optional **Variables** `OPENCODE_REVIEW_REPORT_PROVIDER` (to switch provider), `OPENCODE_REVIEW_REPORT_MODEL_*` (to retune the model chain), and `OPENCODE_CLI_VERSION` (pin OPENCODE CLI; unset = reuse an existing v2 installation, or install the latest v2 release when none is available) without editing the workflow. See [Environment variables](#environment-variables) for the complete list and [Providers](#providers) for the per-provider breakdown.

> **Breaking v2 migration:** set the `OPENCODE_CLI_VERSION` repo/org Variable to a specific **2.x** release (for example `2.0.11`). A stale 1.x pin now fails fast. Unset means "any v2": on a fresh GitHub-hosted runner that is the latest v2 release, but on a machine that already has a v2 binary on `PATH` (local runs, self-hosted runners) the installer keeps it as is, so an unpinned install can quietly stay on an older 2.x — another reason to pin. All four install paths — the gate, `ai-analyse`, the eval harness, and the npm consumer template — honor the pin through the shared v2 installer ([`lib/install-opencode.sh`](.agents/skills/ai-review-report/scripts/lib/install-opencode.sh) — see LADR-087). Standard `AGENTS.md` scope is loaded natively by v2; custom `*_AGENTS.md`, `.agents/rules/**/*.md` and `.github/instructions/**/*.instructions.md` stay on the gate's explicit context path because v2's schema accepts but does not yet resolve the `instructions` array. `.agents/rules-scoped/**` is deliberately not in that array — scope it per run through `MANDATORY_CONTEXT_FILES` instead. RTK remains installed and version-visible on v2, but plugin initialization is bypassed until the installed release advertises `--opencode-v2`; that future integration activates automatically.

> **Version-pin Variable naming convention.** `OPENCODE_CLI_VERSION` (no `REVIEW_REPORT_` prefix) pins the opencode core binary the gate actually runs. `OPENCODE_TOOL_<NAME>_VERSION` pins ancillary tools the gate installs alongside it — `OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION` (LADR-049), `OPENCODE_TOOL_RTK_VERSION` (LADR-054), future additions. Behaviour toggles like `OPENCODE_REVIEW_REPORT_ENABLE_RTK` stay in the gate-level `OPENCODE_REVIEW_REPORT_*` namespace — they are review-gate config, not tool pins.

## Providers

OpenCode is provider-agnostic — the committed config ([`.agents/skills/ai-review-report/assets/opencode.json`](.agents/skills/ai-review-report/assets/opencode.json)) defines the providers OpenCode can route to. Each provider reads its gateway URL and API key from environment variables (`{env:...}` substitution), so credentials never live in the repo.

| Provider | Status | Models | Env vars (gateway URL + key) |
|---|---|---|---|
| **Gemini** (`gemini`, `@ai-sdk/google`) | Optional | `gemini-3.1-pro-preview`, `gemini-2.5-pro`, `gemini-3-flash-preview`, `gemini-2.5-flash` | `OPENCODE_REVIEW_REPORT_GEMINI_URL`, `OPENCODE_GEMINI_API_KEY` |
| **OpenAI** (`openai`, `@ai-sdk/openai`) | Default — the model chain points here | `gpt-6-sol-2026-09-22`, `gpt-6-luna-2026-09-22`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` | `OPENCODE_REVIEW_REPORT_OPENAI_URL`, `OPENCODE_OPENAI_API_KEY` |
| **Anthropic** (`anthropic`, `@ai-sdk/anthropic`) | Optional — direct Anthropic API (Claude models) | `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5` | `OPENCODE_ANTHROPIC_API_KEY` (base URL hardcoded) |
| **OpenCode Go — OpenAI** (`go-openai`, `@ai-sdk/openai-compatible`) | Optional — [OpenCode's own gateway](https://opencode.ai/docs/go/) Chat Completions surface | `grok-4.5`, `glm-5.3-flash`, `glm-5.3`, `glm-5.2`, `glm-5.1`, `kimi-k3`, `kimi-k2.7-code`, `kimi-k2.6`, `longcat-2.0`, `deepseek-v4.1-flash`, `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-v4-flash-vision-exp`, `mimo-v2.5`, `mimo-v2.5-pro`, `hy4-preview`, `hy3` | `OPENCODE_GO_OPENAI_API_KEY` (base URL hardcoded) |
| **OpenCode Go — Anthropic** (`go-anthropic`, `@ai-sdk/anthropic`) | Optional — same gateway, Messages surface | `minimax-m3`, `minimax-m2.7`, `minimax-m2.5`, `qwen3.8-max`, `qwen3.8-flash`, `qwen3.7-max`, `qwen3.7-plus`, `qwen3.6-plus` | `OPENCODE_GO_ANTHROPIC_API_KEY` (base URL hardcoded) |
| **OpenCode Go — Responses** (`go-responses`, `@ai-sdk/openai`) | Optional — same gateway, Responses API surface | `grok-4.6`, `gpt-5.6-luna`, `muse-spark-1.3-contributor`, `muse-spark-1.2-contributor` | `OPENCODE_GO_OPENAI_API_KEY` (shared Zen key; base URL hardcoded) |
| **OpenRouter** (`openrouter`, `@openrouter/ai-sdk-provider`) | Optional — the [OpenRouter](https://openrouter.ai/) model aggregator (one key, many vendors) | `deepseek/deepseek-v4-pro`, `deepseek/deepseek-v4-flash`, `deepseek/deepseek-v3.2`, `qwen/qwen3.7-plus`, `qwen/qwen3.7-max`, `qwen/qwen3.6-max-preview`, `z-ai/glm-5.1`, `minimax/minimax-m3`, `minimax/minimax-m2.7`, `xiaomi/mimo-v2.5`, `tencent/hy3-preview`, `stepfun/step-3.7-flash`, `nvidia/nemotron-3-ultra-550b-a55b` | `OPENCODE_OPENROUTER_API_KEY` (base URL hardcoded) |

> **OpenCode Go is three providers.** Zen exposes Chat Completions (`go-openai`, `@ai-sdk/openai-compatible`), Messages (`go-anthropic`, `@ai-sdk/anthropic`), and Responses (`go-responses`, `@ai-sdk/openai`) under one hardcoded base. One provider block cannot pin three SDKs, so three selectors route them separately. Same Zen key works for every surface; Responses reuses `OPENCODE_GO_OPENAI_API_KEY`.

> **Anthropic is a direct provider with a fixed base.** Selected by `OPENCODE_REVIEW_REPORT_PROVIDER=ANTHROPIC`, it routes directly to Anthropic's API at `https://api.anthropic.com` (hardcoded in `opencode.json`, like OpenCode Go and OpenRouter) — so there's **no URL Variable**, only the `OPENCODE_ANTHROPIC_API_KEY` Secret. Models are Claude-family ids (`claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`). Use this when you want real Claude models rather than the OpenCode Go Zen gateway's Anthropic-surface models (MiniMax/Qwen).

> **OpenRouter is an aggregator with a fixed base.** Selected by `OPENCODE_REVIEW_REPORT_PROVIDER=OPEN_ROUTER`, it routes through the single public endpoint `https://openrouter.ai/api/v1` (hardcoded in `opencode.json`, like OpenCode Go) — so there's **no URL Variable**, only the `OPENCODE_OPENROUTER_API_KEY` Secret. Its model ids carry a `vendor/` prefix (`deepseek/deepseek-v4-pro`, `z-ai/glm-5.1`, …); opencode prefixes the provider-id and routes `openrouter/<vendor>/<model>` correctly. Anthropic and OpenAI models are intentionally **not** declared here — use the dedicated providers for those. The API key is supplied the same way as every other provider (the `{env:…}` placeholder in `opencode.json`); OpenCode's `/connect`/`auth.json` flow is not used.

The active provider is chosen by the **`OPENCODE_REVIEW_REPORT_PROVIDER`** Variable (`GEMINI` | `COPILOT` | `OPENAI` | `ANTHROPIC` | `OPENCODE-GO-OPENAI` | `OPENCODE-GO-ANTHROPIC` | `OPENCODE-GO-RESPONSES` | `OPEN_ROUTER`, default `OPENAI`). The pipeline resolves it to the matching opencode provider-id and gateway credentials, then prefixes every model with that id (`<provider-id>/<model>`) when invoking OpenCode. Optional providers can be left unconfigured: you only need credentials for the provider `OPENCODE_REVIEW_REPORT_PROVIDER` actually selects.

### Decision model scoring (optional)

Off by default (`OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS=0`). When on, an independent **structured decision model** — TypeSafe Jev 1.13 — judges the merged findings after the chunk reviews and before the summary is written (`run-review.sh` Step 17.6, LADR-093). It is not a chat model and is not an opencode provider: it answers typed yes/no, choice and rubric questions with probabilities, so the gate calls it directly over HTTPS (curl + jq) and it needs no `opencode.json` entry. It reuses an existing key — **no new Secret**.

| Decision provider | Endpoint (fixed) | Key (reused Secret) | Default model |
|---|---|---|---|
| `OPENCODE-GO-DECISIONS` (default) | `https://opencode.ai/zen/v1/systemone` (OpenCode Console catalog — Jev is not in the Go catalog) | `OPENCODE_GO_OPENAI_API_KEY` | `jev-1.13` (`jev-1.13-free` for trials) |
| `OPENROUTER-DECISIONS` | `https://openrouter.ai/api/alpha/decisions` | `OPENCODE_OPENROUTER_API_KEY` | `typesafe/jev-1.13` |

For every merged finding it asks whether the **quoted evidence actually demonstrates the defect** (`supported`), which **severity** the finding deserves, whether it is **pre-existing**, and how **actionable** it is; then, once per PR, whether the PR should be **blocked**, the **dominant risk** category and the **overall risk**. The chunk model's own severity, confidence and `[VERIFIED]` tag are never changed.

- **`annotate`** (default) — each finding line gains a suffix such as `· decision: supported 0.91`, plus `[UNSUPPORTED]` when `supported` is below `OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY` and `(decision model: medium)` when it disagrees with the severity. The Coverage block names the model and the counts. Nothing is removed and the verdict rules are unchanged.
- **`filter`** — additionally removes non-critical findings below the threshold from the Issues Summary and lists them in the Coverage block. Because that can turn a REQUEST_CHANGES into an approval, it runs only when every chunk reviewed successfully and contributed its structured findings; otherwise it falls back to `annotate` and says why. It never removes a 🔴 Critical. Keep it off until you have measured it on your own PRs — Jev's accuracy on code-review claims is not yet established.

The PR-level answers are passed to the summary model as facts and recorded in the run artifact's `metadata.json`; they never change the posted decision. A preflight or configuration failure — unreachable endpoint, refused key, timeout, missing dependency, or invalid provider settings — logs one warning and leaves the review exactly as it would have been without the feature. After a successful preflight, an individual malformed or failed response leaves only that finding unscored; other successful scores and the `skipped` count are still recorded. Cost is input-token-only and small (one request per finding plus one per PR); it adds precision, not recall, and does not reduce the gate's own token spend.

### GitHub configuration

Set these under repo (or org) **Settings → Secrets and variables → Actions**. The workflow exports each value into the job env so OpenCode's `{env:...}` substitution resolves at runtime.

**Secrets** (API keys only — sensitive):

| Secret | For | Required? |
|---|---|---|
| `OPENCODE_OPENAI_API_KEY` | OpenAI gateway API key | Required (default provider) |
| `OPENCODE_GEMINI_API_KEY` | Gemini gateway API key | Only if using `GEMINI` |
| `OPENCODE_ANTHROPIC_API_KEY` | Anthropic (Claude) API key | Only if using `ANTHROPIC` |
| `OPENCODE_GO_OPENAI_API_KEY` | OpenCode Go Chat Completions / Responses API key — an OpenCode Console key, also reused by the `OPENCODE-GO-DECISIONS` decision provider | Only if using `OPENCODE-GO-OPENAI` or `OPENCODE-GO-RESPONSES`, or decision scoring with `OPENCODE-GO-DECISIONS` (the default decision provider) |
| `OPENCODE_GO_ANTHROPIC_API_KEY` | OpenCode Go (Anthropic surface) API key | Only if using `OPENCODE-GO-ANTHROPIC` |
| `OPENCODE_OPENROUTER_API_KEY` | OpenRouter aggregator API key — also reused by the `OPENROUTER-DECISIONS` decision provider | Only if using `OPEN_ROUTER`, or decision scoring with `OPENROUTER-DECISIONS` |

**Variables** (non-sensitive — gateway URLs, provider selector, model chain; switch provider / retune without editing the workflow; each falls back to a literal default if unset):

| Variable | Default | Role |
|---|---|---|
| `OPENCODE_REVIEW_REPORT_PROVIDER` | `OPENAI` | Selects the active provider: `GEMINI`, `COPILOT`, `OPENAI`, `ANTHROPIC`, `OPENCODE-GO-OPENAI`, `OPENCODE-GO-ANTHROPIC`, `OPENCODE-GO-RESPONSES`, or `OPEN_ROUTER` |
| `OPENCODE_REVIEW_REPORT_OPENAI_URL` | _(none — required)_ | OpenAI gateway base URL (default provider). There is **no** hardcoded fallback: leaving it unset aborts the run at preflight. Set `https://api.openai.com/v1` for the native API, or point it at a LiteLLM proxy. |
| `OPENCODE_REVIEW_REPORT_GEMINI_URL` | _(none — required when `GEMINI` is selected)_ | Gemini gateway base URL (OpenAI-compatible), e.g. `https://generativelanguage.googleapis.com/v1beta/openai`. Point at a LiteLLM proxy to relay instead. |
| `OPENCODE_CLI_VERSION` | _(unset)_ | OpenCode v2 CLI pin (recommended — see callout above). Unset = any v2: latest on a fresh runner, but an already-present v2 binary is reused as is on local and self-hosted machines; configured values must be a specific `2.x` release. |
| `OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION` | _(unset)_ | `code-review-graph` package version pin (LADR-049, recommended for supply-chain hygiene). Unset = latest. |
| `OPENCODE_TOOL_RTK_VERSION` | _(unset)_ | RTK binary version pin. On OpenCode v2 the binary remains installed/version-visible; plugin initialization is bypassed until RTK advertises `--opencode-v2`. Unset = latest. |
| `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY` | `gpt-5.6-sol` | Primary deep chunk-review model |
| `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY` | `gpt-5.5` | Secondary review model (two-tier chain) |
| `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR` | `gpt-5.6-terra` | Cheap model for grouping, aggregation, and summary |
| `OPENCODE_ANALYSE_PROVIDER` | _(unset)_ | Optional provider selector for the autonomous analyse primary model. Required when `OPENCODE_ANALYSE_MODEL` is set; unset means analyse inherits the review provider/model. |
| `OPENCODE_ANALYSE_MODEL` | _(unset)_ | Optional model used by `pipeline-ai-analyse.yml` for autonomous low/medium fixes. When set, it runs on `OPENCODE_ANALYSE_PROVIDER`; fallbacks stay on the review provider/model chain. |
| `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` | _(unset — off)_ | "Test in the loop" switch. Off by default: autonomous fixes may **not** edit tests (unit/component/integration/e2e) or test-framework/config files, so the suite stays an independent oracle for the fix; any such edit is reverted before commit. Set truthy (`1`/`true`/`yes`/`on`) to allow test + test-framework self-fixes. |
| `OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING` | `10` | If changed file count is this value or lower, review as a single chunk. Above it, use normal chunking flow. |
| `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` | `100` | Upper bound on post-filter changed files. If a PR exceeds it, the gate posts REQUEST_CHANGES ("too many files to review") and skips the AI review entirely. Override per run with `file_limit` or local `--file-limit`. |
| `OPENCODE_REVIEW_REPORT_EXCLUDE_DELETED` | `0` | Opt-in: remove deleted paths from AI review scope. Their names and exclusion reason remain in prompts, preventing false missing-file findings. |
| `OPENCODE_REVIEW_REPORT_EXCLUDE_GENERATED_PATHS` | _(empty)_ | Newline-separated generated file paths or directory prefixes to remove from AI review scope. Their names and exclusion reason remain in prompts. |
| `OPENCODE_REVIEW_REPORT_RUN_ON_DRAFT` | `false` | Review PRs while they are still in **DRAFT**. Truthy (`1`/`true`/`yes`/`on`) reviews drafts; falsy (`0`/`false`/`no`/`off`, the default) waits until the PR is marked ready. Set this to `true` on a repo that wants cheap review feedback during draft — useful when a costlier check (e.g. the eval harness) is deliberately reserved for ready PRs. The `run_on_draft` input overrides this Variable when non-empty. |
| `OPENCODE_ANALYSE_RUN_ON_DRAFT` | `false` | Independent draft switch for `pipeline-ai-analyse.yml`. Truthy lets the autonomous low/medium fixer act on a draft PR; falsy (the default) makes the guard skip drafts. Deliberately separate from the review Variable — reviewing a draft and letting an autonomous fixer commit to one are different risk decisions, so a repo can enable either without the other. |
| `OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS` | `1` (on) | Code graph analysis (LADR-049). Builds a Tree-sitter SQLite knowledge graph via `code-review-graph` and runs risk-scored change detection. Set falsy to disable. |
| `OPENCODE_REVIEW_REPORT_ENABLE_TRIVIAL_SKIP` | `1` (on) | Trivial-PR skip (LADR-059). A PR whose every changed file is a lockfile/manifest may be skipped after a deterministic allowlist precondition plus an orchestrator-model veto. Never fires for `/ai-review` comments or `workflow_dispatch`. Set falsy to review every PR. |
| `OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS` | `1` (on) | Per-run artifact upload (LADR-062). Assembles `ci_temp/run/` (report, per-chunk reviews, merged findings, metadata) on every run — including skipped and failed ones — and uploads it. Set falsy to disable. |
| `OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY` | `1` (on) | Bounded `gh` retry (LADR-078). Gives each GitHub call that could abort the run exactly one retry after a fixed 30s wait, on an allowlist of HTTP-status/network signatures only; writes verify before retrying so a landed mutation is never re-posted. Set falsy to restore fail-fast behaviour. |
| `OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS` | `0` (off) | Decision-model scoring of the merged findings (LADR-093) — see [Decision model scoring (optional)](#decision-model-scoring-optional). Off → the posted review is byte-identical. |
| `OPENCODE_REVIEW_REPORT_DECISIONS_PROVIDER` | `OPENCODE-GO-DECISIONS` | `OPENCODE-GO-DECISIONS` or `OPENROUTER-DECISIONS`. Reuses that vendor's existing key Secret; no URL Variable (both endpoints are fixed). |
| `OPENCODE_REVIEW_REPORT_DECISIONS_MODEL` | _(provider default)_ | `jev-1.13` on `OPENCODE-GO-DECISIONS` (`jev-1.13-free` for trials), `typesafe/jev-1.13` on `OPENROUTER-DECISIONS`. A crossed id is refused with a warning. |
| `OPENCODE_REVIEW_REPORT_DECISIONS_MODE` | `annotate` | `annotate` tags findings and never drops one; `filter` also suppresses non-critical findings below the threshold, only on full coverage. |
| `OPENCODE_REVIEW_REPORT_DECISIONS_MIN_PROBABILITY` | `0.5` | `supported` probability below which a finding is tagged `[UNSUPPORTED]` (annotate) or suppressed (filter, non-critical only). |
| `OPENCODE_REVIEW_REPORT_DECISIONS_TIMEOUT` | `20` | Seconds per decision request. |
| `OPENCODE_REVIEW_REPORT_MAX_PARALLEL` | `7` | Maximum chunk reviews run concurrently. Raising it trades provider rate-limit risk for wall-clock; lower it if the gateway throttles. |
| `OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX` | `1200` | Upper clamp (seconds) for the per-chunk budget, which is split across the review model chain. Bounds `OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT` so a retune cannot set an unbounded budget. |
| `OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT` | `600` | Total budget (seconds) for the aggregation summary call, which previously had no timeout (LADR-092). Split across the chain: the orchestrator gets a share (390 s at the default), the review-model fallback gets what is left, so a hung orchestrator no longer blocks the job or starves the fallback. A timeout takes the existing summary-failure path; it can never make a review greener. Non-integer values fall back to `600`. |
| `OPENCODE_REVIEW_REPORT_COPILOT_URL` | _(unset)_ | Copilot gateway base URL (only when `OPENCODE_REVIEW_REPORT_PROVIDER=COPILOT`). |
| `OPENCODE_ANALYSE_TEST_COMMAND` | _(unset)_ | Optional test command `pipeline-ai-analyse.yml` runs to verify its autonomous fixes. Unset skips the verification step. |
| `OPENCODE_ANALYSE_TEST_TIMEOUT` | `600` | Seconds `OPENCODE_ANALYSE_TEST_COMMAND` may run before it is killed. |
| `OPENCODE_ANALYSE_TEST_LOG_LINES` | `40` | Tail lines of test output surfaced in the analyse summary when the test command fails. |
| `EVAL_SAMPLES` | `1` | Runs per fixture in the LLM eval harness. Precision and recall both use a majority rule, so >1 absorbs single-sample model noise — cost scales linearly. |
| `EVAL_PARALLEL` | `4` | Fixtures evaluated concurrently in the eval harness. Each is a live paid model call; raising it trades wall-clock for rate-limit risk, and a rate-limited fixture fails the run as an INFRA failure. |

> **Switching provider:** set `OPENCODE_REVIEW_REPORT_PROVIDER`, selected provider's Secret, and all three model Variables. OpenCode Go model IDs must use matching selector: Chat Completions (`OPENCODE-GO-OPENAI`), Messages (`OPENCODE-GO-ANTHROPIC`), or Responses (`OPENCODE-GO-RESPONSES`). Responses and Chat Completions share `OPENCODE_GO_OPENAI_API_KEY`. `lib/resolve-provider.sh` fails fast on cross-surface IDs.

> **One-click manual switch (no Variables to change):** a `workflow_dispatch` (manual) run also offers a **model preset** dropdown. Picking *Anthropic Claude Opus 4.8*, *Anthropic Claude Sonnet 4.6*, *Anthropic Claude Haiku 4.5*, *OpenAI GPT-5.5*, *OpenCode DeepSeek V4 Pro*, *OpenCode GLM-5.1*, *OpenCode MiniMax m3*, *OpenCode Qwen3.7 Plus*, *OpenRouter DeepSeek V4 Pro*, *OpenRouter Qwen3.7 Plus*, *OpenRouter GLM-5.1*, or *OpenRouter MiniMax M3* overrides the provider **and** all three model tiers (primary/secondary/orchestrator) with that single model for that one run — taking precedence over both the free-text `model` input and the `OPENCODE_REVIEW_REPORT_*` Variables. The preset still needs the matching provider's API-key Secret configured. Leave the dropdown on *(repository default)* to use the configured Variables.

## Environment variables

Complete reference for every environment variable the pipeline reads. **Selector + credentials + model chain** are what you configure; **derived** vars are computed at runtime by [`lib/resolve-provider.sh`](.agents/skills/ai-review-report/scripts/lib/resolve-provider.sh) (CI: written to `$GITHUB_ENV`; local: exported by `local-review.sh`) — you never set them by hand.

| Variable | Set by | Purpose |
|---|---|---|
| `OPENCODE_REVIEW_REPORT_PROVIDER` | GitHub **Variable** / `--provider` / shell (default `OPENAI`) | Selects the active provider: `GEMINI`, `COPILOT`, `OPENAI`, `ANTHROPIC`, `OPENCODE-GO-OPENAI`, `OPENCODE-GO-ANTHROPIC`, `OPENCODE-GO-RESPONSES`, or `OPEN_ROUTER`. |
| `OPENCODE_REVIEW_REPORT_GEMINI_URL` (**Variable**) / `OPENCODE_GEMINI_API_KEY` (**Secret**) | GitHub / shell export | Gemini gateway base URL + API key (`gemini` provider). |
| `OPENCODE_REVIEW_REPORT_OPENAI_URL` (**Variable**) / `OPENCODE_OPENAI_API_KEY` (**Secret**) | GitHub / shell export | OpenAI gateway base URL + API key (`openai` provider). |
| `OPENCODE_ANTHROPIC_API_KEY` (**Secret**) | GitHub / shell export | Anthropic (Claude) API key (`anthropic` provider). Base URL `https://api.anthropic.com` is hardcoded — no URL Variable. |
| `OPENCODE_GO_OPENAI_API_KEY` (**Secret**) | GitHub / shell export | OpenCode Go key for `go-openai` and `go-responses`. Base URL is hardcoded (`https://opencode.ai/zen/go/v1`) — no URL Variable. |
| `OPENCODE_GO_ANTHROPIC_API_KEY` (**Secret**) | GitHub / shell export | OpenCode Go Anthropic-compatible API key (`go-anthropic` provider). Base URL is hardcoded — no URL Variable. |
| `OPENCODE_OPENROUTER_API_KEY` (**Secret**) | GitHub / shell export | OpenRouter aggregator API key (`openrouter` provider). Base URL `https://openrouter.ai/api/v1` is hardcoded — no URL Variable. |
| `OPENCODE_CLI_VERSION` | GitHub **Variable** / shell (default unset) | OpenCode v2 CLI version pin (recommended — see callout above). Unset = any v2 (latest on a fresh runner, an existing v2 binary is reused as is); a configured value must be a specific `2.x` release. Existing consumers must update any 1.x value when moving to `@v2`. |
| `OPENCODE_TOOL_CODE_REVIEW_GRAPH_VERSION` | GitHub **Variable** / shell (default unset) | `code-review-graph` package version pin (LADR-049, recommended for supply-chain hygiene). Unset = latest. |
| `OPENCODE_TOOL_RTK_VERSION` | GitHub **Variable** / shell (default unset) | RTK binary version pin. OpenCode v1 initializes `--opencode`; v2 initializes `--opencode-v2` when the installed RTK exposes it, otherwise only plugin initialization is bypassed and the review continues. |
| `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY` | GitHub **Variable** / `--model` / shell (default `gpt-5.6-sol`) | Primary deep chunk-review model. The `workflow_dispatch` `model` input overrides it. |
| `OPENCODE_REVIEW_REPORT_MODEL_SECONDARY` | GitHub **Variable** / shell (default `gpt-5.5`) | Secondary review model (two-tier fallback chain). |
| `OPENCODE_REVIEW_REPORT_MODEL_ORCHESTRATOR` | GitHub **Variable** / shell (default `gpt-5.6-terra`) | Cheap model for semantic grouping, aggregation, and summary. |
| `OPENCODE_ANALYSE_PROVIDER` | GitHub **Variable** (default unset) | Optional provider selector for `pipeline-ai-analyse.yml`'s primary autonomous-fix model: same allowed values as `OPENCODE_REVIEW_REPORT_PROVIDER`. Required when `OPENCODE_ANALYSE_MODEL` is set. |
| `OPENCODE_ANALYSE_MODEL` | GitHub **Variable** (default unset; unset inherits `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY`) | Optional model used by `pipeline-ai-analyse.yml` for autonomous low/medium fixes. When set, it runs on `OPENCODE_ANALYSE_PROVIDER`; the fallback chain remains `OPENCODE_REVIEW_REPORT_MODEL_PRIMARY` → `_SECONDARY` on `OPENCODE_REVIEW_REPORT_PROVIDER`. |
| `OPENCODE_ANALYSE_MAX_INCREMENTAL` | GitHub **Variable** (default `3`) | Max consecutive incremental gate reviews since the latest full review before autonomous fixes stop and a limit comment is posted. |
| `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` | GitHub **Variable** (default unset — off) | "Test in the loop" switch for `pipeline-ai-analyse.yml`. Off by default, the autonomous fixer may not modify tests (unit/component/integration/e2e) or test-framework/config files: `.agents/skills/ai-analyse/scripts/lib/filter-test-self-fix.sh` reverts any such edit before the commit step, so the suite stays an independent oracle that proves the fix did not break anything. Set truthy (`1`/`true`/`yes`/`on`) to allow test + test-framework self-fixes; reverted paths are listed in the PR auto-fix summary. |
| `OPENCODE_ANALYSE_GH_TOKEN` | GitHub **Secret** (optional) | PAT preferred by `pipeline-ai-analyse.yml` for auto-fix pushes so the follow-up push is attributed to a user rather than the repository `GITHUB_TOKEN` (the commit author remains `github-actions[bot]`). If `ai-analyse` stages changes under `.github/workflows/**`, this PAT also needs `workflow` scope; otherwise the run emits `push_skipped=workflow-paths-require-pat-with-workflow-scope` instead of retrying a `GITHUB_TOKEN` push GitHub will reject for that path. For non-workflow changes, the workflow falls back to `GITHUB_TOKEN` when this Secret is unset or rejected. |
| `OPENCODE_REVIEW_REPORT_MIN_FILE_COUNT_BEFORE_CHUNCKING` | GitHub **Variable** / shell (default `10`) | If changed file count is this value or lower, review as a single chunk. Above it, the standard chunking flow runs. |
| `OPENCODE_REVIEW_REPORT_MAX_FILE_COUNT` | GitHub **Variable** / shell (default `100`) | Max post-filter changed files the gate will review. `file_limit` and `--file-limit` override it for one run. |
| `OPENCODE_REVIEW_REPORT_EXCLUDE_DELETED` | GitHub **Variable** / shell (default `0`) | Excludes deleted paths only when truthy. Use workflow `exclude_deleted` or local `--exclude-deleted` for one run. |
| `OPENCODE_REVIEW_REPORT_EXCLUDE_GENERATED_PATHS` | GitHub **Variable** / shell (default empty) | Newline-separated generated file paths or directory prefixes. Use workflow `exclude_generated_paths` or repeat local `--exclude-generated PATH`. |
| `OPENCODE_REVIEW_REPORT_RUN_ON_DRAFT` | GitHub **Variable** / workflow `run_on_draft` input (default `false`) | Reviews PRs while they are still in DRAFT when truthy; when falsy — the default in every packaging — the gate waits for `ready_for_review`. Resolution is `run_on_draft` input → this Variable → `false`, so the input wins when non-empty and a repo opts in by setting either. |
| `OPENCODE_ANALYSE_RUN_ON_DRAFT` | GitHub **Variable** / `run_on_draft` dispatch input (default `false`) | Independent draft switch for the autonomous fixer. When falsy (the default) the analyse guard skips a draft PR (`draft PRs are not auto-fixed unless OPENCODE_ANALYSE_RUN_ON_DRAFT is enabled`) even if the gate reviewed it — so enabling draft *reviews* does not implicitly enable draft *auto-fixes*. The guard reads `.draft` from the PR JSON it already fetches, since a `workflow_run`-triggered `if:` cannot see draft state. |
| `OPENCODE_REVIEW_REPORT_ENABLE_GRAPH_ANALYSIS` | GitHub **Variable** / shell (default `1` — on) | Code graph analysis (LADR-049): builds the `code-review-graph` SQLite graph and emits `ci_temp/graph_detect_changes.json`, `graph_risk_summary.md`, `graph_file_risks.txt`. Degrades gracefully — the review proceeds without graph enrichment on failure. Set falsy to skip the build entirely. |
| `OPENCODE_REVIEW_REPORT_ENABLE_TRIVIAL_SKIP` | GitHub **Variable** / shell (default `1` — on) | Trivial-PR skip (LADR-059). Two-stage: a deterministic lockfile/manifest allowlist precondition, then an orchestrator-model veto — anything other than an explicit `yes`, including a timeout, proceeds with the full review. Never fires for `/ai-review` comments or `workflow_dispatch`. |
| `OPENCODE_REVIEW_REPORT_ENABLE_RUN_ARTIFACTS` | GitHub **Variable** / shell (default `1` — on) | Per-run artifact assembly (LADR-062). An EXIT trap builds `ci_temp/run/` so skipped and failed runs upload one too. Must be declared in both workflow packagings. |
| `OPENCODE_REVIEW_REPORT_ENABLE_GH_RETRY` | GitHub **Variable** / shell (default `1` — on) | Bounded single retry for GitHub API calls (LADR-078) via `lib/gh-retry.sh`: one attempt, a fixed 30s wait, one retry. Allowlisted HTTP/network signatures only, so an unrecognised error still fails fast; writes snapshot a gate-authored review/comment count and re-read it before retrying so a mutation that landed is never duplicated. |
| `OPENCODE_REVIEW_REPORT_MAX_PARALLEL` | GitHub **Variable** / shell (default `7`) | Maximum chunk reviews in flight at once. |
| `OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT_MAX` | GitHub **Variable** / shell (default `1200`) | Upper clamp in seconds on the per-chunk budget that `OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT` requests; the budget is split across the review model chain. |
| `OPENCODE_REVIEW_REPORT_SUMMARY_TIMEOUT` | GitHub **Variable** / shell (default `600`) | Total budget in seconds for the aggregation summary call (LADR-092), split across the orchestrator and the review-model fallback via `lib/run-split-chain.sh`. Must be declared in both workflow packagings. |
| `OPENCODE_REVIEW_REPORT_COPILOT_URL` (**Variable**) / `OPENCODE_COPILOT_API_KEY` (**Secret**) | GitHub / shell export | Copilot gateway base URL + API key (`copilot` provider). |
| `OPENCODE_ANALYSE_TEST_COMMAND` | GitHub **Variable** (default unset) | Test command `pipeline-ai-analyse.yml` runs to verify its own autonomous fixes. Unset skips verification. Note this only *runs* tests — the fixer may not *edit* them unless `OPENCODE_ANALYSE_ALLOW_TEST_SELF_FIX` is truthy, and it must never make a failing test green (LADR-056). |
| `OPENCODE_ANALYSE_TEST_TIMEOUT` | GitHub **Variable** (default `600`) | Seconds `OPENCODE_ANALYSE_TEST_COMMAND` may run before being killed. |
| `OPENCODE_ANALYSE_TEST_LOG_LINES` | GitHub **Variable** (default `40`) | Tail lines of failing test output included in the analyse summary. |
| `EVAL_SAMPLES` | GitHub **Variable** / `samples` dispatch input (default `1`) | Runs per fixture in `llm-eval-harness.yml`; majority rule over samples absorbs model noise. Cost scales linearly. |
| `EVAL_PARALLEL` | GitHub **Variable** / `parallel` dispatch input (default `4`) | Fixtures evaluated concurrently in `llm-eval-harness.yml`. Each is a live paid model call. |
| `MANDATORY_CONTEXT_FILES` | `mandatory_context_files` input (`workflow_call` / `workflow_dispatch`) → built-in list; the local-job packaging reads the GitHub **Variable** of the same name (space-separated) | Context files loaded into every review (coding standards, language/tool setup, review guidelines). The built-in list names product-repo paths and warn-and-skips missing ones; pass the repo's real files, or `none` for no mandatory context files (only as the whole value — `none` inside a list is an ordinary, missing path). Blank cannot mean "none": it falls through to the built-in list. |
| `AGENTS_MD_EXEMPT_PATHS` | Workflow `env:` (pipe-separated) | Paths exempt from the `*_AGENTS.md` validation requirement. |
| `OPENCODE_REVIEW_REPORT_DISABLE_AGENTS_MD_CHECK` | GitHub **Variable** (default `0`) / workflow input | Disables the full-review AGENTS.md / README.md / SKILL.md documentation validation when set to `1`. Leave unset or `0` to keep the gate enabled. |
| `OPENCODE_REVIEW_REPORT_BYPASS_MANDATORY_CONTEXT_FILE` | GitHub **Variable** (default empty) / workflow input | When truthy (`1`/`true`), bypasses both the AGENTS.md validation checks and the mandatory context file loading. Leave unset/empty or `0`/`false` to keep the standard behaviour. The workflow input overrides the Variable when non-empty; the Variable is used when the input is null/empty. |
| `OPENCODE_REVIEW_REPORT_ENABLE_STRUCTURED_FINDINGS` | GitHub **Variable** / shell (default `1` — on) | Structured findings (LADR-055). When on, each chunk review emits a machine-readable JSON sidecar alongside its markdown; the sidecars are deduplicated across chunks, a finding claiming confidence ≥ 75 without quoting its motivating line is demoted, findings below the actionable anchor are suppressed and counted, and the posted **Issues Summary** is rendered from the merged result with stable `#` numbers and a chunk back-reference per finding. The markdown grammar (severity headers, emoji, `[VERIFIED]`/`[SPECULATIVE]`) is identical either way, so nothing downstream changes shape. Set to a falsy value (`0`/`false`/`no`/`off`) to revert the chunk prompt and the summary to their pre-LADR-055 behaviour. Requires nothing extra to be installed — Python is used if present and skipped gracefully if not. |
| `OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS` / `OPENCODE_REVIEW_REPORT_DECISIONS_{PROVIDER,MODEL,MODE,MIN_PROBABILITY,TIMEOUT}` | GitHub **Variables** / shell (defaults `0`, `OPENCODE-GO-DECISIONS`, provider default, `annotate`, `0.5`, `20`) | Decision-model scoring (LADR-093). Declared in **both** workflow packagings; `local-review.sh` honours the same names. Requires structured findings (it scores their merged document). The key is the selected decision provider's existing Secret (`OPENCODE_GO_OPENAI_API_KEY` / `OPENCODE_OPENROUTER_API_KEY`). |
| `OPENCODE_REVIEW_REPORT_CHUNK_TIMEOUT` | GitHub **Variable** / shell (default `450`) | Seconds a single chunk review may take. The budget wraps the entire model chain, so when it fires the fallback model is never reached and the chunk fail-closes to REQUEST_CHANGES — raise it rather than lowering it. Raised from a hardcoded 300 after structured findings (LADR-055) roughly tripled per-chunk model output. |
| `GITHUB_TOKEN` | GitHub Actions (or `gh auth` locally) | Posting reviews/comments and reading PR metadata. |
| `OPENCODE_REVIEW_REPORT_REPO_ROOT` | shell / workflow `env:` (default: derived from script location) | Overrides the repo `local-review.sh` reviews. Only needed when the script runs from outside its skill tree — e.g. the [npm-in-GitHub-Actions](#use-in-github-actions-via-npm) path, where you set it to `${{ github.workspace }}`. |
| `OPENCODE_REVIEW_REPORT_PROVIDER_ID` | **Derived** | The opencode.json provider key: `gemini` / `github-copilot` / `openai` / `anthropic` / `go-openai` / `go-anthropic` / `go-responses` / `openrouter`. |
| `OPENCODE_ANALYSE_PROVIDER_ID` / `OPENCODE_ANALYSE_GATEWAY_URL` | **Derived** | Analyse-only provider id + gateway URL, computed only when `OPENCODE_ANALYSE_MODEL` is set. The analyse API key stays in its provider-specific Secret and is not written to `$GITHUB_ENV`. |
| `OPENCODE_REVIEW_REPORT_GATEWAY_URL` / `OPENCODE_GATEWAY_API_KEY` | **Derived** | The selected provider's URL + key, copied to generic names for the credential presence check. (Health is checked separately and provider-agnostically through v2's `opencode api get /api/info` — `lib/opencode-health.sh` — so there is no derived per-provider health URL.) |
| `OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE` | GitHub **Variable** (default `1`) | Controls whether `.claude` support is disabled in opencode. If unset or empty, defaults to `1` (disabled). Set to `0` to re-enable Claude Code integration. |
| `OPENCODE_DISABLE_CLAUDE_CODE` | **Derived** from `OPENCODE_REVIEW_REPORT_DISABLE_CLAUDE_CODE` | Disables all `.claude` support in opencode to prevent conflicts with Claude Code's `.claude` directory features. |

## Using Local Report

Use **`ai-review-report --local`** to generate a review report locally. This is the same review generator as the CI gate, wrapped for local execution.

Bare `--local` reviews HEAD/current branch against `main`, does not post to GitHub, uses `OPENCODE_REVIEW_REPORT_PROVIDER` from your shell if set (otherwise `OPENAI`), and uses local runner model defaults unless you pass overrides. It should not prompt for PR number, provider, post mode, or base branch.

If the skill is copy-installed and you want to run the script directly:

```bash
.agents/skills/ai-review-report/scripts/local-review.sh
```

Optional local overrides:

```bash
.agents/skills/ai-review-report/scripts/local-review.sh --base develop
.agents/skills/ai-review-report/scripts/local-review.sh --provider OPENAI --model gpt-5.5
.agents/skills/ai-review-report/scripts/local-review.sh --pr 48 --post
.agents/skills/ai-review-report/scripts/local-review.sh --file-limit 250 --exclude-deleted --exclude-generated generated/ --exclude-generated src/api.g.cs
```

Local prerequisites: `opencode`, `jq`, and shell-exported provider credentials. `gh` is required only for `--pr` or `--post`.

## Using `/ai-review`

`/ai-review` is the companion skill that **consumes** a posted review and applies fix/skip decisions back to the PR. It is invoked locally inside Claude Code after the CI gate has posted a review.

### Two modes

| Mode | When to use | Invocation |
|---|---|---|
| **Analyse** | Fetch a posted review and get a recommended fix/skip table | `/ai-review <pr>` |
| **Execute** | Apply the fix/skip decisions from an analyse run | `/ai-review <pr> 1=fix 2=skip …` |

Modes are auto-detected: if any argument matches `<N>=fix` or `<N>=skip`, execute mode is used; otherwise analyse.

### Quick examples

```bash
# Analyse PR 48 — fetches the latest AI review and outputs a fix/skip recommendation table
/ai-review 48

# Execute decisions from the analyse output
/ai-review 48 1=fix 2=skip 3=fix

# Force a specific review source (auto-detected by default)
/ai-review analyse 48 --source=copilot
/ai-review execute 48 1=fix --source=other
```

### Result routing

- **GitHub Copilot review** — replies to and resolves each inline review thread per decision, then posts a summary comment on the PR.
- **Other review** (OpenCode/Gemini/generic) — appends the fix/skip table to the PR description's **AI Review Notes** section.

Source is auto-detected by scanning the PR's reviews for the Copilot bot. Override with `--source=copilot` or `--source=other`.

### Guardrails

- Analyse **always stops** — execute is never triggered automatically.
- Fixes are scoped to selected items only; unrelated threads are never resolved.
- Non-Copilot flow appends to AI Review Notes — it never overwrites existing content.

Full spec: [`.agents/skills/ai-review/SKILL.md`](.agents/skills/ai-review/SKILL.md)
