---
description: 'How AI agent skills must handle secrets — read from the runtime environment via a script, never embed secret values in model-visible or committed text.'
globs: ".agents/skills/**"
paths:
  - ".agents/skills/**"
applyTo: '.agents/skills/**'
alwaysApply: false
---

# Skill Secret Handling

How any skill under `.agents/skills/` must handle a secret (API key, token, password, connection string). Updated: 2026-09-27

Synced from the canonical rule in `generic-automation-and-it/smooth-devex-template` (`.github/instructions/skills/skill-secret-handling.instructions.md`, template PR 85). The Rule and the Checklist are kept verbatim; Reference Pattern and Current Status are rewritten for this repo's skills.

## The Rule

A skill that needs a secret **MUST delegate to a script that reads the secret from the runtime environment** (an environment variable injected at execution time) and uses it there. The secret **value** must never appear in any model-visible or committed text.

| Allowed | Forbidden |
|---------|-----------|
| `SKILL.md` instructs the agent to run a script that reads `$MY_API_KEY` from the env | A real key, token, or password written literally in `SKILL.md`, a prompt, agent YAML, README, reference doc, or any committed file |
| A bash/python script reads the secret via `os.environ` / `"$VAR"` and passes it to the tool | Echoing/printing the secret, putting it in a URL query string, or passing it as a logged CLI argument |
| Documenting the env var **name** the script expects (e.g. `MY_API_KEY`) | Documenting the env var **value** |

The secret value flows: **runtime environment → script → tool**. It is never typed into a file an agent reads, generates, or commits.

## Reference Pattern

This repo has two canonical shapes; mirror whichever fits:

- **Model provider keys (opencode).** Each `OPENCODE_<PROVIDER>_API_KEY` is a GitHub **Secret**, mapped into the gate step's `env:` and resolved by opencode itself from the `{env:OPENCODE_<PROVIDER>_*}` placeholders in `.agents/skills/ai-review-report/assets/opencode.json`. Scripts never print the value: `lib/resolve-provider.sh` and `run-review.sh` only check it is non-empty and name the **variable** in the error when it is not.
- **Raw HTTP calls (no opencode).** `.agents/skills/ai-review-report/scripts/lib/score-findings-decisions.sh` writes the `Authorization` header to a `umask 077` file in a `mktemp -d` directory, passes it to curl as `-H @file`, unsets the variable, and removes the directory in an `EXIT` trap — the key never reaches argv or a process listing.

## Checklist

Run this when **authoring or reviewing** a skill that touches a secret or launches a model/agent with tools. Every box is a yes/no question about the diff; a "no" is a finding, not a style note.

**Where the value lives**
- [ ] No secret value in `SKILL.md`, prompts, agent YAML, README, references, templates, tests or fixtures — only env var **names**.
- [ ] Knowledge artefacts the skill writes (Understandings, worktasks, PR bodies, run summaries) redact to `<REDACTED>`.
- [ ] Custom config ships placeholders (`{env:VAR}`), never values.

**How the script uses it**
- [ ] Read from the environment inside a script (`"${VAR:-}"`, `os.environ`); presence checked without printing (`[ -n "${VAR:-}" ]`).
- [ ] Never a CLI argument, URL userinfo (`https://token@host`) or query string. Use env-auth tools (`gh` reads `GH_TOKEN`), stdin, or a one-shot credential helper (`git -c 'credential.helper=!gh auth git-credential' push`).
- [ ] A user-supplied URL is **rejected** when it embeds credentials, before it is echoed or cloned.
- [ ] No `set -x`, `env`/`printenv`, or unredacted stderr from tools that echo URLs or headers around the secret.

**What a model process can reach**
- [ ] The model subprocess gets only the key its provider needs, via an **allowlist** (a deny-list misses tokens nobody listed, such as a developer shell's other keys): in a subshell, `unset` every variable not on the list, then `exec` the model CLI. A GitHub, OIDC or cloud token never reaches it. Never pass `NAME=value` to `env -i`: the value shows in the process list.
- [ ] Tool sandbox: no shell, no web fetch, no paths outside the repo; `read` and `edit` deny `.git/**` (persisted credentials, hooks) and `.env*`. Check **how** each tool's permission is matched: a content-search tool whose rule matches the query, not the file path (opencode `grep`), cannot be fenced by path and must be denied outright. Agent-level `read: "allow"` replaces the tool's default `.env` deny, so restate the denies.
- [ ] Nothing on disk inside the model's readable root holds a credential while the model runs. In Actions: `actions/checkout` with `persist-credentials: false`. If one may still be there, the script moves it outside the root for the model phase and restores it (or fails closed when it cannot safely move it).
- [ ] **Every** git command the script runs is hook-proof, set once for the whole script (`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n=core.hooksPath`/`GIT_CONFIG_VALUE_n=/dev/null`), not per command: the model may have written a hook, hooks inherit the token, and `checkout`, `commit`, `push` and any ref update each fire one.
- [ ] Untrusted input the model reads (upstream repos, issues, diffs) is treated as a prompt-injection source. The script, not the model, decides what gets committed or pushed.

**CI wiring**
- [ ] Secrets mapped on the **step** that needs them, not job-level `env`.
- [ ] Only the needed secrets are mapped; `secrets: inherit` is documented as a same-org shortcut, not the default.

**Before the PR**
- [ ] SkillSpector static scan run or predicted. This repo has no `skill-scan.yml` gate or baseline yet; run the scan locally with the recipe in the template repo's `skillspector-pre-pr` rule and triage the findings in the PR description.
- [ ] The skill's `AGENTS.md` names every env var it reads, and which process receives it.

## Current Status

**Every skill in this repo that launches a model handles real secrets:** `ai-review-report` (the gate, and `local-review.sh`) and `ai-analyse` both run opencode with an `OPENCODE_<PROVIDER>_API_KEY` resolved from `{env:…}` placeholders, and both call `gh` with `GITHUB_TOKEN`/`GH_TOKEN` from the environment; the optional decision scorer (LADR-093) is the header-file reference above. `ai-review` and `git-commit-review-push` read no secret of their own and rely on the developer's `gh`/`git` authentication. No value appears in committed text or prompts; the only credential-shaped literal in the tree is the deliberately planted fake key in the eval fixture `scripts/eval/corpus/must-catch/MC-005-hardcoded-secret/`, which the gate must flag.

The checklist's **model-process** and **CI wiring** items are only partly met. The 2026-09-27 security scan recorded these open gaps:

- The opencode child inherits the full step environment: all seven provider keys, set at job level, plus `GITHUB_TOKEN`.
- The `review` and `analyse` agents allow `external_directory` and do not deny `.git/**` or `.env*`.
- The gate's and the analyse tooling's `actions/checkout` steps keep the default `persist-credentials: true`, so the token sits in a `.git/config` the model can read.
- Model output is posted without redaction.
- `ai-analyse`'s git commands are not hook-proof, and its push puts the token in the URL.
- On the `/ai-review` comment path, untrusted PR-head content can run with the gate's secrets in three ways:
  - the `head_ref` value, which the gate sources as shell;
  - in-repo gate scripts, which are replaced by the checkout;
  - a project `opencode.json` or `.opencode/`.

Close them against this checklist before adding another secret consumer.

## Changelog

> AI loading note: Skip this section during routine task execution. Use it only when updating this rule file.

| Date | Change |
|:-----|:-------|
| 2026-09-27 | Synced into `smooth-ai-report-review` from `smooth-devex-template` (template PR 85). Rule and Checklist verbatim; Reference Pattern, the SkillSpector pre-PR item and Current Status rewritten for this repo. |
| 2026-09-27 | (template) Added the authoring/review **Checklist** (value location, script usage, model-process reach, CI wiring, pre-PR). |
| 2026-09-13 | (template) Moved into the new `skills/` rule category (with `skillspector-pre-pr`); cross-references updated. |
| 2026-06-21 | (template) Initial version — env-via-script secret handling for skills; mirrors the skill-scan workflow's key handling. |
