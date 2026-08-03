---
name: ai-review-report-eval
description: LLM eval harness for the chunk-review model (LADR-033). Use when adding/editing fixtures in `corpus/`, scoring logic in `lib/score-review.sh`, the runners (`run-evals.sh` / `local-evals.sh`), the self-test (`test-evals.sh`), or the eval workflow. Do NOT use for the parent skill's review pipeline scripts (`review-in-chunks.sh` etc.) — those are governed by the parent `ai-review-report` skill.
---

# Eval Harness — chunk-review model

The LLM eval harness for the `ai-review-report` skill. Regression-tests the
chunk-review LLM against a labeled corpus (the DR golden set + synthesized
seeded defects) so prompt / model / LADR changes don't silently re-introduce
known false positives or weaken real-defect detection. See **LADR-033** in
`../../SKILL.md` for the full context/decision narrative.

## TL;DR

Two-axis scored harness for the chunk-review LLM: **precision** (must-NOT-flag
the DR-001…014 golden set — zero-tolerance at Crit/High/**Med** on the fixture's OWN
`forbidden_claim`; unrelated true findings are reported, not blocking) and **recall**
(must-catch synthesized defects at ≥ labeled severity, threshold configurable).
Drives the real `review-in-chunks.sh` per fixture, reuses the CI transport
verbatim, makes paid model calls — opt-in only (local entrypoint,
`workflow_dispatch`, or the scope-checked `pull_request` required check),
never in the default bash-test path.

## Non-Negotiables

- **When repairing a `must-not-flag` fixture, REMOVE surface — never add scaffolding.** Every addition is new material for a reviewer to find, and this rule was learned twice the hard way: DR-015 got a `push` arm added to make a dead trigger live, and the reviewer immediately flagged the resolve step that had no `push` branch; DR-009 got a faithful `setup-opencode-config.sh` excerpt added to restore its gateway bait, and the reviewer flagged — correctly — that the excerpt returns 0 when `jq` is missing even though a URL variable is set. Both additions were defensible in isolation and both cost a full paid run. Prefer deleting the offending lines, and accept a thinner fixture: the injected DR context document already carries the explanation, so the fixture only has to carry the *shape*.
- **A `must-not-flag` fixture fails on its OWN claim, not on any finding.** Each manifest carries a `forbidden_claim` ERE describing the WRONG claim; a flagged Critical/High/Medium finding matching it fails the fixture, and true findings about anything else are counted as `Unrelated findings` and reported without blocking. This reverses the original severity-only rule, and the reversal is evidence-driven: across five paid runs (30766652401 … 30795770815) **every** precision failure was a correct finding and **not one** was a DR re-raise; five fixtures were repaired and the set never converged, because each run samples a different subset of what is findable in realistic code. Severity-only was measuring "did a thorough reviewer find anything at all", which is not what the corpus is for. A manifest with NO `forbidden_claim` keeps the strict behaviour — where the wrong claim cannot be expressed as a pattern (DR-014), silently loosening to "never fails" would be worse than staying strict. Unrelated findings are still fixture-hygiene debt worth clearing; they just no longer block a merge.
- **A `must-not-flag` fixture should still contain as little flaggable surface as possible.** The `forbidden_claim` rescope above stops unrelated findings from BLOCKING; it does not make them free. Each one is still a true statement about code the corpus presents as exemplary, it still shows up in the `Unrelated findings` tally, and it still costs a reader triage time. Three of the fourteen carried one on run 30766652401 — a stale `baseURL` in DR-009 contradicting its own injected context, a real `${{ inputs.pr_number }}` script-injection vector in DR-015, a `ToListAsync` whose result was only `.Count`ed in DR-007 — and the reviewer was right about all three. When adding or repairing a fixture, read the `after/` tree as if you were the reviewer and remove anything you would legitimately raise.
- **The fixture must also agree with the context injected beside it.** Every fixture is reviewed with `corpus/context/code-review-standards*.md` in scope. A fixture whose content contradicts its own DR text (DR-009 shipping the exact `{env:}` placeholder the DR calls a design violation) is not testing suppression — it is presenting the model with a real contradiction and punishing it for noticing.
- **A failed chunk is an INFRA failure, never a clean review.** `review-in-chunks.sh` writes a NON-EMPTY stub when the model chain is exhausted and drops a LADR-031 `chunk_<n>.failed` flag beside it, so the stub sails past any emptiness check and scores like a review with no findings — i.e. **every must-not-flag fixture passes**. Run 30791708130 is the proof: the provider was down for the entire run, all 20 fixtures got the stub, and the harness reported **precision 14/14 (100%)** having reviewed nothing. Only the recall half made it visible; a precision-only corpus would have gone green. `run_fixture` therefore checks for the flag file **before** the emptiness test, and detection is flag-file existence ONLY — never a grep for the stub text, per LADR-031, because a quoted marker inside a real review false-matched once already. `test-evals.sh` case K pins all three properties.
- **`EVAL_PARALLEL` trades wall-clock for rate-limit risk, and nothing else.** Fixtures run in a bounded worker pool (default 4, `wait -n` throttle, serial fallback below bash 4.3 since macOS ships 3.2). Isolation is not the constraint — each fixture builds its own sandbox and `cd`s into it, so the `ci_temp/` review-in-chunks.sh writes is per-fixture, and artifact copies are keyed on the fixture id. The shared resource is the **model endpoint**: every in-flight fixture is one live chunk-review call, and a rate-limited call fails the run as an INFRA failure. That is a flaky required check, which is precisely the state this harness was just rescued from — so raise the default only with evidence from a real run, never on the theory that more concurrency is free.
- **The driver tallies in launch order, never completion order.** A parallel run must produce a byte-identical RESULTS table to a serial one; `test-evals.sh` case I pins that by diffing the two tables. Workers cannot touch the parent's arrays or counters — each writes one `kind|id|verdict|detail` line to a result file and its console output to a log the driver replays in order. An INFRA verdict is counted as infra ONLY: putting it in the precision or recall denominator quietly understates both rates (the serial version avoided this with a `continue`, and it is the one thing to re-check if the counters are ever refactored again).
- **Do not trim the installed provider block to "just the provider under eval".** It looks like free savings — the eval runs one provider (`OPENCODE_REVIEW_REPORT_PROVIDER`, e.g. `OPENCODE-GO-ANTHROPIC`) while `setup-opencode-config.sh` installs all seven. It is not: opencode resolves an `@ai-sdk/*` package only for the provider it actually uses, and a full eval run installs **no** SDK package at all (checked against run 30766652401 — the only install line is the opencode binary itself). So the saving is zero, while the cost is real: `opencode-with-fallback.sh` accepts provider-qualified model targets (`go-openai/kimi-k2.7-code`, `openrouter/deepseek/…`), and any target naming a provider that was filtered out of the config fails at run time. `setup-opencode-config.sh` is shared with the production gate; a filter added for the eval's benefit changes the gate too.
- **Workflow ↔ script paths are coupled.** The eval workflow
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
│       ├── code-review-standards.md              # DR-001…011 snapshot
│       └── code-review-standards-supplement.md   # DR-012…015 supplement
├── README.md               # human-readable run guide
└── AGENTS.md               # this file
```

**Flow per fixture (real run, `EVAL_SELFTEST` unset):**
1. `mktemp` a sandbox, `git init`, commit `before/` (or empty base) as the
   base, then overlay `after/` and commit it as head. Net-new files = full
   review surface; modify/delete = real diff.
2. Assemble the canonical DR standards corpus snapshot and supplement at the
   production dot-path (so `MANDATORY_CONTEXT_FILES` injects the same context
   production uses): `.agents/skills/code-review-standards/SKILL.md`.
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
- **`pull_request`** — required status check (opened / synchronize / reopened /
  ready_for_review; draft and fork PRs skip via the job `if:`). Relevance is
  decided by the in-job `Scope check`, not a `paths:` filter (a path-skipped
  required check reports nothing and wedges the PR): only changes under
  `.agents/skills/ai-review-report/**` or the workflow itself pay for model
  calls — the eval scores the reviewer against a fixed corpus, so arbitrary
  PR content cannot change the result.
- **No `push`-to-`main` canary.** Retired: the PR gate scores the same paths
  before merge, so the canary re-ran the identical diff for a second paid
  bill. A merged fork PR that touched the pipeline needs a manual dispatch.

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
  full surface; the eval workflow exposes all the relevant env at job
  scope. Adding a new provider is a LADR-worthy change, not a one-line
  edit in `opencode.json`.

## Changelog

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-06-08 | Initial eval-dir AGENTS.md: fixture hygiene, `EVAL_ARTIFACT_DIR` triage archive, post-merge canary trigger, strict precision bar, and safe `test-evals.sh` path. | — |
| 2026-07-30 | Move the retired `.github/instructions` DR standards into the eval corpus and assemble them into `.agents/skills/code-review-standards/SKILL.md` inside each fixture sandbox. | — |
| 2026-08-03 | Retired the post-merge push-to-main canary trigger — the scope-checked `pull_request` required check scores the same paths before merge; merged fork PRs need a manual dispatch. | — |
