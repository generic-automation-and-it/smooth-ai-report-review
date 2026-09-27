#!/bin/bash
# redact-secrets.sh — replace secrets with <REDACTED> in every file under a
# directory, in place, before it is kept as an artifact.
#
# Usage: redact-secrets.sh <dir>
#
# The skill-secret-handling checklist requires knowledge artefacts (run
# summaries included) to redact to `<REDACTED>`. Run artifacts carry model
# prompts, model output, recommendations and test logs — text derived from the
# PR, which can repeat a credential quoted in a finding or echoed by a test
# (PR 179, review 5331608121 finding 1). Two passes:
#
#   1. Exact values. Every environment variable whose NAME looks like a secret
#      (*_API_KEY, *_TOKEN, *_SECRET, *_PASSWORD, *_PAT) and whose value is at
#      least 8 characters is replaced wherever it appears. Values are read from
#      the environment inside perl — never passed as arguments, so they never
#      reach argv or a process listing.
#   2. Well-known credential shapes, whatever their source: GitHub tokens
#      (ghp_/gho_/ghu_/ghs_/ghr_, github_pat_), OpenAI/Anthropic/OpenRouter-style
#      `sk-…` keys, AWS access key ids, Google API keys, Slack tokens, bearer
#      tokens, and PEM private-key blocks.
#
# Exit status is the contract the caller relies on: 0 only when every file was
# processed. On any failure it exits non-zero, and the caller must then NOT
# upload the directory — an unredacted artifact is the outcome this exists to
# prevent. It prints only counts, never a value.
set -uo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "redact-secrets.sh: directory required" >&2; exit 64; }
[ -d "$dir" ] || exit 0
command -v perl >/dev/null 2>&1 || { echo "redact-secrets.sh: perl unavailable — cannot redact" >&2; exit 1; }

files=0
while IFS= read -r -d '' f; do
  files=$((files + 1))
  perl -0777 -i -pe '
    BEGIN {
      @vals = sort { length($b) <=> length($a) }
              grep { length($_) >= 8 }
              map  { $ENV{$_} }
              grep { /(?:_API_KEY|_TOKEN|_SECRET|_PASSWORD|_PAT)$/ || /^(?:GH_TOKEN|GITHUB_TOKEN)$/ } keys %ENV;
    }
    for my $v (@vals) { s/\Q$v\E/<REDACTED>/g; }
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/<REDACTED>/gs;
    s/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/<REDACTED>/g;
    s/\bgithub_pat_[A-Za-z0-9_]{20,}\b/<REDACTED>/g;
    s/\bsk-(?:ant-|or-)?[A-Za-z0-9_-]{20,}/<REDACTED>/g;
    s/\bAKIA[0-9A-Z]{16}\b/<REDACTED>/g;
    s/\bAIza[0-9A-Za-z_-]{35}\b/<REDACTED>/g;
    s/\bxox[abprs]-[A-Za-z0-9-]{10,}/<REDACTED>/g;
    s/(\b[Bb]earer\s+)[A-Za-z0-9._~+\/=-]{16,}/$1<REDACTED>/g;
  ' "$f" || { echo "redact-secrets.sh: could not redact a file under ${dir}" >&2; exit 1; }
done < <(find "$dir" -type f -print0)

echo "redact-secrets.sh: ${files} file(s) redacted under ${dir}"
exit 0
