#!/bin/bash
set -uo pipefail

# L0/L1 test for LADR-119 — deterministic verification of a finding's quoted
# line against the tree at the reviewed revision.
#
# Drives lib/verify-quotes.sh against a temp git repo, then proves the three
# invariants that matter: a fabricated quote is demoted and never dropped, a
# real quote keeps its anchor, and every uncertain case fails open. It also
# pins the contract boundaries — merge-findings.py untouched, the merged
# document gains no key — and the renderer's single Coverage line.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${SCRIPT_DIR}/lib/verify-quotes.sh"
RENDER="${SCRIPT_DIR}/lib/render-findings-summary.sh"
MERGE_PY="${SCRIPT_DIR}/lib/merge-findings.py"
MERGE_SH="${SCRIPT_DIR}/lib/merge-findings.sh"

TMP_DIR="$(mktemp -d /tmp/verify-quotes.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASSES=0
FAILURES=0
pass() { echo "✅ $1"; PASSES=$((PASSES + 1)); }
fail() { echo "❌ $1"; FAILURES=$((FAILURES + 1)); }
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$name"; else
    echo "❌ $name"; echo "--- expected ---"; printf '%s\n' "$expected"
    echo "--- actual ---"; printf '%s\n' "$actual"; FAILURES=$((FAILURES + 1))
  fi
}

echo "=========================================="
echo "Testing quote verification (LADR-119)"
echo "=========================================="
echo ""

# ── Fixture repo ────────────────────────────────────────────────────────────
REPO="${TMP_DIR}/repo"
mkdir -p "${REPO}/src"
cd "${REPO}" || exit 1
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
printf 'header line\nvar account = await _db.Accounts.FindAsync(accountId);\ntrailer line\n' > src/a.cs
printf 'guard file\nvar guard = CurrentUser.Owns(account);\n' > src/b.cs
printf 'indent file\n        var spaced = DoThing(value);\n' > src/c.cs
git add src
git commit -q -m base
REV="$(git rev-parse HEAD)"

mk_doc() { # findings-json → merged document
  jq -n --argjson findings "$1" '{
    status: "complete",
    findings: $findings,
    pre_existing_findings: [],
    suppressed_findings: [],
    suppressed_by_confidence: {},
    merged_duplicates: 0,
    demoted_no_quote: 0,
    malformed_findings: 0,
    malformed_returns: 0
  }'
}

finding() { # severity confidence first_evidence file line
  jq -n --arg sev "$1" --argjson conf "$2" --arg ev "$3" --arg f "$4" --argjson l "$5" \
    --arg title "Synthetic finding" \
    '{title:$title, severity:$sev, confidence:$conf, file:$f, line:$l,
      first_evidence:$ev, pre_existing:false, verified:true, chunks:[0],
      why_it_matters:"Synthetic.", autofix_class:"manual", owner:"human",
      requires_verification:false}'
}

echo "Part 1 — demote, never drop"

# Fabricated quote at 100 on a High → demoted to 50 and suppressed (the
# existing confidence gate); it stays in the document.
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = SomethingElse(completelyDifferent);' src/a.cs 2)]")"
m="${TMP_DIR}/fabricated.merged.json"; r="${TMP_DIR}/fabricated.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "fabricated quote: demoted count" "1" "$(jq -r '.demoted' "$r")"
check "fabricated quote: finding stays in the document (suppressed)" "1" "$(jq -r '.suppressed_findings | length' "$m")"
check "fabricated quote: anchor stepped to 50" "50" "$(jq -r '.suppressed_findings[0].confidence' "$m")"
check "fabricated quote: not left in the actionable set" "0" "$(jq -r '.findings | length' "$m")"

# Real quote at 100 → keeps its anchor and stays actionable.
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = await _db.Accounts.FindAsync(accountId);' src/a.cs 2)]")"
m="${TMP_DIR}/real.merged.json"; r="${TMP_DIR}/real.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "real quote: kept in findings" "1" "$(jq -r '.findings | length' "$m")"
check "real quote: anchor kept at 100" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "real quote: nothing demoted" "0" "$(jq -r '.demoted' "$r")"

echo ""
echo "Part 2 — file resolution and reporting"

# Quote names b.cs while the finding is filed against a.cs → the quote's file
# wins, so the finding is verified rather than demoted.
doc="$(mk_doc "[$(finding high 100 'src/b.cs:2 -- var guard = CurrentUser.Owns(account);' src/a.cs 9)]")"
m="${TMP_DIR}/filewins.merged.json"; r="${TMP_DIR}/filewins.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "quote's file wins over finding.file" "1" "$(jq -r '.findings | length' "$m")"

# A quote that exists only in another file keeps its anchor and is recorded.
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var guard = CurrentUser.Owns(account);' src/a.cs 2)]")"
m="${TMP_DIR}/elsewhere.merged.json"; r="${TMP_DIR}/elsewhere.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "found elsewhere: kept in findings" "1" "$(jq -r '.findings | length' "$m")"
check "found elsewhere: counted" "1" "$(jq -r '.found_elsewhere' "$r")"
check "found elsewhere: names the other file" "src/b.cs" "$(jq -r '[.findings[] | select(.result=="found_elsewhere") | .found_in[0]] | first // "missing"' "$r")"

echo ""
echo "Part 3 — formatting tolerance and skips"

# ` - `, `: ` separators and backticks all verify the same line.
for ev in 'src/c.cs:2 - `var spaced = DoThing(value);`' 'src/c.cs:2: var spaced = DoThing(value);'; do
  doc="$(mk_doc "[$(finding high 75 "$ev" src/c.cs 2)]")"
  m="${TMP_DIR}/tolerant.merged.json"; r="${TMP_DIR}/tolerant.report.json"
  printf '%s\n' "$doc" > "$m"
  bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
  check "tolerance keeps the anchor: ${ev:11:12}…" "75" "$(jq -r '.findings[0].confidence' "$m")"
done

# Unrecognisable prefix → skip, anchor unchanged.
doc="$(mk_doc "[$(finding high 100 'var spaced = DoThing(value);' src/c.cs 2)]")"
m="${TMP_DIR}/noprefix.merged.json"; r="${TMP_DIR}/noprefix.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "unrecognisable prefix: anchor unchanged" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "unrecognisable prefix: reported as a skip" "unrecognised_prefix" "$(jq -r '.findings[0].reason' "$r")"

# Short quote → skip.
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- two words' src/a.cs 2)]")"
m="${TMP_DIR}/short.merged.json"; r="${TMP_DIR}/short.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "short quote: anchor unchanged" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "short quote: reported as a skip" "short_quote" "$(jq -r '.findings[0].reason' "$r")"

# Multi-line quote → skip.
multiline_ev=$'src/a.cs:2 -- var account = await _db.Accounts.FindAsync(accountId);\nmore text here'
doc="$(mk_doc "[$(finding high 100 "$multiline_ev" src/a.cs 2)]")"
m="${TMP_DIR}/multiline.merged.json"; r="${TMP_DIR}/multiline.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "multi-line quote: anchor unchanged" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "multi-line quote: reported as a skip" "multiline_quote" "$(jq -r '.findings[0].reason' "$r")"

# Absent named file → skip.
doc="$(mk_doc "[$(finding high 100 'src/missing.cs:2 -- var account = await _db.Accounts.FindAsync(accountId);' src/missing.cs 2)]")"
m="${TMP_DIR}/absent.merged.json"; r="${TMP_DIR}/absent.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "absent named file: anchor unchanged" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "absent named file: reported as a skip" "absent_file" "$(jq -r '.findings[0].reason' "$r")"

# A failed named-file read that still emits partial stdout must skip: only the
# exit status decides, never the output's emptiness.
real_git_show="$(command -v git)"
shim_show="${TMP_DIR}/shim-show"
mkdir -p "$shim_show"
cat > "${shim_show}/git" <<SHIM
#!/bin/bash
if [ "\$1" = "show" ]; then echo "partial output from a failed read"; exit 1; fi
exec "${real_git_show}" "\$@"
SHIM
chmod +x "${shim_show}/git"
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = await _db.Accounts.FindAsync(accountId);' src/a.cs 2)]")"
m="${TMP_DIR}/showfail.merged.json"; r="${TMP_DIR}/showfail.report.json"
printf '%s\n' "$doc" > "$m"
PATH="${shim_show}:${PATH}" bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "failed named-file read with stdout: anchor unchanged" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "failed named-file read with stdout: reported as a skip" "git_error" "$(jq -r '.findings[0].reason' "$r")"

# A git failure during the repo-wide look must skip, never demote: grep's 1 is
# "no match", but 2+ (and a timeout's 124) is "the check could not run".
real_git="$(command -v git)"
shim="${TMP_DIR}/shim"
mkdir -p "$shim"
cat > "${shim}/git" <<SHIM
#!/bin/bash
if [ "\$1" = "grep" ]; then exit 128; fi
exec "${real_git}" "\$@"
SHIM
chmod +x "${shim}/git"
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = SomethingElse(completelyDifferent);' src/a.cs 2)]")"
m="${TMP_DIR}/giterror.merged.json"; r="${TMP_DIR}/giterror.report.json"
printf '%s\n' "$doc" > "$m"
PATH="${shim}:${PATH}" bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "git error: anchor unchanged (fail-open)" "100" "$(jq -r '.findings[0].confidence' "$m")"
check "git error: reported as a skip" "git_error" "$(jq -r '.findings[0].reason' "$r")"

# Unknown revision → nothing verified, nothing demoted, no report written.
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = await _db.Accounts.FindAsync(accountId);' src/a.cs 2)]")"
m="${TMP_DIR}/unknownrev.merged.json"; r="${TMP_DIR}/unknownrev.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "0000000000000000000000000000000000000000" >/dev/null 2>&1
check "unknown revision: anchor unchanged" "100" "$(jq -r '.findings[0].confidence' "$m")"
if [ -e "$r" ]; then fail "unknown revision: a report was written"; else pass "unknown revision: no report (no Coverage line)"; fi

# Pre-existing findings are not candidates.
pe_finding="$(finding low 100 'src/a.cs:2 -- definitely not in the tree at all' src/a.cs 2)"
doc="$(mk_doc '[]' | jq --argjson pe "[$pe_finding]" '.pre_existing_findings = $pe')"
m="${TMP_DIR}/preexisting.merged.json"; r="${TMP_DIR}/preexisting.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "pre-existing: never demoted" "100" "$(jq -r '.pre_existing_findings[0].confidence' "$m")"

echo ""
echo "Part 3b — survivors stay contiguously numbered"

# Three same-severity findings, the middle one fabricated. Suppressing the
# middle must renumber the survivors 1..N: the renderer prints the stored `#`,
# and its ordered-list form is only safe while the sequence is unbroken.
doc="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = await _db.Accounts.FindAsync(accountId);' src/a.cs 2),$(finding high 100 'src/a.cs:3 -- var account = SomethingElse(completelyDifferent);' src/a.cs 3),$(finding high 100 'src/b.cs:2 -- var guard = CurrentUser.Owns(account);' src/b.cs 2)]")"
m="${TMP_DIR}/contiguous.merged.json"; r="${TMP_DIR}/contiguous.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "middle suppression renumbers survivors 1..N" "1,2" "$(jq -r '[.findings[]["#"]] | join(",")' "$m")"

echo ""
echo "Part 4 — Critical survives demotion"

doc="$(mk_doc "[$(finding critical 100 'src/a.cs:2 -- var account = SomethingElse(completelyDifferent);' src/a.cs 2)]")"
m="${TMP_DIR}/critical.merged.json"; r="${TMP_DIR}/critical.report.json"
printf '%s\n' "$doc" > "$m"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "Critical demoted to 50" "50" "$(jq -r '.findings[0].confidence' "$m")"
check "Critical stays in the Issues Summary set" "1" "$(jq -r '.findings | length' "$m")"

echo ""
echo "Part 5 — contract boundaries and Coverage line"

if grep -q 'verify-quotes\|quote_verification' "$MERGE_PY"; then
  fail "merge-findings.py references the new concern (must stay frozen)"
else
  pass "merge-findings.py stays byte-identical in its concerns"
fi
if grep -q 'verify-quotes.sh\|_MERGE_SOURCE_REV' "$MERGE_SH"; then
  pass "merge-findings.sh owns the verification call"
else
  fail "merge-findings.sh does not call verify-quotes.sh"
fi

# The merged document gains no key: top-level and finding key sets identical.
before="$(mk_doc "[$(finding high 100 'src/a.cs:2 -- var account = SomethingElse(completelyDifferent);' src/a.cs 2)]")"
m="${TMP_DIR}/keys.merged.json"; r="${TMP_DIR}/keys.report.json"
printf '%s\n' "$before" > "$m"
before_keys="$(jq -S 'keys' "$m")"
before_finding_keys="$(jq -S '.findings[0] | keys' "$m")"
bash "$VERIFY" "$m" "$r" "$REV" >/dev/null 2>&1
check "merged document top-level keys unchanged" "$before_keys" "$(jq -S 'keys' "$m")"
check "finding keys unchanged" "$before_finding_keys" "$(jq -S '.suppressed_findings[0] | keys' "$m")"

# Renderer: one Coverage line when the report exists, none when it does not.
_QUOTE_VERIFICATION_JSON="$r" bash "$RENDER" "$m" 0 1 "" > "${TMP_DIR}/rendered.md" 2>/dev/null
if grep -q "Demoted for unverifiable quoted evidence" "${TMP_DIR}/rendered.md"; then
  pass "renderer emits the quote-verification Coverage line"
else
  fail "renderer omitted the quote-verification Coverage line"
fi
if grep -qE '#[0-9]' "${TMP_DIR}/rendered.md" && grep -qE '#[0-9]' <(grep "unverifiable quoted evidence" "${TMP_DIR}/rendered.md"); then
  fail "the Coverage line carries a '#<digit>' autolink hazard"
else
  pass "the Coverage line carries no '#<digit>'"
fi
bash "$RENDER" "$m" 0 1 "" > "${TMP_DIR}/rendered-off.md" 2>/dev/null
if grep -q "unverifiable quoted evidence" "${TMP_DIR}/rendered-off.md"; then
  fail "renderer emits the line with no report (flag-off body not byte-identical)"
else
  pass "renderer omits the line with no report"
fi

echo ""
echo "Part 6 — the Variable is declared everywhere it must be"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
check "run-review.sh declares the flag defaulting to 0" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION:-0' "${SCRIPT_DIR}/run-review.sh")"
check "local-review.sh declares the flag defaulting to 0" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION:-0' "${SCRIPT_DIR}/local-review.sh")"
check "reusable workflow declares the Variable" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION:.*|| .0.' "${REPO_ROOT}/.github/workflows/pipeline-code-review-report.yml")"
check "local-job packaging declares the Variable" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION:.*|| .0.' "${REPO_ROOT}/docs/examples/code-review-local.yml")"
check "merge wrapper gates the verification on the flag" "1" \
  "$(grep -c 'OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION' "${MERGE_SH}")"

echo ""
echo "Part 7 — end-to-end through the merge wrapper"

reviews="${TMP_DIR}/reviews"
mkdir -p "$reviews"
printf '{"chunk":1,"findings":[%s],"residual_risks":[],"testing_gaps":[]}\n' \
  "$(finding high 100 'src/a.cs:2 -- var account = SomethingElse(completelyDifferent);' src/a.cs 2)" \
  > "${reviews}/chunk_1.findings.json"
out="${TMP_DIR}/wf-on.merged.json"
OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION=1 _MERGE_SOURCE_REV="$REV" \
  bash "$MERGE_SH" "$reviews" "$out" >/dev/null 2>&1
report="${TMP_DIR}/quote_verification.json"
if [ -s "$out" ] && [ -s "$report" ]; then
  pass "wrapper: flag on writes the merged document and the verification report"
else
  fail "wrapper: flag on did not write both files"
fi
check "wrapper: fabricated quote demoted end to end" "1" "$(jq -r '.demoted' "$report" 2>/dev/null || echo missing)"
check "wrapper: demoted finding suppressed end to end" "1" "$(jq -r '.suppressed_findings | length' "$out" 2>/dev/null || echo missing)"

rm -f "$report"
out_off="${TMP_DIR}/wf-off.merged.json"
OPENCODE_REVIEW_REPORT_ENABLE_QUOTE_VERIFICATION=0 _MERGE_SOURCE_REV="$REV" \
  bash "$MERGE_SH" "$reviews" "$out_off" >/dev/null 2>&1
report_off="$report"
check "wrapper: flag off keeps the anchor" "100" "$(jq -r '.findings[0].confidence' "$out_off")"
if [ -e "$report_off" ]; then fail "wrapper: flag off wrote a report"; else pass "wrapper: flag off writes no report"; fi

echo ""
echo "=========================================="
echo "Results: ${PASSES} passed, ${FAILURES} failed"
echo "=========================================="
[ "${FAILURES}" -eq 0 ] || exit 1
