#!/bin/bash
# Offline regression test for post-review.sh — a review must be anchored to the
# commit it actually reviewed (LADR-109), not to the PR's head at post time.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$GH_ARGS_FILE"
STUB
chmod +x "$TMP/bin/gh"

printf 'review body\n' > "$TMP/body.md"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/post-review.sh"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_FILE="$TMP/args"
post_review owner/repo 42 0123456789abcdef0123456789abcdef01234567 REQUEST_CHANGES "$TMP/body.md"

args="$(cat "$GH_ARGS_FILE")"
for expected in \
  '--method' \
  'POST' \
  'repos/owner/repo/pulls/42/reviews' \
  'commit_id=0123456789abcdef0123456789abcdef01234567' \
  'event=REQUEST_CHANGES' \
  "body=@$TMP/body.md"
do
  if ! printf '%s\n' "$args" | grep -Fqx -- "$expected"; then
    echo "❌ missing argument: $expected" >&2
    printf '%s\n' "$args" >&2
    exit 1
  fi
done

echo "✅ post-review pins commit_id, the review event and the body file"

# A regression must not reintroduce the current-head anchor, and every post site
# must go through the helper.
RR="$SCRIPT_DIR/run-review.sh"
LR="$SCRIPT_DIR/local-review.sh"
for f in "$RR" "$LR"; do
  if grep -v '^[[:space:]]*#' "$f" | grep -q 'gh pr review'; then
    echo "❌ $(basename "$f") still posts through gh pr review" >&2
    exit 1
  fi
done
rr_count="$(grep -v '^[[:space:]]*#' "$RR" | grep -c 'post_review ' || true)"
lr_count="$(grep -v '^[[:space:]]*#' "$LR" | grep -c 'post_review ' || true)"
[ "$rr_count" = "5" ] || { echo "❌ run-review.sh has ${rr_count} post_review sites, expected 5" >&2; exit 1; }
[ "$lr_count" = "3" ] || { echo "❌ local-review.sh has ${lr_count} post_review sites, expected 3" >&2; exit 1; }
echo "✅ every review post uses post_review; no gh pr review remains"
