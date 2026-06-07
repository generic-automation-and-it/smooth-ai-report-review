# LLM Eval Harness — chunk-review model

Scores the **chunk-review LLM** (the gate's blocking-findings call in
`review-in-chunks.sh`) against a labeled corpus on two axes, so prompt / model /
LADR changes can be **regression-tested** instead of being caught in production
by adding another DR. See **LADR-030** in `../../SKILL.md`.

> ⚠️ `run-evals.sh` / `local-evals.sh` make **real, paid model calls**. They are
> opt-in only — never in the default bash-test path. The default-path-safe test
> is `test-evals.sh` (stubbed model, no calls).

## Two axes

- **Precision — must-NOT-flag** (`corpus/must-not-flag/`): one+ fixture per
  **DR-001 … DR-014** (the confirmed-false-positive golden set). The reviewer
  must NOT re-raise any of them at Critical/High/Medium. **Zero tolerance** —
  any such flag fails the run.
- **Recall — must-catch** (`corpus/must-catch/`): fixtures with a seeded real
  defect the reviewer SHOULD flag at ≥ its labeled severity. The run fails if the
  catch rate drops below `EVAL_RECALL_THRESHOLD` (default 80%).

Output is parsed with the pipeline's own grammar (LADR-012): only `[VERIFIED]`
findings count; `[SPECULATIVE]` and "None found" never count as flags.

## Run it

```bash
# Local — handles credential harvest (shell rc) + macOS timeout shim, then runs:
./local-evals.sh                                   # GEMINI / default model
./local-evals.sh --provider OPENAI --model gpt-5.5 \
                 --recall-threshold 80 --samples 1 --filter DR-007

# CI — manual only: Actions → "LLM Eval Harness" → Run workflow (workflow_dispatch).
```

Reuses the exact CI provider/transport resolution: `lib/resolve-provider.sh` +
`lib/setup-opencode-config.sh` + `lib/opencode-health.sh` + the two-tier
`lib/opencode-with-fallback.sh` chain. **No new model transport.**

## Config (env)

| Var | Default | Meaning |
|---|---|---|
| `OPENCODE_PROVIDER` + `OPENCODE_MODEL_*` | GEMINI chain | provider/model, resolved exactly like CI |
| `EVAL_RECALL_THRESHOLD` | `80` | min must-catch catch-rate %% to pass |
| `EVAL_SAMPLES` | `1` | runs per fixture (>1 = precision worst-case, recall majority) |
| `EVAL_CORPUS_DIR` | `./corpus` | corpus root override |
| `EVAL_FILTER` | (unset) | only run fixtures whose id contains this substring |

## Add a fixture

Create `corpus/{must-not-flag|must-catch}/<id>/`:

- `manifest.json`:
  ```json
  { "id": "<id>", "kind": "must-not-flag" | "must-catch",
    "label": "DR-007" | "MC-002",
    "min_severity": "HIGH" | "CRITICAL",   // must-catch only
    "note": "one line" }
  ```
- `after/<repo/relative/path>` — post-change file(s); the whole tree is committed
  as the head. For a net-new file the entire file is the diff (fully reviewable).
- `before/<...>` *(optional)* — pre-change tree, for modify/delete fixtures
  (e.g. `DR-013`, `MC-003`). The harness commits `before/`, then `after/`, and
  reviews the diff between them.

The harness places the canonical DR standards
(`.github/instructions/code-review-standards.instructions.md` +
`corpus/context/code-review-standards-supplement.md`) at their production
dot-paths in each sandbox so the reviewer reads the same context production
injects via `MANDATORY_CONTEXT_FILES`.

## Files

| File | Role |
|---|---|
| `run-evals.sh` | core runner (real calls); resolve → config → health → drive `review-in-chunks.sh` → score → gate |
| `local-evals.sh` | local entrypoint: cred harvest + macOS `timeout` shim → `run-evals.sh` |
| `lib/score-review.sh` | parse a review's markdown → blocking severities (pipeline grammar) |
| `test-evals.sh` | **structural self-test (stubbed, no calls)** — safe for the default test path |
| `corpus/` | fixtures + DR-standards context supplement |

## Out of scope

Evals for the **orchestrator-tier** calls (semantic grouping, aggregation
summary — LADR-022) are not covered: they are classification/cosmetic, not
blocking. Possible follow-up.
