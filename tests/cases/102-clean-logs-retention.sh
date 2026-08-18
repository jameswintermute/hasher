#!/bin/bash
# 102 — Log/report retention correctness
#
# v1.4.31 clean-logs.sh passed an unquoted glob as its first function
# argument. Once a pattern matched multiple files the shell expanded it before
# the call, shifting KEEP and LABEL out of position and silently breaking
# pruning. Exercise both retention limits and path handling.

case_description="Log housekeeping: correct 5/10 retention, newest preservation, path safety"

_touch_report_sequence() {
  local _dir="$1" _prefix="$2" _suffix="$3" _count="$4"
  local _i _f
  _i=1
  while [ "$_i" -le "$_count" ]; do
    _f="$_dir/${_prefix}${_i}${_suffix}"
    printf 'report-%s\n' "$_i" > "$_f"
    # Distinct mtimes make oldest/newest expectations deterministic without
    # depending on sub-second timestamp support.
    touch -t "20260101$((1000 + _i)).00" "$_f" 2>/dev/null || {
      # Portable fallback: the suite itself runs on Bash targets where sleep
      # is available; a one-second gap is acceptable in this small case.
      sleep 1
    }
    _i=$(( _i + 1 ))
  done
}

run_case() {
  # ── Five-file policy: seven reports become newest five ────────────────
  make_sandbox cleanlogs-five || return 1
  _touch_report_sequence "$SANDBOX/logs" "duplicate-groups-" ".txt" 7
  printf 'do-not-touch\n' > "$SANDBOX/logs/unrelated.txt"

  run_tool clean-logs.sh
  assert_rc 0 "clean-logs succeeds with seven matching reports"
  assert_glob_count "$SANDBOX/logs/duplicate-groups-*.txt" 5 "five-file policy retains exactly five reports"
  assert_file_missing "$SANDBOX/logs/duplicate-groups-1.txt" "oldest report pruned"
  assert_file_missing "$SANDBOX/logs/duplicate-groups-2.txt" "second-oldest report pruned"
  assert_file_exists "$SANDBOX/logs/duplicate-groups-3.txt" "oldest retained report remains"
  assert_file_exists "$SANDBOX/logs/duplicate-groups-7.txt" "newest report remains"
  assert_file_exists "$SANDBOX/logs/unrelated.txt" "unrelated log is untouched"
  teardown_sandbox

  # ── Ten-file policy: twelve plans become newest ten ──────────────────
  make_sandbox cleanlogs-ten || return 1
  _touch_report_sequence "$SANDBOX/logs" "review-dedupe-plan-" ".txt" 12

  run_tool clean-logs.sh
  assert_rc 0 "clean-logs succeeds with twelve matching plans"
  assert_glob_count "$SANDBOX/logs/review-dedupe-plan-*.txt" 10 "ten-file policy retains exactly ten plans"
  assert_file_missing "$SANDBOX/logs/review-dedupe-plan-1.txt" "oldest plan pruned"
  assert_file_missing "$SANDBOX/logs/review-dedupe-plan-2.txt" "second-oldest plan pruned"
  assert_file_exists "$SANDBOX/logs/review-dedupe-plan-12.txt" "newest plan remains"
  teardown_sandbox

  # ── No-match patterns are harmless ───────────────────────────────────
  make_sandbox cleanlogs-empty || return 1
  run_tool clean-logs.sh
  assert_rc 0 "clean-logs succeeds when retention globs match nothing"
  teardown_sandbox

  # ── Install path containing spaces remains safe ──────────────────────
  make_sandbox "clean logs spaces" || return 1
  _touch_report_sequence "$SANDBOX/logs" "duplicates-report " ".csv" 7
  # The production pattern is duplicates-*.csv; this intentionally includes
  # spaces after that prefix to prove each pathname remains one argv entry.
  mv "$SANDBOX/logs/duplicates-report 1.csv" "$SANDBOX/logs/duplicates-1 report.csv"
  mv "$SANDBOX/logs/duplicates-report 2.csv" "$SANDBOX/logs/duplicates-2 report.csv"
  mv "$SANDBOX/logs/duplicates-report 3.csv" "$SANDBOX/logs/duplicates-3 report.csv"
  mv "$SANDBOX/logs/duplicates-report 4.csv" "$SANDBOX/logs/duplicates-4 report.csv"
  mv "$SANDBOX/logs/duplicates-report 5.csv" "$SANDBOX/logs/duplicates-5 report.csv"
  mv "$SANDBOX/logs/duplicates-report 6.csv" "$SANDBOX/logs/duplicates-6 report.csv"
  mv "$SANDBOX/logs/duplicates-report 7.csv" "$SANDBOX/logs/duplicates-7 report.csv"

  run_tool clean-logs.sh
  assert_rc 0 "clean-logs succeeds from install path containing spaces"
  local _space_count
  _space_count="$(find "$SANDBOX/logs" -maxdepth 1 -type f -name 'duplicates-*.csv' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$_space_count" "5" "space-containing filenames retain newest five"
  assert_file_missing "$SANDBOX/logs/duplicates-1 report.csv" "oldest spaced filename pruned"
  assert_file_missing "$SANDBOX/logs/duplicates-2 report.csv" "second-oldest spaced filename pruned"
  assert_file_exists "$SANDBOX/logs/duplicates-7 report.csv" "newest spaced filename remains"
  teardown_sandbox
}
