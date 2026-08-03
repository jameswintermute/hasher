#!/bin/bash
# 70 — Launcher run-status reporting
#
# The launcher summary describes the LAST completed run. While a new hash is
# in flight that summary is stale by definition, and its recommended action
# ("rerun duplicate analysis") would collide with the run already underway.
# Worse, the user has no way to see how far along they are without leaving
# the menu.
#
# These cases drive the launcher with a synthetic pidfile and a background
# log containing known progress lines, so the parsing is checked against
# the exact formats hasher.sh emits.

case_description="Launcher run status: live progress takes precedence over stale summary"

# Drive the launcher to the menu and quit, returning its output.
# The launcher is interactive, so 'q' is fed on stdin.
_launcher_screen() {
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && printf 'q\n' | \
    timeout "${TEST_TIMEOUT:-60}" bash launcher.sh \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

# Make the launcher believe a hash is running, and supply a progress line.
# Returns the fake PID so the caller can reap it.
_fake_running_hash() {
  local _progress="$1"
  # stdout and stderr are redirected because this function is called through
  # command substitution: a background job inheriting the substitution's
  # pipe holds it open, and $(...) then blocks until the job exits rather
  # than until the function returns. Without this the suite waits out the
  # full sleep on every case.
  sleep 45 >/dev/null 2>&1 &
  local _p=$!
  printf '%s\n' "$_p" > "$SANDBOX/var/hasher.pid"
  if [ -n "$_progress" ]; then
    printf '%s\n' "$_progress" > "$SANDBOX/logs/background.log"
  else
    : > "$SANDBOX/logs/background.log"
  fi
  printf '%s' "$_p"
}

# A minimal complete manifest, so the launcher shows the main menu rather
# than the first-run screen.
_seed_manifest() {
  local _h
  _h="$(printf 'seed\n' | sha256sum | awk '{print $1}')"
  printf 'path,size_bytes,mtime_epoch,algo,hash\n' \
    > "$SANDBOX/hashes/hasher-2026-08-01-000000-1.csv"
  printf '"/tmp/seed.txt",5,1700000000,sha256,%s\n' "$_h" \
    >> "$SANDBOX/hashes/hasher-2026-08-01-000000-1.csv"
}

run_case() {
  # ── Hashing phase: percentage, counts and ETA ─────────────────────────
  make_sandbox status-hashing || return 1
  _seed_manifest
  local _pid
  _pid="$(_fake_running_hash '[2026-08-03 10:03:24] [RUN abc-123] [PROGRESS] Hashing: [41%] 108267/263289 | elapsed=03:49:04 (3h 49m) eta=05:27:59 (5h 27m)')"

  _launcher_screen

  assert_out_contains "Hashing in progress" "in-progress heading"
  assert_out_contains "41%" "percentage"
  assert_out_contains "108267/263289" "file counts"
  assert_out_contains "5h 27m" "estimated remaining"

  # The stale summary and its colliding recommendation must be suppressed.
  assert_out_not_contains "rerun duplicate analysis" "stale recommendation suppressed"
  assert_out_not_contains "waiting for duplicate analysis" "stale summary suppressed"

  # The menu itself must still render — the panel replaces the summary,
  # not the interface.
  assert_out_contains "Stage 1" "menu still shown"

  kill "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
  teardown_sandbox

  # ── Walk phase: no percentage is possible, and none is invented ───────
  make_sandbox status-walk || return 1
  _seed_manifest
  _pid="$(_fake_running_hash '[2026-08-03 10:00:15] [RUN abc-123] [PROGRESS] Walking paths: 84213 file(s) discovered so far | elapsed=00:02:15')"

  _launcher_screen

  assert_out_contains "Hashing in progress" "in-progress heading"
  assert_out_contains "84213" "discovered count"
  assert_out_contains "No estimate yet" "honest absence of an ETA"
  # Inventing a percentage during the walk would be a lie: the denominator
  # is exactly what the walk is still determining.
  assert_out_not_contains "Progress:" "no fabricated percentage"

  kill "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
  teardown_sandbox

  # ── Started, but no progress line has been written yet ────────────────
  make_sandbox status-startup || return 1
  _seed_manifest
  _pid="$(_fake_running_hash '')"

  _launcher_screen

  assert_out_contains "Hashing in progress" "in-progress heading"
  assert_out_contains "Starting up" "startup message"

  kill "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
  teardown_sandbox

  # ── Nothing running: the normal summary path is restored ──────────────
  # Guards against the progress panel swallowing the idle case.
  make_sandbox status-idle || return 1
  _seed_manifest
  rm -f "$SANDBOX/var/hasher.pid"

  _launcher_screen

  assert_out_not_contains "Hashing in progress" "no false in-progress claim"
  assert_out_contains "Stage 1" "menu shown"
  teardown_sandbox
}
