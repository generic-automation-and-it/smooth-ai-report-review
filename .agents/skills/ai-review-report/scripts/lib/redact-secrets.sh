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
      $cred = qr{://[^/\s@]+@|(?:password|pwd|accountkey|sharedaccesskey)\s*=}i;
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
    # URL userinfo is replaced WHOLE, user and password: a token is often the
    # user part (https://TOKEN@host, https://TOKEN:x-oauth-basic@host), which
    # a password-only pass left visible (review 5331864763 finding 1).
    s{(\b[a-z][a-z0-9+.-]*://)(?!<REDACTED>@)[^\s/@"\x27<>]+@}{$1<REDACTED>@}gi;
    # Connection-string credential values (Password= / Pwd= / AccountKey= /
    # SharedAccessKey=). Three reviews on PR 183 each found a way to leave part
    # of one visible, so the value is taken in whole:
    #   - quoted "…" or \x27…\x27: a doubled quote ("") and a backslash escape
    #     (\") stay inside the value (5331716081, 5331790729, 5331802857);
    #   - unquoted: everything up to the `;` delimiter or the end of the line,
    #     spaces and escaped quotes (a JSON-embedded \"…\") included. A log
    #     line with no `;` is therefore redacted to its end — over-redaction is
    #     the safe direction.
    # Quoted forms run first; the unquoted pass skips a value that starts with
    # a quote or is already <REDACTED>.
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*)"(?!<REDACTED>")(?:\\.|""|[^"\\\n])*"/$1"<REDACTED>"/gi;
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*)\x27(?!<REDACTED>\x27)(?:\\.|\x27\x27|[^\x27\\\n])*\x27/$1\x27<REDACTED>\x27/gi;
    # Backslash-escaped quotes around the value (a connection string embedded
    # in JSON: Password=\"alpha;omega\"). A `;` inside is part of the
    # password, so the delimiter-based pass below must not see it first
    # (review 5331854745): take \"…\" whole, and fail closed to the end of the
    # line when the escaped quote never closes.
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*+)\\(["\x27])(?!<REDACTED>)(?:(?!\\\2).)*?\\\2/$1\\$2<REDACTED>\\$2/gi;
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*+)\\(["\x27])(?!<REDACTED>)[^\r\n]*/$1\\$2<REDACTED>/gi;
    # Fail-closed for an UNTERMINATED quoted value (a log line cut mid-value:
    # Password="abc123secret): the passes above need the closing quote, the one
    # below skips a value starting with a quote, so neither matched and the
    # value survived (review 5331831530). A terminated value is already
    # <REDACTED> by now, so anything else after an opening quote is redacted
    # through the `;` delimiter or the end of the line.
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*+)(["\x27])(?!<REDACTED>)[^;\r\n]*/$1$2<REDACTED>/gi;
    # `\s*+` is possessive: the spaces after `=` cannot be given back, so a
    # space never becomes "the value" in front of an already-redacted one.
    s/(\b(?:password|pwd|accountkey|sharedaccesskey)\s*=\s*+)(?![\x27"]|<REDACTED>|\\["\x27]<REDACTED>)(?:\\.|[^;"\x27\\\r\n])+/$1<REDACTED>/gi;
  ' "$f" || { echo "redact-secrets.sh: could not redact a file under ${dir}" >&2; exit 1; }
done < "$list"

echo "redact-secrets.sh: ${files} file(s) redacted under ${dir}"
exit 0
