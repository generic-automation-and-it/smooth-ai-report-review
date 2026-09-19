# Security Policy

## Supported Versions

| Version | Supported |
| --- | --- |
| `main` / latest `v1` tag | ✅ |
| Older tags | ❌ — upgrade to the current major tag |

The floating major tag (`v1`) always points at the latest release on `main`. Fixes
land on `main` and the tag is moved; there are no backport branches.

## Reporting a Vulnerability

**Do not open a public issue for a security problem.**

Report privately through GitHub:

1. Go to the repository's **Security** tab → **Advisories** → **Report a vulnerability**.
2. Describe the issue, the affected file or workflow, and how to reproduce it.

Please include, where relevant: affected version or commit SHA, impact, and whether
any credential may have been exposed.

**Response targets** (best effort, this is a small maintainer team):

- Acknowledgement within 5 working days.
- An assessment and a remediation plan within 15 working days.
- Disclosure coordinated with the reporter once a fix is available.

## Scope

This repository ships a CI review gate — GitHub Actions workflows and shell/Python
scripts that run with repository credentials. The highest-value reports concern:

- Command, argument, or prompt injection reachable from PR-controlled content
  (branch names, PR titles/bodies, diff contents, file paths).
- Anything that could exfiltrate `GITHUB_TOKEN` or a provider API key, or widen the
  workflow permissions actually granted at run time.
- Supply-chain weaknesses in the install paths (`install-opencode.sh`,
  `build-code-graph.sh`, `install-rtk.sh`) or in the npm package.
- A path that lets untrusted input reach `pipeline-ai-analyse.yml`, which commits and
  pushes autonomously.

Out of scope: vulnerabilities in the upstream model providers, in opencode itself, or
in GitHub Actions — report those to their respective maintainers.

## Credential Handling

Credentials are **never** committed. Provider API keys are GitHub **Secrets**;
endpoint URLs, provider selectors, and model ids are GitHub **Variables**.
`.agents/skills/ai-review-report/assets/opencode.json` contains `{env:OPENCODE_*}`
placeholders only. If you believe a real key has been committed anywhere in this
repository or its history, report it through the private channel above and treat the
key as compromised — rotate it first, then report.

Note that this is also why **pull requests from forks are not accepted** (see
[CONTRIBUTING.md](CONTRIBUTING.md)): a fork PR runs without access to these secrets,
so the gate cannot validate itself against a fork.
