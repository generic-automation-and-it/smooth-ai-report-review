#!/bin/bash
# Head-SHA permalinks on rendered findings (LADR-112). No model, network or repo
# writes: the renderer reads its link inputs from the environment only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$SCRIPT_DIR/lib/render-findings-summary.sh"
STRIP="$SCRIPT_DIR/lib/strip-finding-links.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then echo "  ✅ $1"; pass=$((pass + 1))
  else echo "  ❌ $1"; echo "    expected: $2"; echo "    actual:   $3"; fail=$((fail + 1)); fi
}

SHA=0123456789abcdef0123456789abcdef01234567
unset GITHUB_SERVER_URL GITHUB_REPOSITORY OPENCODE_REVIEW_REPORT_DIFF_TO_SHA OPENCODE_REVIEW_REPORT_ENABLE_FINDING_LINKS

# One numbered finding per interesting path/line shape, plus every non-finding
# class the link must never touch: suppressed, pre-existing (P), residual (R)
# and testing-gap (T) items.
cat > "$work/merged.json" <<'JSON'
{"status":"complete","merged_chunks":[0],
 "findings":[
  {"#":1,"title":"Plain path","severity":"high","file":"src/app/main.py","line":42,"why_it_matters":"Why.","confidence":100,"verified":true,"chunks":[0]},
  {"#":2,"title":"Odd path","severity":"medium","file":"docs/a b/(x)#y?.md","line":7,"confidence":100,"verified":true,"chunks":[0]},
  {"#":3,"title":"String line","severity":"medium","file":"src/s.sh","line":"12","confidence":100,"verified":false,"chunks":[0]},
  {"#":4,"title":"Blank line","severity":"low","file":"src/b.sh","line":"","confidence":100,"verified":true,"chunks":[0]},
  {"#":5,"title":"Range line","severity":"low","file":"src/c.sh","line":"10-12","confidence":100,"verified":true,"chunks":[0]},
  {"#":6,"title":"Zero line","severity":"low","file":"src/d.sh","line":0,"confidence":100,"verified":true,"chunks":[0]},
  {"#":7,"title":"Runner path","severity":"low","file":"/home/runner/work/repo/repo/src/e.sh","line":5,"confidence":100,"verified":true,"chunks":[0]},
  {"#":8,"title":"Parent path","severity":"low","file":"src/../../etc/f.sh","line":5,"confidence":100,"verified":true,"chunks":[0]},
  {"#":9,"title":"Windows path","severity":"low","file":"C:\\repo\\g.cs","line":5,"confidence":100,"verified":true,"chunks":[0]}],
 "pre_existing_findings":[{"title":"Old thing","severity":"medium","file":"src/old.sh","line":3,"chunks":[0]}],
 "suppressed_findings":[{"title":"Quiet","severity":"low","file":"src/q.sh","line":4}],
 "residual_risks":["Needs human judgement"],"testing_gaps":["No test for x"],
 "suppressed_by_confidence":{"50":1},"demoted_no_quote":0,"merged_duplicates":0,
 "malformed_findings":0,"malformed_returns":0}
JSON

render() { bash "$RENDER" "$work/merged.json" 0 1 > "$work/out.md"; }
line_of() { grep -E "^$1\. " "$work/out.md" || true; }

echo "T-A2: URL shape"
export GITHUB_REPOSITORY=owner/repo OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$SHA"
render
check "default server, flag defaults on" \
  "1. 🟠 [VERIFIED] High Priority: Plain path — \`src/app/main.py:42\` (chunk 0) · [open](https://github.com/owner/repo/blob/$SHA/src/app/main.py#L42)" \
  "$(line_of 1)"
check "the why line stays the next line, unchanged" \
  "   - Why." "$(grep -A1 -E '^1\. ' "$work/out.md" | tail -n1)"
check "( ) # ? and space are percent-encoded per segment, slashes kept" \
  "[open](https://github.com/owner/repo/blob/$SHA/docs/a%20b/%28x%29%23y%3F.md#L7)" \
  "$(line_of 2 | sed 's/.* · //')"
check "a numeric string line links" "[open](https://github.com/owner/repo/blob/$SHA/src/s.sh#L12)" "$(line_of 3 | sed 's/.* · //')"
GITHUB_SERVER_URL=https://ghe.example.com/ render
check "GHES server honoured (trailing slash trimmed)" \
  "[open](https://ghe.example.com/owner/repo/blob/$SHA/src/app/main.py#L42)" "$(line_of 1 | sed 's/.* · //')"

echo "T-A3: no link unless every input is valid"
render
for n in 4 5 6 7 8 9; do
  check "finding $n (blank, range or zero line; absolute, parent or Windows path) gets no link" "0" "$(line_of "$n" | grep -c '\[open\]' || true)"
done
check "no link on P, R, T or suppressed lines" "0" \
  "$(grep -E '^- \*\*(P|R|T)[0-9]+\)\*\*|suppressed' "$work/out.md" | grep -c '\[open\]' || true)"
check "links appear only on numbered finding lines" "3" "$(grep -c '\[open\]' "$work/out.md")"
check "no bare #digits outside URLs (LADR-067)" "" "$(sed 's/([^)]*)//g' "$work/out.md" | grep -nE '#[0-9]' || true)"

unset GITHUB_REPOSITORY OPENCODE_REVIEW_REPORT_DIFF_TO_SHA
render; cp "$work/out.md" "$work/baseline.md"
for v in 0 false no off OFF " 0 "; do
  GITHUB_REPOSITORY=owner/repo OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$SHA" OPENCODE_REVIEW_REPORT_ENABLE_FINDING_LINKS="$v" render
  check "flag '$v' renders byte-identically to the unlinked body" "same" "$(cmp -s "$work/out.md" "$work/baseline.md" && echo same || echo differs)"
done
GITHUB_REPOSITORY=owner/repo render
check "missing sha → unlinked" "same" "$(cmp -s "$work/out.md" "$work/baseline.md" && echo same || echo differs)"
OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$SHA" render
check "missing repo → unlinked" "same" "$(cmp -s "$work/out.md" "$work/baseline.md" && echo same || echo differs)"
GITHUB_REPOSITORY='owner/repo) evil' OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$SHA" render
check "a repo that could break the markdown link → unlinked" "same" "$(cmp -s "$work/out.md" "$work/baseline.md" && echo same || echo differs)"
GITHUB_REPOSITORY=owner/repo OPENCODE_REVIEW_REPORT_DIFF_TO_SHA='not-a-sha' render
check "a non-hex sha → unlinked" "same" "$(cmp -s "$work/out.md" "$work/baseline.md" && echo same || echo differs)"

echo "D1: strip-finding-links.sh"
GITHUB_REPOSITORY=owner/repo OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$SHA" render
bash "$STRIP" < "$work/out.md" > "$work/stripped.md"
check "stripping the links restores the unlinked body byte for byte" "same" \
  "$(cmp -s "$work/stripped.md" "$work/baseline.md" && echo same || echo differs)"
printf '%s\n' 'Prose that mentions · [open](https://example.com) mid-line stays.' '- **R1)** 🟡 Residual risk: x · [open](https://e.com)' > "$work/other.md"
check "only numbered finding lines are stripped" "same" \
  "$(bash "$STRIP" < "$work/other.md" | cmp -s - "$work/other.md" && echo same || echo differs)"

echo "T-A5: consumers read a linked body exactly like an unlinked one"
SCORE="$SCRIPT_DIR/eval/lib/score-review.sh"
SHAPE="$SCRIPT_DIR/lib/review-has-shape.sh"
GITHUB_REPOSITORY=owner/repo OPENCODE_REVIEW_REPORT_DIFF_TO_SHA="$SHA" render
cp "$work/out.md" "$work/linked.md"
check "the linked fixture carries links" "3" "$(grep -c '\[open\]' "$work/linked.md")"
check "score-review.sh flags the unlinked fixture (the comparison is not vacuous)" \
  "HIGH,MEDIUM" "$(bash "$SCORE" "$work/baseline.md" | paste -sd, -)"
check "score-review.sh flags the same severities on the linked body" \
  "HIGH,MEDIUM" "$(bash "$SCORE" "$work/linked.md" | paste -sd, -)"
check "score-review.sh --lines flags the same findings (link suffix aside)" \
  "$(bash "$SCORE" --lines "$work/baseline.md")" \
  "$(bash "$SCORE" --lines "$work/linked.md" | sed -E 's/ · \[open\]\([^)]*\)$//')"
for f in baseline linked; do
  printf '**Issues Found:**\n' > "$work/shape-$f.md"; cat "$work/$f.md" >> "$work/shape-$f.md"
done
for f in baseline linked; do
  check "review-has-shape.sh accepts the $f body" "yes" \
    "$(bash "$SHAPE" "$work/shape-$f.md" 2>/dev/null && echo yes || echo no)"
done

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
