# LADR-03: Graph and Provenance Signals Are Hints, Never Verdicts

**Status:** Accepted

## Context

- Structural risk and inferred coverage help a reviewer look in the right place.
- An inferred test edge is not proof that a test is missing.
- Graph construction can fail, time out or lag the reviewed commit.
- Enrichment must not become a new permission or a new way to block a PR.

## Decision

**Treat** graph signals and blame provenance as bounded, optional context. Each slice is capped
including its truncation marker, and every failure — missing graph, failed build, missing tool,
timeout — omits the block and leaves the review otherwise unchanged.

Risk is not severity, and a missing test edge is not proof of missing tests. Neither signal alone
justifies Critical or High, and neither satisfies the quote-the-line evidence requirement.

Deleted-symbol references (what the graph still records as using a symbol the PR removed),
change-frequency risk, and the direct-versus-indirect test classification belong to the same
bounded-hint class. A hint class that did not ship before is **opt-in** until an eval measures it,
and with its flag off the chunk prompt is byte-identical.

## Consequences

- Reviewers get directed attention without outsourcing judgment to a heuristic.
- Enrichment can disappear without changing the review's validity.
- Graph availability is recorded separately from review completeness.
- No tool permission or test-edit authority is added by enrichment.
- A deleted-symbol hint never becomes a "will break" claim; the reviewer opens each recorded user.

## Related

- Canonical **LADR-049**, **LADR-050** (and its 2026-11-17 amendment), **LADR-061** in [ai-review-report AGENTS.md](../../../../.agents/skills/ai-review-report/AGENTS.md).
