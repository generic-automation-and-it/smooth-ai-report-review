# Contributing

Thanks for your interest in `smooth-ai-report-review`. This repository's deliverable
is the automated PR review gate itself — GitHub Actions workflows plus the skills
under `.agents/skills/` — not application code.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security
problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Branches, not forks

**Pull requests from forks are not accepted.** Contribute from a branch in this
repository; ask an organization owner for write access (open an issue titled
"Access request" describing what you want to work on).

This is a deliberate constraint, not gatekeeping. The review gate is an agentic
workflow: every PR is reviewed by `pipeline-code-review-report.yml`, which needs the
repository's provider API keys (GitHub Secrets) and a `GITHUB_TOKEN` that can post
reviews. GitHub withholds secrets from fork-originated `pull_request` runs, so a fork
PR cannot exercise the very pipeline it is changing — the change would be unreviewable
by the tool it modifies. Fork PRs will be closed with a pointer to this section.

## Getting started

```bash
git clone https://github.com/generic-automation-and-it/smooth-ai-report-review.git
cd smooth-ai-report-review
git checkout -b <yourname>/<short-topic>
```

No build step and no runtime dependencies to install for most changes — the gate is
Bash plus a little Python, and the tools it uses (`opencode`, `code-review-graph`,
`rtk`) are installed by the workflow at run time.

## Read these first

Before changing anything under `.agents/skills/` or `.github/workflows/`:

- [`CLAUDE.md`](../CLAUDE.md) — the Non-Negotiables. Read them; several are
  load-bearing invariants that a reasonable-looking edit silently breaks.
- [`AGENTS.md`](../AGENTS.md) — repository-wide agent context.
- [`.agents/skills/ai-review-report/SKILL.md`](../.agents/skills/ai-review-report/SKILL.md)
  and its companion `AGENTS.md`, which carries the LADR decision log.

The constraints that trip people up most often:

- **Workflow YAML and scripts are coupled.** Script paths are hardcoded in the
  workflows. Move or rename a script, and change the workflow, in the same commit.
- **`run-review.sh` is the gate's single source of truth.** New *review* behaviour
  goes there, driven by environment variables — not `inputs.*` or `steps.*.outputs`.
  A new env var must be added to **both** `pipeline-code-review-report.yml` and
  `.docs/examples/code-review-local.yml` in the same commit.
- **Never commit a credential.** `assets/opencode.json` holds `{env:OPENCODE_*}`
  placeholders only.
- **Everything lives under `.agents/`, never `.ai/`.**
- **Nothing that reaches a posted review body may contain `#` followed by digits**
  (GitHub autolinks it — LADR-067).

## Testing

The suites are plain Bash and run offline — no model calls, no network:

```bash
failed=0
for t in .agents/skills/ai-review-report/scripts/test-*.sh; do
  echo "== $t"
  bash "$t" || failed=1
done
test "$failed" -eq 0
```

Run the suite for anything you touched, plus any suite that greps the source you
changed (several pin exact call-site strings deliberately). Add a test with a
behaviour change — most libs under `scripts/lib/` have a matching `test-*.sh`.

`scripts/eval/` makes **real, paid** model calls. `eval/test-evals.sh` is the
default-path-safe, stubbed variant; `eval/local-evals.sh` is not. Don't run the paid
evals casually.

## Commits and pull requests

- **Conventional commits**: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `refactor:`,
  `test:`. Reference the issue where there is one.
- Include `/ai-review` in the message of the commit that ends up as HEAD when you
  push — that is what triggers a full gate review. The `git-commit-review-push` skill
  does this for you, placing the trigger before any trailer block so
  `Co-authored-by:`/`Signed-off-by:` still parse as trailers.
- Target `main`. Fill in the PR template — in particular **Skip Areas / Known
  Issues**, which the gate reads to avoid re-raising findings you have intentionally
  accepted.
- Keep versions in lockstep when you bump them: `package.json` and
  `.claude-plugin/plugin.json` must match, and a `vX.Y.Z` release tag must match both.

## Responding to the review

The gate posts one consolidated review per run. Use `/ai-review` to work through it
with fix/skip decisions. If you skip a Critical or High finding, the rationale
**must** land in the PR description's "Skip Areas / Known Issues" bullets — the
summary table alone does not propagate the decision, and the finding will be raised
again on the next run.

`ai-analyse` may autonomously fix Medium/Low findings on your PR. It never edits
tests or evals, and never makes a failing test green — a red test is a decision for
a human.

## Reporting bugs and requesting features

Open an issue. For a bug, include: what you expected, what happened, the workflow run
URL if it is a CI failure, and the relevant `OPENCODE_*` Variable values (**never** a
Secret's value).
