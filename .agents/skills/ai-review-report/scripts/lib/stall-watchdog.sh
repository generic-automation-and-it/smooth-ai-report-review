#!/bin/bash
# stall-watchdog.sh — kill a chunk whose model has gone silent, before its budget
# expires (LADR-101).
#
# Usage:
#   bash stall-watchdog.sh <timeout_pid> <watch_file> <threshold_seconds> <chunk_label> <marker_file>
#
# Run it in the BACKGROUND next to the `timeout`-wrapped model call, and kill it
# when that call returns. It exits 0 in every case; the kill it may perform is
# the whole point, and its status is never consulted (the caller's `wait` on the
# model call is the status that matters).
#
# WHY a watchdog at all. The only detector the gate had was the outer
# `timeout`, and it fires exactly once, at the very end of the budget. A chunk
# whose model is making progress but far too slowly therefore cost the ENTIRE
# LADR-081 primary share before anything reacted. Measured on run 36837246807
# (job 110287529991, PR #144): chunk 0 launched at 08:36:02 with a 1000 s budget
# split 650 s primary / 350 s reserve, was killed at exit 124 at 08:46:52 —
# 10m50s of a 17m19s gate run, 63% of wall clock. The preserved stderr log shows
# why: the model was still in its file-exploration phase, working steadily,
# one small Read/Glob round-trip at a time through a slow endpoint. It was never
# hung; it was merely unkillably slow to detect. The LADR-082 retry then rescued
# the chunk in 5m18s, which is the proof that nothing was wrong with the chunk
# itself. Typical runs of this workflow finish in 2.7–6 min.
#
# THE SIGNAL: byte growth in `ci_temp/reviews/chunk_<n>_stderr.log`.
#
# That file is the tool-event stream — the `> review · model` header, every
# `Read`/`Glob`/`Grep` invocation, and every error — and it is the one file the
# gate already preserves on failure (`lib/report-error-log.sh` copies it to
# `ci_temp_logs/` precisely because naming its path was useless). Byte growth is
# the authoritative signal because it is the only one that cannot false-positive
# on a slow-but-streaming model: a model thinking for 60 s between tool calls
# emits nothing during that window, but a model spending 60 s doing 30 Reads
# emits bytes continuously and is never near the threshold. Gating on the SHAPE
# of the growth (tool events vs raw model text) was considered and rejected: it
# is strictly more fragile for no additional safety, because raw model text on
# stderr is itself evidence the model is alive and doing work.
#
# Deliberately NOT used as the signal:
#   - the review body (`chunk_<n>.md`) — it only appears when the model has
#     already finished, so a model that never writes it looks identical to a
#     model still working;
#   - CPU time of the opencode process — a model blocked on a slow HTTPS read is
#     idle by that measure while being perfectly healthy;
#   - the presence of the process — a hung `opencode` process is exactly the
#     case this must catch.
#
# WHY killing the PROCESS GROUP is safe and necessary. `lib/opencode-with-
# fallback.sh` is a bash script that spawns `opencode`, which spawns the model
# transport; a signal to the direct child alone leaves the grandchildren running
# (the macOS `timeout` shim in `local-review.sh` documents that exact orphaning
# as the root cause of the old local "deadlock"). GNU `timeout` calls
# `setpgid(0, 0)` before forking, so the `timeout` process is a process-group
# leader and its PID IS its PGID — killing `-<pid>` reaches the whole tree. The
# per-worktask constraint is that a stall kill must be indistinguishable from a
# timeout to everything downstream, and group-killing is how that is achieved:
# `timeout` sees its monitored child die, exits non-zero, and the caller's
# existing failure path runs unchanged.
#
# The macOS `local-review.sh` shim is a perl script that does NOT create a new
# process group for its `timeout` equivalent, so `kill -TERM -<pid>` there would
# find no such group and the direct `kill -TERM <pid>` fallback applies. That is
# best-effort by design: this gate runs on `ubuntu-latest` (GNU coreutils) in
# CI, and a local run degrades to the old behaviour rather than to a wrong kill.
set -uo pipefail

_timeout_pid="${1:-}"
_watch_file="${2:-}"
_threshold="${3:-}"
_label="${4:-chunk}"
_marker="${5:-}"

# Nothing to watch, or a threshold that is not usable — stay out of the way
# entirely. Silently exiting 0 is correct: the watchdog must never be the reason
# a chunk behaves differently, only ever the reason it stops earlier.
if [ -z "$_timeout_pid" ] || [ -z "$_watch_file" ] || ! [[ "$_threshold" =~ ^[1-9][0-9]*$ ]]; then
  exit 0
fi

# Poll often enough that a threshold is honoured to within one interval, and
# rarely enough that a 7-way parallel chunk loop does not spend its time in
# `stat`. 10 s against a 240 s default is a 4% error bar on the kill point,
# which is immaterial next to the 8 minutes being saved.
POLL_SECONDS=10

# Never poll slower than the threshold itself. Without this a small configured
# threshold is honoured only to the width of a poll interval — a 30 s threshold
# would not fire before 40 s, and a test could not exercise the detector at all
# without waiting a full 10 s per case. Clamped to 1 s so a 1 s threshold is still
# expressible; the loop counts elapsed time by the interval it actually slept,
# so the kill point is `threshold..threshold + poll`.
[ "$_threshold" -lt "$POLL_SECONDS" ] && POLL_SECONDS="$_threshold"

_file_size() {
  # Byte count, or 0 when the file does not exist yet (a model that has not
  # written its first stderr byte is not evidence of anything on its own — the
  # threshold is measured from process start, not from first output).
  if [ -f "$_watch_file" ]; then
    wc -c < "$_watch_file" 2>/dev/null | tr -d ' \t\n' || echo 0
  else
    echo 0
  fi
}

_last_size=$(_file_size)
_elapsed=0

while [ "$_elapsed" -lt "$_threshold" ]; do
  # The model call finished on its own; nothing to police.
  if ! kill -0 "$_timeout_pid" 2>/dev/null; then
    exit 0
  fi

  sleep "$POLL_SECONDS"
  _elapsed=$(( _elapsed + POLL_SECONDS ))

  _size=$(_file_size)
  if [ "$_size" != "$_last_size" ]; then
    _last_size="$_size"
    _elapsed=0
    continue
  fi

  # Growth resets the clock. Silence accumulates it. This is the whole detector.
done

# Still here: no bytes for the whole threshold. Confirm the target is genuinely
# still alive before killing, so a race with the `timeout` firing on its own
# cannot turn a normal timeout into a kill we then misattribute.
if ! kill -0 "$_timeout_pid" 2>/dev/null; then
  exit 0
fi

echo "⏱️  ${_label} stalled — no output for ${_threshold}s, killing (LADR-101)" >&2

# Marker file so the caller's log and any diagnostic group can distinguish a
# stall kill from a budget timeout after the fact. Purely diagnostic: the
# routing is carried by the non-zero exit, exactly as for a timeout, and nothing
# downstream reads this (LADR-031's `.failed` flag remains the only control
# signal — a watchdog must never become a second one).
[ -n "$_marker" ] && printf 'stalled: no output for %ss (LADR-101)\n' "$_threshold" > "$_marker" 2>/dev/null

# Process group first (GNU `timeout` is its own group leader, so -PID reaches
# `opencode` and the model transport), then the direct pid. Both are best-effort:
# a watchdog that cannot kill anything must not become the reason the stage
# hangs, so nothing here is fatal and the caller's own `timeout` remains the
# backstop that bounds the stage regardless.
kill -TERM "-${_timeout_pid}" 2>/dev/null || kill -TERM "$_timeout_pid" 2>/dev/null || true

# Give the tree a moment to unwind on TERM, then insist. A model blocked on a
# hung socket may not act on TERM at all, and the point of the kill is to stop
# paying for it.
_n=0
while [ "$_n" -lt 5 ] && kill -0 "$_timeout_pid" 2>/dev/null; do
  sleep 1
  _n=$(( _n + 1 ))
done
if kill -0 "$_timeout_pid" 2>/dev/null; then
  kill -KILL "-${_timeout_pid}" 2>/dev/null || kill -KILL "$_timeout_pid" 2>/dev/null || true
fi

exit 0