# Distribution and Evaluation — High-Level Design

| | |
|---|---|
| **Status** | Accepted |
| **Owner** | Repository platform |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [SKILLS_INSTALLER.md](../../../scripts/SKILLS_INSTALLER.md) + [plugin.json](../../../.claude-plugin/plugin.json) + [llm-eval-harness.yml](../../../.github/workflows/llm-eval-harness.yml) at `0a8a7a2`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-17 |

> Design record for the delivered distribution and evaluation platform. It states **intent + spec**;
> execution sequencing lives in the issue tracker.

## Intent

A review gate is only trustworthy if every consumer runs the same pinned code and if regressions are
measured before release. This design specifies the supported consumption paths, the installer that
places the skills, the layered evaluation that protects the gate, and the single version manifest
that keeps channels aligned.

## Key Goals

### 1. Give every channel one source of truth

The reusable workflow side-checks pinned tooling; the local-job caller checks out this repository at
a pinned commit; the installer copies the owned skills; the marketplace exposes the same skill
folders; and the copy-install path is documented. The installer and marketplace deliver skills, not
the CI gate. No channel carries its own copy of gate logic.

**Acceptance criteria / DoD**

- Every gate-running channel resolves the same entrypoint; every skill channel resolves the same
  skill folders.
- Each channel states its pin explicitly and resolves the same artifacts. RTK pins differ by
  channel: the reusable workflow's `rtk_version` input wins over the
  `OPENCODE_TOOL_RTK_VERSION` Variable, while the local-job packaging reads only the Variable.
- No channel requires a second copy of review behavior to stay current.

### 2. Keep the installer self-contained

The installer owns only its own store and manifest, installs skills only, and never edits another
tool's configuration beyond its documented profile exception. Both language ports implement one
contract, and the optional report and analyse skills stay behind an explicit flag.

**Acceptance criteria / DoD**

- The owned skill lists are identical in both ports after normalization.
- Repeated runs reconcile flags without duplicating state.
- A corrupt manifest is a hard error and is left untouched.
- No tool configuration file is read or written outside the documented profile block.
- Purging removes only links whose target is inside the installer's own store.

### 3. Layer evaluation by cost and trust

The secret-free `opencode-v2-regressions` job blocks relevant pull requests, including drafts and
forks. The paid `llm-evals` job, driven by `run-evals.sh`, runs report-only and never blocks. The
evaluation corpus measures precision and recall against labeled expectations.

**Acceptance criteria / DoD**

- The `opencode-v2-regressions` job needs no secret and no network model call.
- Relevance is checked inside the job so branch protection always receives a result.
- The `llm-evals` job never blocks a merge.
- Eval precision is judged per sample by majority over repeated samples against a labeled corpus.
- The corpus includes a deletion-regression recall fixture, and the paid run reports graph-hint
  uptake and accuracy and autonomous-skip recurrence as report-only series.

### 4. Keep versioning singular

The plugin manifest is the only version manifest. A release bumps its version, tags the release, and
`update-major-tag.yml` derives the floating major tag (`vN`) from that version and moves it to the
default-branch HEAD; it does not validate release tags. The retired package channel is not
reintroduced.

**Acceptance criteria / DoD**

- A release bumps `plugin.json`, tags the release, and moves `vN` to the default-branch HEAD.
- The updater derives `vN` from the manifest's major version and points it at the default-branch HEAD.
- No package manifest or publish workflow exists.
- No consumer channel depends on a package registry.

### 5. Expose a documented input surface

The reusable workflow accepts the model, preset, draft, Claude Code, file-limit, mandatory-context,
config and review-scope inputs. The caller example documents every input and its precedence, and the
preset dropdown and draft guard are duplicated across all three packagings.

**Acceptance criteria / DoD**

- Every input is documented in the caller example with its precedence.
- The preset dropdown is duplicated wherever the dispatch form is defined.
- The draft guard is duplicated in all three packagings and extended together.

## Core Separation of Concerns

> One source of truth, many delivery channels, and an evaluation layer that never ships the gate.

Distribution moves the same artifacts; it does not fork behavior. Evaluation observes the gate from
outside, so it can fail without changing what consumers run. Versioning names the artifacts once.

## Guiding Principle — Distribute the same code, prove it from outside

- A consumer's channel is a delivery mechanism, not a variant.
- Evaluation is an independent observer, never a runtime dependency.
- A version exists in exactly one place.

## Related HLDs

- [HLD index](../README.md) — ownership map, numbering convention and source precedence.
- [001 PR Review Gate Pipeline](../001-review-gate-pipeline/README.md) — the artifact being distributed.
- [005 Autonomous Low and Medium Fixer](../005-autonomous-fixer/README.md) — the optional skill behind the install flag.

---

## Diagrams

- [System Context (C1) + delivery channels](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-five-consumption-paths.md) | Five consumption paths share one source of truth | Accepted |
| [LADR-02](./ladrs/LADR-02-installer-owns-its-state.md) | The installer owns its own state and installs skills only | Accepted |
| [LADR-03](./ladrs/LADR-03-offline-blocking-evals.md) | Offline regressions block; paid model evals report only | Accepted |
| [LADR-04](./ladrs/LADR-04-single-version-manifest.md) | The plugin manifest is the only version manifest | Accepted |

## Non-Functional Requirements

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-installer-parity.md) | Installer parity | Identical owned lists; idempotent reconciliation | Accepted |
| [NFR-02](./nfrs/NFR-02-offline-regression-independence.md) | Evaluation independence | Blocking suite needs no secret or model call | Accepted |
| [NFR-03](./nfrs/NFR-03-version-tag-consistency.md) | Version consistency | Major tag always matches the manifest version | Accepted |
| [NFR-04](./nfrs/NFR-04-measurement-visibility.md) | Measurement visibility | Every reappearing skip counted or `unavailable`; hint metrics never gate | Accepted |

Eval corpus and harness assets are owned by the `ai-review-report` skill; this HLD governs their
gating and release role.
