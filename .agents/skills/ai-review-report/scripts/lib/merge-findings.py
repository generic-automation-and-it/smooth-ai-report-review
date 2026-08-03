#!/usr/bin/env python3
"""Deterministic merge of per-chunk structured findings (LADR-055).

stdin  : JSON array of chunk documents conforming to assets/findings-schema.json
stdout : one JSON object (sort_keys=True)
exit   : 0 on success, 2 when stdin is not a JSON array

No filesystem access, no network, no arguments. The caller
(lib/merge-findings.sh) owns interpreter resolution and file collection so
there is exactly one place that knows how to find a Python.

Design origin: EveryInc/compound-engineering-plugin, skills/ce-code-review,
scripts/findings-mechanics.py @ a5cd949 (MIT). The seven ordered operations are
theirs; the severity vocabulary, chunk-based source identity, the `verified`
mirror, and the critical-severity escape are this repo's. Their plan-settlement
(`settled_conflict`) and cross-reviewer independence promotion are deliberately
absent — the first has no analogue here, the second belongs to Tier 1 item 7
(cross-model peer) and would be wrong to half-implement now.

Determinism is a hard requirement, not a nicety: the eval harness and any future
run-to-run diffing depend on identical input producing byte-identical output,
including the `#` assignment. Every sort key is total, and output is emitted with
sort_keys=True.
"""

from __future__ import annotations

import json
import sys
from collections import Counter

# Ordered most-severe-first. Index doubles as the sort rank and as the
# "which wins on disagreement" comparison.
SEVERITIES = ("critical", "high", "medium", "low")
CONFIDENCES = (0, 25, 50, 75, 100)
# Ordered least-conservative-first: a higher index wins a merge disagreement.
# gated_auto proposes a concrete change, manual wants a decision first, advisory
# asks for nothing at all — so advisory is the most conservative routing claim a
# contributor can make about a shared finding.
AUTOFIX_CLASSES = ("gated_auto", "manual", "advisory")
OWNERS = ("downstream-resolver", "human", "release")

# The anchor at and above which a finding is actionable, and the anchor a
# finding that fails the quote-the-line gate is demoted to.
ACTIONABLE_ANCHOR = 75
DEMOTED_ANCHOR = 50

# Narrower than the schema's top-level `required`, deliberately. The schema also
# requires `residual_risks` and `testing_gaps`, but extract-findings-json.sh
# normalises both to arrays before this ever runs, and neither carries a finding
# — rejecting a whole chunk document over a missing empty list would discard real
# findings to enforce a field nothing reads.
REQUIRED_TOP = {
    "chunk": int,
    "findings": list,
}
REQUIRED_FINDING = {
    "title": str,
    "severity": str,
    "file": str,
    "why_it_matters": str,
    "confidence": int,
    "pre_existing": bool,
    "requires_verification": bool,
    "autofix_class": str,
    "owner": str,
}


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def valid_return(value):
    if not isinstance(value, dict):
        return False
    for key, expected in REQUIRED_TOP.items():
        got = value.get(key)
        if not isinstance(got, expected):
            return False
        # bool is a subclass of int in Python; a `true` chunk index is not a
        # chunk index.
        if expected is int and isinstance(got, bool):
            return False
    return True


def valid_finding(value):
    if not isinstance(value, dict):
        return False
    for key, expected in REQUIRED_FINDING.items():
        got = value.get(key)
        if not isinstance(got, expected):
            return False
        if expected is int and isinstance(got, bool):
            return False
    if not nonempty_string(value["title"]):
        return False
    if not nonempty_string(value["file"]):
        return False
    if not nonempty_string(value["why_it_matters"]):
        return False
    if value["severity"] not in SEVERITIES:
        return False
    if value["confidence"] not in CONFIDENCES:
        return False
    if value["autofix_class"] not in AUTOFIX_CLASSES:
        return False
    if value["owner"] not in OWNERS:
        return False
    # `evidence` is optional as of the sidecar-slimming change: the chunk prompt
    # no longer asks for it, because the quotes already appear in the markdown a
    # human reads and repeating them here inflated the block that is emitted last
    # and truncated first. Nothing in this module ever read it — `first_evidence`
    # alone carries the quote-the-line gate. When a producer does send it, it must
    # still be a non-empty list of non-empty strings; a present-but-junk field is
    # a malformed finding, an absent one is not.
    if "evidence" in value:
        evidence = value["evidence"]
        if not isinstance(evidence, list) or not evidence:
            return False
        if not all(nonempty_string(e) for e in evidence):
            return False
    # `line` is intentionally more forgiving than the schema, which asks for an
    # integer: models routinely emit "42" or "42-55", and dropping an otherwise
    # complete finding over the type of its line reference trades a real finding
    # for a formatting preference.
    line = value.get("line")
    line_ok = (isinstance(line, int) and not isinstance(line, bool) and line > 0) or (
        isinstance(line, str) and bool(line.strip())
    )
    if not line_ok:
        return False
    # first_evidence, when present, must be usable — a blank one would satisfy
    # the quote-the-line gate without carrying a quote.
    if "first_evidence" in value and not nonempty_string(value["first_evidence"]):
        return False
    return True


def soft_key(value):
    """Dedup key for the free-text soft buckets (residual risks, testing gaps).

    Same normalisation as the title leg of `fingerprint()`. These carry no
    file/line, so the text is all there is to key on.
    """
    return " ".join(str(value).lower().split())


def normalise_line(value):
    """Integer when it reads as one, else the stripped original."""
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    text = str(value).strip()
    if text.isdigit():
        return int(text)
    return text


def fingerprint(finding):
    """Exact-match dedup key: same file, same line, same title.

    Deliberately exact rather than fuzzy. A near-miss that survives as two
    findings is noise a reader can dismiss in a second; a fuzzy match that
    collapses two genuinely different defects at the same line loses one of them
    silently, and nothing downstream would ever surface the loss.
    """
    return (
        finding["file"].strip().lower(),
        str(normalise_line(finding.get("line"))).strip(),
        " ".join(finding["title"].lower().split()),
    )


def sort_key(finding):
    """Total order: severity, then -confidence, then file, line, title.

    `line` sorts numerically when both sides are numeric and lexically
    otherwise, via a (is_text, number, text) tuple that never compares an int
    with a str.
    """
    line = normalise_line(finding.get("line"))
    if isinstance(line, int):
        line_key = (0, line, "")
    else:
        line_key = (1, 0, str(line))
    return (
        SEVERITIES.index(finding["severity"]),
        -finding["confidence"],
        finding["file"].lower(),
        line_key,
        finding["title"].lower(),
    )


def merge_group(group):
    """Collapse one fingerprint group into a single finding, conservatively.

    `group` is a list of (finding, chunk_number). The representative is the most
    severe / highest-confidence member, and supplies the prose fields. On the
    *routing* fields every other member can only make the merged finding more
    cautious, never less: the more conservative `autofix_class` and `owner` win,
    `requires_verification` ORs to true, `pre_existing` survives only on
    unanimity. Severity and confidence are the exception and merge independently
    — see the comment at the `max()` below for why confidence is not simply
    inherited from the representative.
    """
    group = sorted(
        group,
        key=lambda item: (
            SEVERITIES.index(item[0]["severity"]),
            -item[0]["confidence"],
            item[1],
        ),
    )
    merged = dict(group[0][0])
    merged.pop("chunk", None)

    chunks = []
    for finding, chunk in group:
        if chunk not in chunks:
            chunks.append(chunk)

        if AUTOFIX_CLASSES.index(finding["autofix_class"]) > AUTOFIX_CLASSES.index(
            merged["autofix_class"]
        ):
            merged["autofix_class"] = finding["autofix_class"]
        if OWNERS.index(finding["owner"]) > OWNERS.index(merged["owner"]):
            merged["owner"] = finding["owner"]

        merged["requires_verification"] = bool(
            merged["requires_verification"] or finding["requires_verification"]
        )
        # `verified` ORs to true: one chunk having actually read the code makes
        # the [VERIFIED] claim true for the merged finding, and [VERIFIED] is the
        # tag that can block (score-review.sh), so OR is also the fail-closed
        # direction.
        merged["verified"] = bool(
            merged.get("verified") is True or finding.get("verified") is True
        )
        if not nonempty_string(merged.get("first_evidence")) and nonempty_string(
            finding.get("first_evidence")
        ):
            merged["first_evidence"] = finding["first_evidence"]
        if not nonempty_string(merged.get("suggested_fix")) and nonempty_string(
            finding.get("suggested_fix")
        ):
            merged["suggested_fix"] = finding["suggested_fix"]

    # pre_existing survives only on unanimity: a single contributor saying "this
    # diff introduced it" is enough to stop the finding being filed away as
    # someone else's problem, which is the direction that cannot lose a finding.
    merged["pre_existing"] = all(item[0]["pre_existing"] for item in group)

    # Severity and confidence are independent axes, so they merge independently:
    # the representative supplies the most severe severity, and confidence takes
    # the maximum across the whole group. Inheriting the representative's own
    # confidence instead would lose findings — one chunk reporting `high` at 50
    # and another reporting the same defect as `medium` at 100 would merge to
    # `high` at 50 and be suppressed by the confidence gate, discarding a
    # contributor who was certain the issue is real and merely disagreed about
    # how urgent it is. The quote-the-line gate still applies afterwards, over
    # the merged `first_evidence`, so a raised confidence with no quote anywhere
    # in the group is demoted straight back down.
    merged["confidence"] = max(item[0]["confidence"] for item in group)
    merged["line"] = normalise_line(merged.get("line"))
    merged["chunks"] = sorted(chunks)
    return merged, len(group) - 1


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as error:
        print(json.dumps({"status": "failed", "reason": str(error)}, sort_keys=True))
        return 2

    if not isinstance(payload, list):
        print(
            json.dumps(
                {"status": "failed", "reason": "expected an array of chunk documents"},
                sort_keys=True,
            )
        )
        return 2

    malformed_returns = 0
    malformed_findings = 0
    grouped = {}
    order = []
    residual_risks = []
    testing_gaps = []
    residual_seen = set()
    testing_seen = set()
    # Which chunks actually contributed a usable document. This is the coverage
    # figure the caller must gate on: counting sidecar FILES instead would count
    # a chunk whose document was rejected here as covered, and render a summary
    # that silently omits it while reporting full coverage — the exact failure
    # the coverage precondition exists to prevent, reached through a side door.
    merged_chunks = set()

    # --- 1. validate + 2. fingerprint dedup ---------------------------------
    for source in payload:
        if not valid_return(source):
            malformed_returns += 1
            continue
        chunk = source["chunk"]
        merged_chunks.add(chunk)
        # Both lists are rendered into the Medium tier, so they get the same
        # cross-chunk deduplication the findings do. Chunk boundaries are an
        # arbitrary split of one changeset: "no tests for the new guard" reported
        # by three chunks is one gap, not three. Keyed on whitespace-normalised
        # lower case — the same normalisation the title leg of `fingerprint()`
        # uses — and first-seen wins so the output order stays deterministic.
        for item in source.get("residual_risks") or []:
            if nonempty_string(item) and soft_key(item) not in residual_seen:
                residual_seen.add(soft_key(item))
                residual_risks.append(item.strip())
        for item in source.get("testing_gaps") or []:
            if nonempty_string(item) and soft_key(item) not in testing_seen:
                testing_seen.add(soft_key(item))
                testing_gaps.append(item.strip())
        for finding in source["findings"]:
            if not valid_finding(finding):
                malformed_findings += 1
                continue
            key = fingerprint(finding)
            if key not in grouped:
                grouped[key] = []
                order.append(key)
            grouped[key].append((dict(finding), chunk))

    # --- 3. conservative merge ----------------------------------------------
    merged_duplicates = 0
    merged = []
    for key in order:
        finding, dropped = merge_group(grouped[key])
        merged_duplicates += dropped
        merged.append(finding)

    # --- 4. quote-the-line enforcement --------------------------------------
    # The gate the chunk prompt states, made mechanical. A finding claiming 75 or
    # 100 without a quoted motivating line is demoted, not dropped: the claim may
    # well be true, it just has not been evidenced to the standard the anchor
    # asserts, and 50 is exactly the anchor for "real but not established".
    demoted_no_quote = 0
    for finding in merged:
        if finding["confidence"] >= ACTIONABLE_ANCHOR and not nonempty_string(
            finding.get("first_evidence")
        ):
            finding["confidence"] = DEMOTED_ANCHOR
            finding["demoted_no_quote"] = True
            demoted_no_quote += 1

    # --- 5. confidence gate + 6. partition ----------------------------------
    suppressed_by_confidence = Counter()
    findings = []
    pre_existing_findings = []
    suppressed_findings = []
    for finding in merged:
        if finding["pre_existing"]:
            pre_existing_findings.append(finding)
            continue
        # Critical always survives the gate. A critical finding the reviewer
        # could not fully evidence is the single worst thing to drop silently —
        # it is the one case where a false positive costs less than a miss.
        if finding["confidence"] < ACTIONABLE_ANCHOR and finding["severity"] != "critical":
            suppressed_by_confidence[str(finding["confidence"])] += 1
            suppressed_findings.append(finding)
            continue
        findings.append(finding)

    # --- 7. deterministic sort + stable numbering ---------------------------
    findings.sort(key=sort_key)
    pre_existing_findings.sort(key=sort_key)
    suppressed_findings.sort(key=sort_key)
    for number, finding in enumerate(findings, 1):
        finding["#"] = number

    print(
        json.dumps(
            {
                "status": "complete",
                "merged_chunks": sorted(merged_chunks),
                "findings": findings,
                "pre_existing_findings": pre_existing_findings,
                "suppressed_findings": suppressed_findings,
                "residual_risks": residual_risks,
                "testing_gaps": testing_gaps,
                "suppressed_by_confidence": dict(sorted(suppressed_by_confidence.items())),
                "demoted_no_quote": demoted_no_quote,
                "merged_duplicates": merged_duplicates,
                "malformed_returns": malformed_returns,
                "malformed_findings": malformed_findings,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
