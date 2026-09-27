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
#      least 8 characters is replaced wherever it appears. So is a connection
#      string (*CONNECTION_STRING*, *_DSN, DATABASE_URL, *_URI, *_URL) — but
#      only when its value actually carries a credential (URL userinfo, or a
#      Password=/AccountKey= pair): a plain URL such as GITHUB_SERVER_URL must
#      not redact every link to github.com. Values are read from the
#      environment inside perl — never passed as arguments, so they never
#      reach argv or a process listing.
#   2. Well-known credential shapes, whatever their source: GitHub tokens
#      (ghp_/gho_/ghu_/ghs_/ghr_, github_pat_), OpenAI/Anthropic/OpenRouter-style
#      `sk-…` keys, AWS access key ids, Google API keys, Slack tokens, bearer
#      tokens, PEM private-key blocks, and connection-string credentials: the
#      password in `scheme://user:password@host` and the value of
#      Password= / Pwd= / AccountKey= / SharedAccessKey= pairs (review
#      5331632755 finding 2 — the checklist names connection strings).
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

# Materialise the file list and check find's own status: inside a process
# substitution a traversal error (an unreadable directory) is invisible, and the
# loop would report success over files it never saw (review 5331632755
# finding 3). A list that cannot be built fails the whole run.
list="$(mktemp 2>/dev/null)" || { echo "redact-secrets.sh: cannot create a temp file" >&2; exit 1; }
trap 'rm -f "$list"' EXIT
if ! find "$dir" -type f -print0 > "$list"; then
  echo "redact-secrets.sh: could not list every file under ${dir}" >&2
  exit 1
fi

files=0
while IFS= read -r -d '' f; do
  files=$((files + 1))
  perl -0777 -i -pe '
    BEGIN {
      $cred = qr{://[^/\s@:]*:[^/\s@]+@|(?:password|pwd|accountkey|sharedaccesskey)\s*=}i;
      @vals = sort { length($b) <=> length($a) }
              grep { length($_) >= 8 }
              ( ( map { $ENV{$_} }
                  grep { /(?:_API_KEY|_TOKEN|_SECRET|_PASSWORD|_PAT)$/ || /^(?:GH_TOKEN|GITHUB_TOKEN)$/ } keys %ENV ),
                ( grep { /$cred/ }
                  map { $ENV{$_} }
                  grep { /(?:CONNECTION_?STRING|CONNSTR|_DSN|_URI|_URL)$/i || /^DATABASE_URL$/ } keys %ENV ) );
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
    s{(\b[a-z][a-z0-9+.-]*://[^\s/@:]+:)[^\s/@]+@}{$1<REDACTED>@}gi;
    # Quoted values first ("…" or \x27…\x27, spaces allowed inside): the
    # unquoted form stops at a quote and never matched them (review 5331716081
    # finding 1). A doubled quote is the connection-string escape for a quote
    # inside the value, so it belongs to the value: "alpha""omega" is one
    # credential, not "alpha" plus a visible "omega" (review 5331790729).
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*)"(?!<REDACTED>")(?:[^"\n]|"")*"/$1"<REDACTED>"/gi;
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*)\x27(?!<REDACTED>\x27)(?:[^\x27\n]|\x27\x27)*\x27/$1\x27<REDACTED>\x27/gi;
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*)(?![\x27"]|<REDACTED>)[^;"\x27\s]+/$1<REDACTED>/gi;
  ' "$f" || { echo "redact-secrets.sh: could not redact a file under ${dir}" >&2; exit 1; }
done < "$list"

echo "redact-secrets.sh: ${files} file(s) redacted under ${dir}"
exit 0
