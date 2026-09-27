#!/usr/bin/env python3
"""Measure the LADR-093 decision model against the eval corpus's ground truth.

stdin : nothing. argv[1] is a directory of per-fixture-sample JSON records
        written by run-evals.sh or calibrate-decisions.sh (one
        `<fixture>.<sample>.json` each); optional argv[2] is a report title.
stdout: a plain-text report. Report-only: exit 0 whatever it finds, 2 only on
        unusable input, so it can never fail the eval gate.

The question it answers is the one LADR-093 left open ("filter must not default
on until the DR corpus has measured it"): does Jev's judgement separate the
findings we KNOW are wrong from the ones we KNOW are right, and what would each
way of acting on it have done to precision and recall?

Ground truth comes from the corpus, not from Jev and not from the chunk model:
  - must-not-flag fixture: a finding is a KNOWN FALSE POSITIVE when it is a
    [VERIFIED] Critical/High/Medium whose title or rationale matches the
    manifest `forbidden_claim` (every such finding when the manifest has none —
    the harness's own strict rule, DR-014).
  - must-catch fixture: a finding is a TRUE CATCH when it is [VERIFIED] at or
    above the manifest `min_severity`.

One deliberate difference from the harness: the harness matches the claim
against the rendered markdown line, this matches the structured finding's
title + why_it_matters. The structured set is also post-confidence-gate
(merge-findings.py drops < 75 unless critical), so its baseline can differ
from the markdown baseline; both are reported.

Policies are applied OFFLINE to the annotate-mode answers, so one paid run
measures all of them:
  base        the merged findings as they are
  filter@t    drop non-critical findings with supported < t (hunk found)
  demote@t    [VERIFIED] -> [SPECULATIVE] when supported < t
  sev@c       adopt Jev's severity when its choice confidence >= c
  rules@t     drop non-critical findings with sanctioned >= t   (rules given)
  either@t    drop non-critical when supported < t OR sanctioned >= t
"""

from __future__ import annotations

import json
import os
import re
import statistics
import sys

SEV_RANK = {"critical": 3, "high": 2, "medium": 1, "low": 0}
FLAG_MIN = SEV_RANK["medium"]  # the harness flags Critical/High/Medium

POSIX = {
    "[:alnum:]": "a-zA-Z0-9",
    "[:alpha:]": "a-zA-Z",
    "[:digit:]": "0-9",
    "[:space:]": r"\s",
    "[:upper:]": "A-Z",
    "[:lower:]": "a-z",
    "[:punct:]": r"!-/:-@\[-`{-~",
}


def ere(pattern):
    """A grep -E pattern as a Python regex (POSIX classes translated)."""
    for cls, rep in POSIX.items():
        pattern = pattern.replace(cls, rep)
    return re.compile(pattern, re.IGNORECASE)


def load(directory):
    docs = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as fh:
            try:
                docs.append(json.load(fh))
            except json.JSONDecodeError:
                print(f"  (skipped unparseable record {name})")
    return docs


def is_false_positive(doc, f):
    if doc["kind"] != "must-not-flag" or not f.get("verified"):
        return False
    if SEV_RANK.get(f.get("severity"), -1) < FLAG_MIN:
        return False
    claim = doc.get("forbidden_claim") or ""
    if not claim:
        return True
    text = f"{f.get('title', '')} {f.get('why_it_matters', '')}"
    return bool(ere(claim).search(text))


def is_true_catch(doc, f):
    if doc["kind"] != "must-catch" or not f.get("verified"):
        return False
    need = SEV_RANK.get((doc.get("min_severity") or "high").lower(), SEV_RANK["high"])
    return SEV_RANK.get(f.get("severity"), -1) >= need


# --- policies: each maps a finding list to the list a reader would see ------------
def base(findings):
    return findings


def filter_at(t):
    def apply(findings):
        return [
            f for f in findings
            if f.get("severity") == "critical"
            or f.get("supported") is None
            or f.get("diff_hunk_found") is False
            or f["supported"] >= t
        ]
    return apply


def demote_at(t):
    def apply(findings):
        out = []
        for f in findings:
            g = dict(f)
            if g.get("supported") is not None and g["supported"] < t:
                g["verified"] = False
            out.append(g)
        return out
    return apply


def sev_at(c):
    def apply(findings):
        out = []
        for f in findings:
            g = dict(f)
            if g.get("jev_severity") in SEV_RANK and (g.get("jev_confidence") or 0) >= c:
                g["severity"] = g["jev_severity"]
            out.append(g)
        return out
    return apply


def rules_at(t):
    def apply(findings):
        return [
            f for f in findings
            if f.get("severity") == "critical"
            or f.get("sanctioned") is None
            or f["sanctioned"] < t
        ]
    return apply


def either_at(t):
    def apply(findings):
        return rules_at(t)(filter_at(t)(findings))
    return apply


POLICIES = [
    ("base", base),
    ("filter@0.50", filter_at(0.50)),
    ("filter@0.25", filter_at(0.25)),
    ("demote@0.50", demote_at(0.50)),
    ("demote@0.25", demote_at(0.25)),
    ("sev@0.60", sev_at(0.60)),
    ("sev@0.80", sev_at(0.80)),
]
RULE_POLICIES = [
    ("rules@0.50", rules_at(0.50)),
    ("either@0.50", either_at(0.50)),
]


def fixture_outcome(doc, findings):
    """(dr_reraised, caught) for one sample under one policy."""
    if doc["kind"] == "must-not-flag":
        return any(is_false_positive(doc, f) for f in findings), None
    return None, any(is_true_catch(doc, f) for f in findings)


def auc(pos, neg):
    """P(a true catch scores higher than a known false positive); ties count half."""
    if not pos or not neg:
        return None
    wins = 0.0
    for p in pos:
        for n in neg:
            wins += 1.0 if p > n else 0.5 if p == n else 0.0
    return wins / (len(pos) * len(neg))


def fmt(x, nd=2):
    return "n/a" if x is None else f"{x:.{nd}f}"


def summarise(values):
    if not values:
        return "n=0"
    return (f"n={len(values)}  mean {statistics.mean(values):.2f}  "
            f"median {statistics.median(values):.2f}  "
            f"min {min(values):.2f}  max {max(values):.2f}")


def main():
    if len(sys.argv) not in (2, 3) or not os.path.isdir(sys.argv[1]):
        print("usage: decisions-report.py <records-dir> [title]")
        return 2
    docs = load(sys.argv[1])
    title = sys.argv[2] if len(sys.argv) == 3 else "DECISION MODEL MEASUREMENT (LADR-093, report-only)"
    print("==========================================")
    print(f" {title}")
    print("==========================================")
    if not docs:
        print(" No decision records — the measurement did not run.")
        return 0

    providers = sorted({f"{d.get('provider') or '?'}/{d.get('model') or '?'}" for d in docs if d.get("status") == "scored"})
    status = {}
    for d in docs:
        status[d.get("status", "?")] = status.get(d.get("status", "?"), 0) + 1
    print(f" Decision model : {', '.join(providers) or '(none scored)'}")
    print(" Samples        : " + ", ".join(f"{k} {v}" for k, v in sorted(status.items())))
    # A sample with no findings at all is a real outcome (a clean DR fixture, a
    # missed catch), not a failed measurement, so it counts in every table.
    scored = [d for d in docs if d.get("status") in ("scored", "no_findings")]
    excluded = [d for d in docs if d.get("status") not in ("scored", "no_findings")]
    if excluded:
        # Named, not just counted: a reader must be able to tell WHICH fixtures
        # are missing from every table below without opening the records.
        print(f" Excluded       : {len(excluded)} sample(s) not fully measured — left out of every table:")
        for d in excluded:
            where = d.get("fixture", "?") + f" sample {d.get('sample', '?')}"
            if d.get("variant"):
                where += f" ({d['variant']})"
            note = (d.get("note") or "").strip()
            print(f"                  - {where}: {d.get('status', '?')}" + (f" — {note}" if note else ""))
    print("")

    # --- 1. does `supported` separate the known wrong from the known right? -----
    fp, tp, unrelated = [], [], []
    fp_sev, tp_sev = [], []
    for d in scored:
        for f in d.get("findings", []):
            s = f.get("supported")
            if is_false_positive(d, f):
                if s is not None:
                    fp.append(s)
                fp_sev.append(f.get("jev_severity"))
            elif is_true_catch(d, f):
                if s is not None:
                    tp.append(s)
                tp_sev.append((f.get("jev_severity"), d.get("min_severity")))
            elif d["kind"] == "must-not-flag" and s is not None:
                unrelated.append(s)
    print(" 1. `supported` probability by ground truth")
    print(f"    known false positives (DR re-raises) : {summarise(fp)}")
    print(f"    true catches (seeded defects)        : {summarise(tp)}")
    print(f"    other findings on DR fixtures        : {summarise(unrelated)}  (truth unknown — info only)")
    a = auc(tp, fp)
    print(f"    separation (AUC, 1.0 = perfect, 0.5 = chance): {fmt(a)}"
          + ("" if a is not None else "  (needs at least one of each)"))
    print("")

    # --- 1b. the policy question, when the scorer was given project rules -------
    fp_s = [f.get("sanctioned") for d in scored for f in d.get("findings", [])
            if is_false_positive(d, f) and f.get("sanctioned") is not None]
    tp_s = [f.get("sanctioned") for d in scored for f in d.get("findings", [])
            if is_true_catch(d, f) and f.get("sanctioned") is not None]
    has_rules = bool(fp_s or tp_s)
    if has_rules:
        print(" 1b. `sanctioned` (a project rule allows it) by ground truth")
        print(f"    known false positives : {summarise(fp_s)}")
        print(f"    true catches          : {summarise(tp_s)}")
        # Higher sanctioned should mean MORE likely a false positive, so the
        # separation is measured on (1 - sanctioned) like `supported`.
        print(f"    separation (AUC)      : {fmt(auc([1 - x for x in tp_s], [1 - x for x in fp_s]))}")
        print("")

    # --- 2. what would Jev's severity have said? ------------------------------
    fp_below = sum(1 for s in fp_sev if s in SEV_RANK and SEV_RANK[s] < FLAG_MIN)
    tp_ok = sum(1 for s, m in tp_sev
                if s in SEV_RANK and SEV_RANK[s] >= SEV_RANK.get((m or "high").lower(), 2))
    print(" 2. Jev severity by ground truth")
    print(f"    false positives Jev would rate below Medium : {fp_below}/{len(fp_sev)}")
    print(f"    true catches Jev rates at/above the bar     : {tp_ok}/{len(tp_sev)}")
    print("")

    # --- 3. policies ------------------------------------------------------------
    dr = [d for d in scored if d["kind"] == "must-not-flag"]
    mc = [d for d in scored if d["kind"] == "must-catch"]
    print(" 3. What each policy would have done (structured findings, per sample)")
    print(f"    {'policy':<12} {'DR re-raised':>14} {'MC caught':>11}   verdict vs base")
    base_dr = base_mc = None
    for name, pol in POLICIES + (RULE_POLICIES if has_rules else []):
        dr_hits = sum(1 for d in dr if fixture_outcome(d, pol(d.get("findings", [])))[0])
        mc_hits = sum(1 for d in mc if fixture_outcome(d, pol(d.get("findings", [])))[1])
        if name == "base":
            base_dr, base_mc = dr_hits, mc_hits
            note = "(reference)"
        else:
            parts = []
            if dr_hits < base_dr:
                parts.append(f"precision +{base_dr - dr_hits}")
            if dr_hits > base_dr:
                parts.append(f"precision -{dr_hits - base_dr}")
            if mc_hits < base_mc:
                parts.append(f"RECALL -{base_mc - mc_hits}")
            if mc_hits > base_mc:
                parts.append(f"recall +{mc_hits - base_mc}")
            note = ", ".join(parts) or "no change"
        print(f"    {name:<12} {dr_hits:>7}/{len(dr):<6} {mc_hits:>5}/{len(mc):<5}   {note}")
    print("")
    print(" Read with care: one sample per fixture is a small, noisy corpus. A policy")
    print(" is worth pursuing only if it removes DR re-raises WITHOUT losing a catch,")
    print(" and only once that holds across several runs (EVAL_SAMPLES > 1).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
