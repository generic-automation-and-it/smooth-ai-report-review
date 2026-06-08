---
name: ai-review-report-eval
description: LLM eval harness for the chunk-review model (LADR-033). Use when adding/editing fixtures in `corpus/`, scoring logic in `lib/score-review.sh`, the runners (`run-evals.sh` / `local-evals.sh`), the self-test (`test-evals.sh`), or the post-merge canary workflow. Do NOT use for the parent skill's review pipeline scripts (`review-in-chunks.sh` etc.) — those are governed by the parent `ai-review-report` skill.
---

# Eval Harness — chunk-review model

The LLM eval harness for the `ai-review-report` skill. Regression-tests the
chunk-review LLM against a labeled corpus (the DR golden set + synthesized
seeded defects) so prompt / model / LADR changes don't silently re-introduce
known false positives or weaken real-defect detection. See **LADR-033** in
`../../SKILL.md` for the full context/decision narrative.

## TL;DR

Two-axis scored harness for the chunk-review LLM: **precision** (must-NOT-flag
the DR-001…014 golden set, zero-tolerance at Crit/High/**Med**) and **recall**
(must-catch synthesized defects at ≥ labeled severity, threshold configurable).
Drives the real `review-in-chunks.sh` per fixture, reuses the CI transport
verbatim, makes paid model calls — opt-in only (local entrypoint or
`workflow_dispatch` / post-merge canary), **never on `pull_request`**, never in
the default bash-test path.

## Non-Negotiables

- **Workflow ↔ script paths are coupled.** The canary workflow
  (`.github/workflows/llm-eval-harness.yml`) invokes `scripts/eval/run-evals.sh`
  by hardcoded path, the same way the gate invokes `../review-in-chunks.sh`.
  Renaming or moving a file in this dir silently breaks the harness. Change
  the workflow YAML and the scripts in the same commit.
- **The harness makes real, paid model calls.** `run-evals.sh` and
  `local-evals.sh` are NEVER safe for the default test path. The
  default-path-safe test is **`test-evals.sh`** (stubbed via the
  `EVAL_SELFTEST` seam, 17/17 green on commit). A PR that accidentally
  exercises `run-evals.sh` from the default CI path burns real money.
- **Scoring uses the pipeline's own grammar (LADR-012).** Only `[VERIFIED]`
  Critical/High/Medium count as flags; `[SPECULATIVE]` and "None found"
  (case/whitespace/bold/period tolerant — see `lib/score-review.sh`) never
  count. Don't reimplement severity detection outside `lib/score-review.sh`;
  reuse it (or extend it there) so all sites stay consistent.
- **Precision is intentionally stricter than the production gate.** A
  re-raised DR at **Medium** fails the eval, even though the gate only blocks
  on `[VERIFIED]` Crit/High (LADR-012/015). Documented in `run-evals.sh` and
  LADR-033 — don't "fix" the bar to match the gate.
- **Env vars are namespaced `OPENCODE_REVIEW_REPORT_*`.** The legacy
  `OPENCODE_PROVIDER` / `OPENCODE_MODEL_*_REVIEW` / `OPENCODE_<P>_URL` /
  `OPENCODE_CLI_VERSION` names were retired in LADR-032 (#6). API-key Secrets
  keep their `OPENCODE_<P>_API_KEY` names. The eval sources the same
  designed-model Variables + Secrets the review gate uses, so it tests the
  designed models — not a hardcoded chain. `run-evals.sh` defaults
  `*_SECONDARY` / `*_ORCHESTRATOR` to the designed `*_PRIMARY` so a non-GEMINI
  chain stays same-family for `lib/resolve-provider.sh`; don't reintroduce
  hardcoded Gemini literals.

## Architecture

```
scripts/eval/
├── run-evals.sh            # core runner (real calls): resolve → config → health
│                           #   → drive review-in-chunks.sh per fixture → score → gate
├── local-evals.sh          # local entrypoint: shell-rc cred harvest + macOS
│                           #   timeout shim → exec run-evals.sh
├── test-evals.sh           # STRUCTURAL self-test (EVAL_SELFTEST=1, stubbed
│                           #   review). Default-path-safe, no paid calls.
├── lib/
│   └── score-review.sh     # parse review.md → blocking severities
│                           #   (LADR-012 grammar; placeholder-tolerant)
├── corpus/
│   ├── must-not-flag/      # DR-001…014 fixtures (one+ per DR). Each fixture
│   │   └── <id>/
│   │       ├── manifest.json
│   │       └── after/      # the post-change tree (the "diff")
│   │       └── before/     # OPTIONAL: pre-change tree (DR-013, MC-003)
│   ├── must-catch/         # MC-001…006 synthesized seeded defects with
│   │   └── <id>/           #   min_severity in their manifest
│   └── context/
│       └── code-review-standards-supplement.md   # DR-012…014 supplement
│                                               #   (rest is the repo's own
│                                               #   .github/instructions/...
│                                               #   instructions.md)
├── README.md               # human-readable run guide
└── AGENTS.md               # this file
```

**Flow per fixture (real run, `EVAL_SELFTEST` unset):**
1. `mktemp` a sandbox, `git init`, commit `before/` (or empty base) as the
   base, then overlay `after/` and commit it as head. Net-new files = full
   review surface; modify/delete = real diff.
2. Place the canonical DR standards at their production dot-paths (so
   `MANDATORY_CONTEXT_FILES` injects the same context production uses):
   `.github/instructions/code-review-standards.instructions.md` and
   `.agents/skills/code-review-standards/SKILL.md`.
3. `export OPENCODE_MODEL_ID=$OPENCODE_REVIEW_REPORT_MODEL_PRIMARY` and call
   the real `../review-in-chunks.sh` against the diff — this is the genuine
   eval target (prompt assembly + two-tier opencode chain), not a reimplemented
   prompt.
4. Concatenate `ci_temp/reviews/chunk_*.md`, score with `lib/score-review.sh`,
   gate on the fixture's `kind`:
   - `must-not-flag`: any of CRITICAL/HIGH/MEDIUM → FAIL (precision)
   - `must-catch`: a flag at ≥ `min_severity` in a majority of samples → PASS
     (recall); below `EVAL_RECALL_THRESHOLD` fails the whole run
5. **Triage archive (if `EVAL_ARTIFACT_DIR` is set)**: copy each fixture's
   concatenated review to `<id>.review.md` and infra-fail run logs to
   `<fixture>.lastlog`. The per-fixture sandbox + `WORK_ROOT` are wiped on
   EXIT, so without this a precision FAIL leaves no record of WHAT the model
   flagged — the archive is the only surviving evidence. The CI workflow
   sets `EVAL_ARTIFACT_DIR=ci_temp/eval-artifacts` and uploads it via
   `actions/upload-artifact` with `if: always()` (the eval step exits
   non-zero on regression, so the upload must run regardless).

**Triggers (CI workflow `llm-eval-harness.yml`):**
- **`workflow_dispatch`** — manual.
- **`push: branches: [main]`**, **path-filtered** to
  `.agents/skills/ai-review-report/**`,
  `.github/instructions/code-review-standards.instructions.md`, and the
  workflow itself. Post-merge canary: cannot block a merge; a regression
  surfaces as a failed run on the merge commit. The path filter keeps it
  cheap — the eval scores the reviewer against a fixed corpus, so arbitrary
  PR content cannot change the result; only the path-filtered files can.
- **NEVER on `pull_request`**. A PR touching the path-filtered files merges
  without paying for an eval, and the canary fires on the merge commit.

## Key Behaviors

- **The two axes are NOT symmetric.** Precision is **zero-tolerance** (any
  re-raise = run fail) because every DR is a confirmed false positive with a
  real PR reference. Recall is **threshold-gated** (default 80% catch rate)
  because model non-determinism and fixture noise make a single miss a
  poor run-fail signal. Don't collapse them into one knob.
- **A fixture must not itself contain a real defect.** The eval can only
  distinguish a DR re-raise from an unrelated finding if the fixture is
  clean-except-for-the-DR-pattern. If a fixture's `after/` has both the
  intentional pattern *and* a real bug (e.g. DR-001's prior get-only auto-
  props set in an object initializer → CS0200), any reviewer flag on the
  real bug gets miscounted as a DR re-raise. **Fixture hygiene is a
  correctness requirement, not a polish item.** Always include an inline
  "do NOT flag" steering comment in the fixture's `after/` files that
  names the DR-decision surface explicitly and carves out adjacent
  legitimate-review territory — the comment is what the model reads at
  review time, not the manifest. (See `DR-006-gha-uses-valid/after/...` and
  `DR-014-ladr-beats-prbody/after/...` for the working shape.)
- **`EVAL_SAMPLES=1` is the default; >1 amplifies noise, not signal.**
  Raising it makes precision `worst-case` over N samples (more sensitive to
  flakes) and recall `majority` (more forgiving). For diagnosing model
  flakiness, `EVAL_SAMPLES=3` with `EVAL_FILTER=DR-NNN` is more useful than
  blanket re-runs.
- **`test-evals.sh` must stay green.** It is the only path a PR can run in
  default CI without making paid calls. If you change `lib/score-review.sh`,
  `run-evals.sh`'s scoring call, or the result-table format, update the
  canned-review fixtures (`<id>/selftest-review.md`) and the aggregation
  cases in `test-evals.sh` accordingly. The selftest seam is the contract.
- **Self-test path → paid-call path is a one-way trip.** Once you add a
  paid-only code path that isn't exercised by `EVAL_SELFTEST`, the default
  test path can no longer regress-test it. The triage archive logic was
  added with the `EVAL_ARTIFACT_DIR` guard specifically to keep the
  default path unchanged.
- **DR-014 fixture scope gotcha.** A "must NOT flag" fixture protects the
  LADR's *chosen approach* — not the surrounding code. A legitimate
  [VERIFIED] Medium on adjacent defensive validation is *not* a DR-014
  re-raise, but the eval will count it as one. When authoring a DR fixture
  that mixes LADR-decision code with surrounding code, the steering
  comment must explicitly carve out "adjacent code" as out-of-scope. See
  the `DR-014` fixture's `<summary>` for the wording pattern.
- **Triage archive lives or dies on `EVAL_ARTIFACT_DIR`.** When unset
  (default for `local-evals.sh` and the self-test), no archive is written.
  When the CI workflow sets it, both per-fixture reviews and infra-fail
  run logs are copied. The directory is the **only** record of a FAIL —
  inspect it before deciding whether a regression is real or fixture
  hygiene.
- **Don't bake fixture content into `run-evals.sh`.** The corpus is data,
  not code. New DRs and new MCs go under `corpus/`, not into the runner.
  The runner's only corpus-touching code is the manifest walk and the
  per-fixture sandbox setup.

## Quality Constraints

- **All scoring / gating logic must be testable via `EVAL_SELFTEST`.** No
  branch of `run-evals.sh` that runs in the real path should be unreachable
  in the selftest. If you add a new feature (e.g. a new gate type, a new
  severity rule), add a corresponding canned review and a `Part N` case
  in `test-evals.sh`.
- **No new model transport.** The harness reuses `lib/resolve-provider.sh` +
  `lib/setup-opencode-config.sh` + `lib/opencode-health.sh` + the two-tier
  `lib/opencode-with-fallback.sh`. If you find yourself wanting to call
  `opencode` directly (or to add a new env var like a second model chain),
  stop — the test target is the existing transport, and adding a parallel
  path means the eval no longer exercises what production uses.
- **No silent model transport changes.** `OPENCODE_REVIEW_REPORT_*` is the
  full surface; the canary workflow exposes all the relevant env at job
  scope. Adding a new provider is a LADR-worthy change, not a one-line
  edit in `opencode.json`.

## Changelog

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-06-08 | Initial AGENTS.md for the eval dir. Captures the LADR-033 follow-up
| state: must-NOT-flag fixture hygiene (DR-001/006/014 steering comments),
| the `EVAL_ARTIFACT_DIR` triage archive, the post-merge canary trigger
| (path-filtered to `.agents/skills/ai-review-report/**`,
| `code-review-standards.instructions.md`, the workflow), and the eval's
| intentionally-stricter Crit/High/Med precision bar. Test path is still
| `test-evals.sh` (17/17 green); default-path cost unchanged. | — |
