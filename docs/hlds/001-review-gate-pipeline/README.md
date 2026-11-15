# PR Review Gate Pipeline — High-Level Design

| | |
|---|---|
| **Status** | Accepted |
| **Owner** | `ai-review-report` |
| **Tracker** | [Repository issues](https://github.com/generic-automation-and-it/smooth-ai-report-review/issues) |
| **Evidence** | [ai-review-report SKILL.md](../../../.agents/skills/ai-review-report/SKILL.md) + [AGENTS.md](../../../.agents/skills/ai-review-report/AGENTS.md) at `0a8a7a2`; canonical LADRs in each LADR's Related section |
| **Last updated** | 2026-11-15 |

> Design record for the delivered gate. It states **intent + spec** — what the gate guarantees and
> why. It does not contain an implementation plan; phasing and sequencing live in the issue tracker.
>
> Requirements state the *outcome* and its constraints. A mechanism is named only where choosing
> differently would break a decision.

## Intent

The gate turns a pull request into one review verdict a merge policy can trust. It must never
review a diff it cannot prove, never approve an incomplete review, and never post a verdict
detached from the commit it judged. This design covers the path from trigger to posted review,
including the two packagings that invoke it.

## Key Goals

### 1. Prove the review scope

Every full review starts from a base that is a true ancestor of the reviewed head; when ancestry
cannot be resolved the run stops instead of guessing. An incremental review judges only the delta
since the last reviewed commit.

**Acceptance criteria / DoD**

- A full review diffs the resolved ancestor against the reviewed head.
- An unresolvable base produces no review and a failing run.
- No incremental review can approve a PR.

### 2. Bound the work per call

Changed files are grouped by shape, with hard per-file and per-chunk diff-payload limits. Instructions,
context and truncation markers add overhead beyond those limits; the complete prompt has a size
warning, not a hard cap. The chunk clock scales with prompt size rather than staying fixed against
variable work. An oversized PR is blocked rather than reviewed unreliably.

**Acceptance criteria / DoD**

- Per-file diff payloads and each chunk's combined diff payload stay within their byte caps;
  instructions, context and truncation markers are additional.
- A PR above the file-count limit receives a split-request verdict, not a review.
- Deterministic shape cases produce the same chunk count and grouping; semantic grouping may vary
  between runs.

### 3. Survive a degraded model

Each chunk runs through a primary and a secondary model; when the total budget is large enough to
split, the split leaves the fallback a real turn. A stalled chunk is killed early, and a failed
chunk gets at most one retry before the report is assembled. The retry sweep is skipped when every
chunk of a multi-chunk PR fails or the opt-in total-run deadline has been reached (canonical LADR-121).

**Acceptance criteria / DoD**

- A stall is killed at the stall threshold, not at the full chunk budget.
- A chunk that fails twice forces a request-changes outcome.
- When the budget is split, a primary timeout still leaves the secondary budget to run.

### 4. Post one coherent, pinned verdict

Completed chunks aggregate into one summary; the action is policy-driven but protected by mechanical
guards and coverage rules. The review is anchored to the reviewed SHA, stale gate reviews are
minimized on full runs, and an artifact is uploaded for runs that reach artifact assembly.

**Acceptance criteria / DoD**

- A verified write posts exactly one gate-authored review, anchored to the reviewed SHA; an
  uncertain retry's duplicate is cosmetic and minimized later.
- Coverage gaps are named in the posted body and never counted as code defects.
- Runs that reach artifact assembly upload one; preflight exits may post only an error comment.

### 5. Keep one entrypoint across packagings

The reusable workflow and the local-job caller both invoke the same entrypoint through environment
variables. The local runner shares the provider and transport contract but resolves its own diff
base and file limit, and does not post, minimize reviews or run the graph by default.

**Acceptance criteria / DoD**

- Both packagings produce the same review shape from the same inputs.
- The reusable workflow and local-job caller declare the variables they consume; the local runner
  documents its own subset. Five entrypoint knobs remain undeclared (known gap).
- No packaging reads workflow inputs or step outputs inside the entrypoint.

### 6. Decline work the gate cannot review meaningfully

Trivial-PR skip first requires every changed file to stay inside the lockfile and manifest allowlist,
then requires an exact case-insensitive `yes` from a model. Any other answer or model failure runs
the full review. The optional documentation-context validation gate is deterministic and blocks
only when explicitly enforced.

**Acceptance criteria / DoD**

- One changed file outside the allowlist runs the full review without a triviality model call.
- An allowlisted PR skips only after an exact affirmative model answer; any other answer or model
  failure runs the full review. A skip posts guidance and exits green.
- The documentation validation gate blocks only when explicitly enforced.
- Trusted `/ai-review` comments and manual dispatch always run the full review.

## Core Separation of Concerns

> The gate generates evidence; consumers decide what to do with it.

Generation owns scope, chunking, review calls, merging and posting. Follow-through — analysing a
posted review, applying decisions and triggering the next round — is a separate contract. Coupling
the two would let review generation depend on the state of a working tree it does not own.

## Guiding Principle — Never guess, never silently approve

- Fail loudly when the diff base, coverage or model availability cannot be established.
- Treat an approve decision as a claim that must be earned by complete evidence.
- Keep every posted verdict reproducible from the reviewed commit and the run artifact.

## Related HLDs

- [HLD index](../README.md) — ownership map, numbering convention and source precedence.
- [002 Context Delivery and Toolchain](../002-context-and-toolchain/README.md) — what each chunk is given.
- [003 Findings Integrity and Decision Scoring](../003-findings-and-decisions/README.md) — how findings become the verdict.
- [004 Review Follow-Through](../004-review-follow-through/README.md) — what happens after the review is posted.

---

## Diagrams

- [System Context (C1) + gate flow](./diagrams/c4-context.md)

## Architecture Decisions (LADRs)

LADRs 01–06 are strategic. Each is a decision the safety contract actually forces; implementation
detail stays with the entrypoint and its tests. See [`./ladrs/`](./ladrs/).

| LADR | Decision | Status |
|------|----------|--------|
| [LADR-01](./ladrs/LADR-01-diff-scope-resolved-or-fail.md) | The diff base is a resolved ancestor or the run stops | Accepted |
| [LADR-02](./ladrs/LADR-02-shape-based-chunking.md) | Chunk by shape with hard diff-payload budgets | Accepted |
| [LADR-03](./ladrs/LADR-03-bounded-review-chain.md) | A bounded two-tier chain with one retry per chunk | Accepted |
| [LADR-04](./ladrs/LADR-04-fail-closed-coverage.md) | Lost coverage fails closed; incremental reviews never approve | Accepted |
| [LADR-05](./ladrs/LADR-05-one-entrypoint-two-packagings.md) | One entrypoint serves both packagings | Accepted |
| [LADR-06](./ladrs/LADR-06-no-review-gates-fail-open.md) | No-review gates fail open | Accepted |

**Delegated to the entrypoint:** trivial-PR skip (canonical LADR-059), EXIT-trap run artifacts
(LADR-062), bounded GitHub retry allowlist (LADR-078), commit-pinned posting (LADR-109), and
all-models-failed handling (LADR-021).

## Non-Functional Requirements

Only quality concerns this design puts an unusual demand on. See [`./nfrs/`](./nfrs/).

| NFR | Attribute | Target (summary) | Status |
|-----|-----------|------------------|--------|
| [NFR-01](./nfrs/NFR-01-verdict-integrity.md) | Verdict integrity | No approve on incremental or incomplete coverage | Accepted |
| [NFR-02](./nfrs/NFR-02-diff-scope-correctness.md) | Scope correctness | Zero reviews outside the resolved ancestor range | Accepted |
| [NFR-03](./nfrs/NFR-03-post-pinning.md) | Post determinism | One review per run, pinned to the reviewed SHA | Accepted |
