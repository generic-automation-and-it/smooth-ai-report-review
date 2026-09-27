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
- **A `must-not-flag` fixture fails on its OWN claim, not on any finding.** Each manifest carries a `forbidden_claim` ERE describing the WRONG claim; a flagged Critical/High/Medium finding matching it fails the fixture, and true findings about anything else are counted as `Unrelated findings` and reported without blocking. This reverses the original severity-only rule, and the reversal is evidence-driven: across five paid runs (30766652401 … 30795770815) **every** precision failure was a correct finding and **not one** was a DR re-raise; five fixtures were repaired and the set never converged, because each run samples a different subset of what is findable in realistic code. Severity-only was measuring "did a thorough reviewer find anything at all", which is not what the corpus is for. A manifest with NO `forbidden_claim` keeps the strict behaviour, and the mechanism is retained for that case — but **no shipped fixture relies on it any more**. DR-014 was the last one, and staying strict cost it 2 of 3 samples (run 35322499612 attempts 2 and 3, run 35329091011) on a *true* finding about connection-string validation that the fixture's own docstring already declares out of scope — in prose the scorer cannot read. The claim turned out to be expressible after all: it is an objection to LADR-10's **chosen approach** (demanding a discriminator column or global query filter, arguing for a shared/single database, calling database-per-tenant unscalable or an anti-pattern, or asserting isolation is unenforced because it rests on connection-string selection). The hazard when adding a claim is the mirror image of staying strict: a pattern loose enough to match anything makes the fixture **unfailable**, which is worse than the red it replaces and is invisible in a green run. So pin every new claim from BOTH sides in `test-evals.sh` Case Q — it must fire on the re-raise phrasings and must not fire on the adjacent true findings — and mutation-test it (Case Q catches both `forbidden_claim: "tenant"` and a never-matching pattern). Unrelated findings are still fixture-hygiene debt worth clearing; they just no longer block a merge.
- **A `must-catch` `min_severity` states what the finding must BLOCK at, not how alarming the defect sounds.** Critical and High both produce `request-changes` (see SKILL.md's decision matrix), so demanding CRITICAL where HIGH already blocks buys no protection and only makes the fixture fail on a reviewer's tier choice. Two bars were recalibrated on 2026-09-18 against runs 35322499612 attempts 2 and 3 (`gpt-5.6-sol`, `EVAL_SAMPLES=1` each), where both fixtures failed **identically twice** while quoting the exact seeded line — a reproduced signature, not sampling noise. **MC-004** (SQL injection via interpolated `FromSqlRaw`) went CRITICAL → HIGH: it was the corpus's only CRITICAL, and MC-005 already grades a comparable security defect (hardcoded secret) at HIGH, so the old bar was internally inconsistent with its own neighbour. **MC-003** (reachable null-guard deleted) went HIGH → MEDIUM: the null input already threw before the change, so what regresses is the exception *type* and message quality rather than success-to-failure — materially milder than **MC-001**, where an always-null navigation property turns a working path into an unconditional throw, and MC-001 keeps HIGH precisely to preserve that distinction. **Know the cost before copying this move**: MEDIUM does not block, and per LADR-042 `ai-analyse` selects autonomous fixes on severity, so an MC-003-class regression is now inside the autonomous fixer's remit rather than a human's. That is acceptable for restoring a deleted guard and would not be for a defect whose correct fix is a judgement call. Lower a bar only with a reproduced signature and a named sibling fixture it is being made consistent with; never to make a red eval green.
- **A `must-not-flag` fixture should still contain as little flaggable surface as possible.** The `forbidden_claim` rescope above stops unrelated findings from BLOCKING; it does not make them free. Each one is still a true statement about code the corpus presents as exemplary, it still shows up in the `Unrelated findings` tally, and it still costs a reader triage time. Three of the fourteen carried one on run 30766652401 — a stale `baseURL` in DR-009 contradicting its own injected context, a real `${{ inputs.pr_number }}` script-injection vector in DR-015, a `ToListAsync` whose result was only `.Count`ed in DR-007 — and the reviewer was right about all three. When adding or repairing a fixture, read the `after/` tree as if you were the reviewer and remove anything you would legitimately raise.
- **The fixture must also agree with the context injected beside it.** Every fixture is reviewed with `corpus/context/code-review-standards*.md` in scope. A fixture whose content contradicts its own DR text (DR-009 shipping the exact `{env:}` placeholder the DR calls a design violation) is not testing suppression — it is presenting the model with a real contradiction and punishing it for noticing.
- **A failed chunk is an INFRA failure, never a clean review.** `review-in-chunks.sh` writes a NON-EMPTY stub when the model chain is exhausted and drops a LADR-031 `chunk_<n>.failed` flag beside it, so the stub sails past any emptiness check and scores like a review with no findings — i.e. **every must-not-flag fixture passes**. Run 30791708130 is the proof: the provider was down for the entire run, all 20 fixtures got the stub, and the harness reported **precision 14/14 (100%)** having reviewed nothing. Only the recall half made it visible; a precision-only corpus would have gone green. `run_fixture` therefore checks for the flag file **before** the emptiness test, and detection is flag-file existence ONLY — never a grep for the stub text, per LADR-031, because a quoted marker inside a real review false-matched once already. `test-evals.sh` case K pins all three properties.
- **`EVAL_PARALLEL` trades wall-clock for rate-limit risk, and nothing else.** Fixtures run in a bounded worker pool (default 4, `wait -n` throttle, serial fallback below bash 4.3 since macOS ships 3.2). Isolation is not the constraint — each fixture builds its own sandbox and `cd`s into it, so the `ci_temp/` review-in-chunks.sh writes is per-fixture, and artifact copies are keyed on the fixture id. The shared resource is the **model endpoint**: every in-flight fixture is one live chunk-review call, and a rate-limited call fails the run as an INFRA failure. That is a flaky required check, which is precisely the state this harness was just rescued from — so raise the default only with evidence from a real run, never on the theory that more concurrency is free.
- **The driver tallies in launch order, never completion order.** A parallel run must produce a byte-identical RESULTS table to a serial one; `test-evals.sh` case I pins that by diffing the two tables. Workers cannot touch the parent's arrays or counters — each writes one `kind|id|verdict|detail` line to a result file and its console output to a log the driver replays in order. An INFRA verdict is counted as infra ONLY: putting it in the precision or recall denominator quietly understates both rates (the serial version avoided this with a `continue`, and it is the one thing to re-check if the counters are ever refactored again).
- **Do not trim installed provider config to selected eval provider.** opencode resolves SDK package only for provider used, so saving is zero. Provider-qualified fallback targets may name another configured provider, including `go-responses`; filtering breaks them at runtime.
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

- **Decision-model scoring (LADR-093) is MEASURED here, never gated on.** The
  gate verdict comes from pre-merge chunk markdown and stays exactly as it was;
  with `EVAL_DECISIONS` on (default: the gate's own
  `OPENCODE_REVIEW_REPORT_ENABLE_DECISIONS`), `run-evals.sh`'s
  `record_decisions` additionally runs the production post-merge path on each
  sample's real sidecars — `merge-findings.sh`, then
  `score-findings-decisions.sh` in **annotate** — and writes one record per
  fixture-sample. `lib/decisions-report.py` then prints, after the verdict:
  (1) Jev's `supported` distribution for **known false positives** (a DR
  fixture's `[VERIFIED]` Critical/High/Medium matching its `forbidden_claim`)
  versus **true catches** (a must-catch fixture's `[VERIFIED]` finding at or
  above `min_severity`), with an AUC; (2) how Jev's severity lands on each; (3)
  what `filter@t`, `demote@t` (VERIFIED→SPECULATIVE) and `sev@c` (adopt Jev's
  severity above a confidence) would have done to DR re-raises and catches.
  Policies are applied **offline** to the annotate answers, so one paid run
  measures all of them and the measured document is never altered. Four rules:
  it must never assign `fail` or abort the run (`test-decisions-report.sh`
  greps for both); a sample whose decisions failed is **excluded** and named,
  never counted as clean; a sample with no findings **is** counted (a clean DR
  fixture and a missed catch are real outcomes); and the ground truth is the
  corpus, matched on the structured title + rationale — the harness matches the
  markdown line, and the structured set is post-confidence-gate, so both
  baselines are reported rather than assumed equal. Treat any single run as a
  hint: act on a policy only when it removes DR re-raises **without** losing a
  catch across several runs (`EVAL_SAMPLES` > 1).
- **Planted findings calibrate the decision model where the reviewer cannot.**
  A good chunk model raises almost no known false positives, so the measurement
  above had nothing to judge on the precision side (run 36303910662: 0
  re-raises, AUC n/a). Every must-not-flag manifest therefore carries
  `known_false_positive` — the exact wrong claim the fixture forbids, phrased to
  match its own `forbidden_claim` — and every must-catch manifest carries
  `known_true_positive`, both quoting a real line (`evidence_line`).
  `calibrate-decisions.sh` scores each one alone through the production scorer
  against the fixture's real diff, in two variants: **as-is** and **stripped**
  (code comments removed — the fixtures explain themselves in comments such as
  "DO NOT flag … intentional", which would hand the judge the answer key). It
  calls only the decision provider, runs after the measurement when
  `EVAL_DECISIONS` is on, and never changes `fail`. Keep the planted text honest:
  a wrong claim must read the way a reviewer would actually write it, and its
  title + rationale must match the fixture's `forbidden_claim` —
  `test-decisions-report.sh` 4e fails otherwise.
  **First result (2026-09-27, `jev-1.13`, one sample):** true catches scored
  0.58–0.97, so no policy lost a catch at 0.25 or 0.5 in either variant.
  Separation: AUC **0.93** as-is, **0.77** stripped. Jev rejects false
  positives the code itself contradicts (invalid action ref 0.11, SDK mismatch
  0.16, missing write key 0.16, tenant discriminator 0.25) and accepts those that
  are true of the code but exempt by project policy (no max length 0.84,
  throwing getter 0.85, sequential queries 0.88, no LangVersion 0.77, removed
  rethrow 0.86) — `supported` judges evidence, and the project's standards are
  not in its state. It also reads comments: DR-012 moved 0.11 → 0.60 and DR-015
  0.26 → 0.80 when they were removed, so `review_rules.untrusted_content` does
  not neutralise in-diff argument. Severity is a weak lever: only 1/14 planted
  false positives drops below Medium on code alone, and Jev escalates one
  (removed rethrow) to Critical. Read as: tag demotion / filter at 0.5 is a
  plausible, catch-safe candidate on this corpus; severity reconciliation is
  not; and the policy-exempt class needs project rules in the judge's state.
  **Second result (same day): project rules close most of the gap.** A third
  variant, `stripped+rules`, passes the corpus's DR standards as the scorer's
  optional rules file (5th argument), which adds the `sanctioned` question —
  "does a project rule declare this pattern acceptable?", kept separate from
  `supported` so evidence and policy stay distinguishable. `sanctioned`
  separated the planted false positives (mean 0.73) from the true catches (all
  ≤ 0.11) with AUC **0.99**, and `supported` itself rose to AUC 0.99 with the
  rules present. `either@0.50` (drop when `supported` < 0.5 or `sanctioned` ≥
  0.5) removed **13 of 14** false positives and lost **no** catch. MC-001 — a
  materialized NRE that DR-012's expression-tree exemption does not cover —
  scored `sanctioned` 0.11, so Jev checked the rule's conditions rather than
  its topic. The one survivor is DR-013 (mode-aware dead code), which needs
  reasoning about the removed code path; Jev still rates it Critical. Severity
  also improves with rules (9/14 false positives rated below Medium, against
  1/14 without), but `sev@c` gains little because Jev's severity confidence is
  mostly below 0.6. Re-running the stripped variant moved scores by at most
  0.05, so a single run is close to deterministic. Caveat: these rules were
  written for these fixtures and name each pattern; a real repository's
  standards are less targeted, so this is an upper bound until measured on one.
  **Re-run after the DR-002 plant fix** (its rationale had also claimed a real
  divergence defect, so it was not a clean test of the forbidden claim):
  as-is AUC 0.93, code-only 0.80, with rules `supported` 0.98 and `sanctioned`
  1.00; `either@0.50` still removes 13/14 with no catch lost. The numbers moved
  by at most 0.03, consistent with the near-deterministic behaviour above.
- **Real findings overrule planted ones — and on the first 12 they disagree.**
  `corpus/real-findings/` holds live gate findings with a human verdict and the
  score the gate computed at the time (`harvest-real-findings.sh <run>
  <n>=tp|fp`; committed because run artifacts expire, never re-scored).
  `calibrate-decisions.sh` prints them as a fourth report at no cost. The first
  twelve — every finding both gate reviews of PR 169 raised, all accepted and
  fixed — scored `supported` mean **0.43** (0.12–0.88); `filter`/`demote@0.50`
  would have hidden **9 of 12** real problems, and even `@0.25` two. Planted true
  catches never went below 0.58. The difference is the kind of finding: planted
  catches are single-line defects whose quoted line proves them; real review
  findings describe behaviour across code ("a PR-level answer can make unscored
  findings look scored"), which the one hunk around one line in the judge's
  state cannot demonstrate. Conclusion until real false positives are labelled
  too: **`supported` must not demote or filter anything**; it is a display, and
  the rules-based `sanctioned` question is the more promising lever. Label every
  skipped gate finding as `fp` when processing reviews, so the precision side
  gets real data.
- **Labels now come from `/ai-review execute` itself (LADR-096).** On a scored
  run the posted review carries `<!-- ai-review-report run=<id> -->`; execute
  writes an invisible `ai-review-decisions` block (`N: fix` / `skip intentional`
  / `skip invalid` / `skip deferred`) into the PR description, and
  `harvest-real-findings.sh --from-pr N` or `--scan [--limit N]` turns it into
  records with `label_reason`. **`deferred` and anything unrecognised are never
  harvested**: a mislabelled `fp` is the dangerous direction, because it makes a
  suppressing policy look safe. The **latest** decision per finding wins,
  deferred included: a later deferred removes an earlier record, and a
  correction refreshes it — or removes it when the artifact has expired, because
  a superseded label must never survive. Otherwise harvesting is idempotent and
  reports and skips expired artifacts, so a periodic `--scan` of each consumer
  repo inside the retention window is the whole procedure. Live gate records now also carry
  `sanctioned` (per-chunk rules) and `previously_skipped` (the PR's Skip Areas);
  the report adds section 1c and the `skipped@0.50` policy when present. Neither
  may act until the real set shows zero lost true positives (LADR-096 roadmap,
  phase 5).
- **`fix_skip` is measured, and the eval scores what the gate scores (LADR-098).**
  `calibrate-decisions.sh` and `run-evals.sh`'s `record_decisions` call the scorer
  exactly as Step 17.6 does: `fix_skip` asked (optionally), the code context read
  at the sandbox head, and — for the eval — the per-chunk rules in `ci_temp`
  (before this the eval scored without them, unlike the gate). Records carry
  `fix_skip`, `fix_skip_p` and `code_context`. `decisions-report.py` prints a
  `1d.` section only when fix_skip was asked: P(skip) by ground truth with AUC,
  predicted FIX on a known false positive, predicted SKIP on a true catch (a fix
  the autonomous filter would withhold), the human `label_reason` against the
  predicted class, and **how many answers came with a distribution** — the live
  check that the provider returns `probabilities.fix`, without which consumers
  never act. The `fixskip@0.50` policy row is what `ai-analyse`'s
  `OPENCODE_ANALYSE_DECISIONS_MODE=filter` would have withheld. The harvester
  keeps the full reviewed `head`, the base branch tip as `base_tip` (not the
  merge base — a re-score resolves that itself, LADR-075) and the gate's `fix_skip`
  prediction next to the human label (a score, never a label), so a record can
  be re-scored later. The code context changes the evidence the judge sees, so
  scores are not comparable with records from before it; run a calibration with
  `OPENCODE_REVIEW_REPORT_DECISIONS_CODE_CONTEXT=0` for the hunk-only baseline.
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
| 2026-09-27 | `fix_skip` measured: calibration and the eval call the scorer as the gate does (fix_skip, code context; the eval also passes the chunk rules), records carry `fix_skip`/`fix_skip_p`/`code_context`, `decisions-report.py` adds section 1d and `fixskip@0.50`, and the harvester keeps the full reviewed head, the base tip (`base_tip`) and the gate prediction. | LADR-098 |
| 2026-09-27 | `/ai-review execute` writes `ai-review-decisions` label blocks; `harvest-real-findings.sh --from-pr` / `--scan` harvest them (fix → tp, skip intentional/invalid → fp, deferred never); records and the report carry `previously_skipped` (section 1c, `skipped@0.50`). | LADR-096 |
| 2026-09-27 | Real, human-labelled findings (`corpus/real-findings/`, `harvest-real-findings.sh`): the 12 accepted PR 169 findings scored mean 0.43, so filter/demote at 0.5 would hide 9 of 12 — planted catch-safety does not transfer. | LADR-093 |
| 2026-09-27 | `stripped+rules` calibration variant and the scorer's optional rules file / `sanctioned` question: AUC 0.99, `either@0.50` removes 13/14 planted false positives with no catch lost; DR-013 is the only survivor. | LADR-093 |
| 2026-09-27 | Planted findings: `known_false_positive` / `known_true_positive` in every manifest and `calibrate-decisions.sh` (as-is + stripped variants), run with the measurement. First result recorded above: catch-safe at 0.5, AUC 0.93 as-is / 0.77 code-only, severity reconciliation not supported. | LADR-093 |
| 2026-09-27 | Decision-model scoring is now measured: `EVAL_DECISIONS` runs `record_decisions` (real merge + scorer in annotate) per sample and `lib/decisions-report.py` reports separation (AUC) and what filter/demote/severity policies would have done, after the verdict and without ever changing it. `test-decisions-report.sh` covers it offline. | LADR-093 |
| 2026-09-24 | Recorded that LADR-093 decision-model scoring is invisible to this harness (it scores pre-merge chunk markdown) and what the post-merge measurement leg for issue #156 PR C must do. | LADR-093 |
| 2026-06-08 | Initial eval-dir AGENTS.md: fixture hygiene, `EVAL_ARTIFACT_DIR` triage archive, post-merge canary trigger, strict precision bar, and safe `test-evals.sh` path. | — |
| 2026-07-30 | Move the retired `.github/instructions` DR standards into the eval corpus and assemble them into `.agents/skills/code-review-standards/SKILL.md` inside each fixture sandbox. | — |
| 2026-08-03 | Retired the post-merge push-to-main canary trigger — the scope-checked `pull_request` required check scores the same paths before merge; merged fork PRs need a manual dispatch. | — |
