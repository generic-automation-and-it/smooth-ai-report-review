# PR-AF assessment — what was carried, deferred and rejected

Edit-time record only: `references/` is never read during a review. The runtime
rules live in `SKILL.md` and `AGENTS.md`; this document preserves the decision
basis so the comparison does not have to be re-litigated.

Sources: the reconciled plan (local, 2026-11-14), three review-pass
reconciliations of competing carry-over plans, and PR-AF's implementation under
`internal/` (read directly, not its documentation). Feature **#229** bounds the
work; the four adopted units landed as LADR-118 through LADR-121.

## Benchmark position

The repository's own results file (`martian-code-review-bench/RESULTS.md`) puts
PR-AF (GLM-5.2 alone, one open model) at:

- **#2 of 42 in golden recall — 0.706**, behind cubic-dev's 0.741 and ahead of
  cubic-v2's 0.699.
- **Adjusted F1 0.82** (precision 0.86, recall 0.78), the same top tier as
  cubic-dev 0.88 and cubic-v2 0.89.
- **595 valid findings** versus cubic-dev's **195** (golden 81, real non-golden
  341, valid nits 173).
- Coverage of **38 of 50 PRs** (the other 12 are unrunnable: 10 Discourse
  rebase-merged commits with no PR number, 2 synthetic Sentry entries), scored
  by one independent judge, `anthropic/claude-sonnet-4.6`.

The results file's own headline also claims "#1 in real findings delivered".
That is a self-published count of comments an independent reviewer judged valid,
not a benchmark rank: **the golden-recall position is #2 of 42**. The root
README's first-place claim is not supported by this evidence and is not repeated
here.

## Disposition of PR-AF mechanisms

| Mechanism | Value | Disposition | Reason |
| --- | --- | --- | --- |
| Evidence grounding (quote verification) | High | **Adopted — LADR-119** | The gate checked only that a quote was present, never that it existed; a deterministic tree read closes it with no model call and no schema key. |
| Adversary with caller context | High | **Adopted — LADR-120** | The decision judge could not answer "is there an upstream guard?"; caller edges from the existing code graph supply it without a second agent or a new question. |
| Run-level wall-clock ceiling | Medium | **Adopted — LADR-121** | Per-chunk and stall budgets existed but nothing bounded the run; PR-AF's benchmark shows a phase-boundary check cannot interrupt a call, so the deadline stops new work only. |
| Author-text fencing | High | **Adopted — LADR-118** | Author notes reached two prompt builders unfenced; untrusted input is an injection source. |
| Cross-chunk / compound risk synthesis | Medium | **Deferred** | Needs a second model call, a new finding key and a second raw-HTTP consumer; its implementation appends compound findings after the challenge filter, so they are never re-policed. Adoption condition below. |
| Deterministic compound pairing | Medium | **Deferred** | A pair list states co-occurrence, not a reasoned interaction; LADR-064 already single-sources coverage. Adoption condition below. |
| Obligation / consistency verification | High | **Deferred — corrected landing** | The gap is real, but the proposed landing (a new `C1)` posted class, soft-bucket `[VERIFIED]`/severity grammar, a grep deciding a semantic predicate) breaks LADR-063, LADR-055 and honest verification. Adoption condition below. |
| Verifier's `actual_behavior` output | Medium | **Rejected** | Display-only; a consumer-visible decision key with no measured benefit. |
| Adversary "missed trap" as a new finding | Low | **Rejected** | Same post-merge finding-channel problem as the deferred synthesis pass. |
| Dynamic per-PR review dimensions | High in PR-AF | **Rejected** | `planning_phase` is dead code; the shipped mechanism is three fixed lenses, and this gate's dimensional axis is already the chunk. |
| Coverage gate over clusters → gap reviewers | Medium | **Rejected** | Every changed file belongs to exactly one chunk; LADR-064 already names every chunk that contributed nothing. |
| Merge gate (blocking vs severity) | Medium | **Rejected** | The Recommendation sync (LADR-085) and the decision model own "does this block". |
| AI-PR detection and plan adjustment | Medium in PR-AF | **Rejected** | Uncalibratable heuristic; the deterministic metadata variant has no consumer and gives an uncalibrated signal false authority. |
| Severity-alias elevation (`medium→important`) | Low | **Deferred** | Elevates in the wrong direction for this gate's conservative scoring; revisit only on a measured calibration gap. |
| Per-phase budget caps | Low | **Rejected** | Covered by the chunk budgets (LADR-065/081) and the stall watchdog (LADR-102). |
| Per-agent model routing | Low | **Rejected** | Dead config in PR-AF and here. |
| Cost ceiling / spend accounting | Low | **Rejected** | PR-AF's cap is inert (`cost_usd: 0` in every benchmark row); this gate's transport emits no usage. |
| Evidence-pack priming of reviewer prompts | Low | **Rejected** | Spends the exploration budget the chunker already measured (LADR-076). |
| HITL approval gate | Low | **Rejected** | `/ai-review` is the human gate upstream of posting. |
| "Needs human judgement" wording | Low | **Rejected** | The `R1)` / `T1)` classes already carry the routing. |
| Inline GitHub comments with diff line mapping | Medium | **Rejected** | A second posted surface every parser must follow; PR-AF's mapping drops findings outside a hunk and never comments a deletion. |
| Per-file `evidence` array | Low | **Rejected** | Dropped at LADR-064; the sidecar is emitted last and truncates first. |
| Deterministic scoring separated from agents | Medium | **Already present** | The merge owns demotion/suppression; the sync owns escalation. |
| "Return zero, do not pad" discipline | Medium in PR-AF | **Already present** | The advisory test, the passing-checks rule and "praise is not a finding" are stricter. |
| Golden-file prompt fixtures | Low | **Rejected** | The prompt-guard and prompt-budget suites already assert prompt content. |
| Comparison write-up | Low | **Adopted — this document** | Records the disposition durably. |

## Deferred instruments — adoption conditions

- **Findings-emitting cross-chunk synthesis.** Paid evaluation shows a recall
  gap no deterministic instrument closes; a consumer-contract review accepts a
  new finding key and a second raw-HTTP consumer; emitted findings are
  adversarially challenged before they can block (PR-AF does not do this).
- **Deterministic compound pairing.** An eval fixture shows cross-file
  interaction is genuinely missed, and a pairing rule that names a reasoned
  interaction — not just co-occurrence — can be stated without a model call.
- **Obligation / consistency verification.** All four: an eval fixture with a
  known broken cross-file reliance measures the recall gain; the emission
  channel is a numbered finding on a reviewed post-merge path or an existing
  soft bucket, never a new posted class; the verify leg can actually decide
  `holds` (a stated predicate grammar or a model verifier carrying its own
  quote-the-line), never a grep dressed as verified; the extraction call is
  opt-in and fail-open, with its selector outside `model_target()`.
- **Severity-alias elevation.** Revisit only if eval shows a calibration gap it
  would close.

## PR-AF implementation defects behind the rejections

Read from PR-AF's source, not its docs:

- `reasoners/planning.go:13` — the planning phase is dead code; dynamic review
  dimensions never ship, so the advertised dimension mechanism does not exist.
- `cross_ref_hints` are always empty; nothing populates them.
- Compound findings are appended **after** the adversary/challenge filter, so
  the challenge never sees them.
- Evidence and verdict maps are keyed by finding **title**, so two findings with
  the same title collide.
- `ignore_paths` is configured but never applied.
- `cost_usd` is `0` in every benchmark row, so the cost cap is inert.
- 21 of 38 committed benchmark runs exceeded the 3600 s campaign cap (maximum
  4758.7 s) — the basis for deciding that a phase-boundary check must stop new
  work rather than interrupt a call.

## LADR mapping

| Unit | LADR | Runtime surface |
| --- | --- | --- |
| Author-notes data fence | LADR-118 | `lib/fence-untrusted.sh`; both prompt builders; `OPENCODE_REVIEW_REPORT_ENABLE_AUTHOR_FENCE` (default `1`) |
| Quote verification | LADR-119 | `lib/verify-quotes.sh` from the merge wrapper; one Coverage line; `OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION` (default `0`) |
| Caller context | LADR-120 | `lib/score-findings-decisions.sh` code context; `OPENCODE_REVIEW_REPORT_ENABLE_CALLER_CONTEXT` (default `0`) |
| Run deadline | LADR-121 | `review-in-chunks.sh` launch loop and retry sweep; aggregation banner; `OPENCODE_REVIEW_REPORT_MAX_DURATION_SECONDS` (default unset) |

The guarantees are per unit, not uniform:

- **Author fence (LADR-118)** is the one **default-on** unit — a safety boundary,
  not a quality claim — so its prompt does differ from the pre-fence baseline
  until the Variable is set falsy; that off state, and the helper-missing
  fallback (fixed fence plus a warning), both leave the rest byte-identical.
- **Quote verification (LADR-119)** and **caller context (LADR-120)** are
  default-off and fail open: off is byte-identical, and every skip or failure
  leaves the anchor, the merged document and the posted body as they were.
- **Run deadline (LADR-121)** is default-unset (unbounded). When set and
  reached it **hardens** rather than fails open: aggregation posts
  `REQUEST_CHANGES` naming the unreviewed chunks, exactly as a failed chunk
  does. It never softens a verdict, and an unset run is byte-identical.

Every unit adds no model call, no new merged-document key, no new posted class,
and no new secret or endpoint.
