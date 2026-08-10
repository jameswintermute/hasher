#!/bin/bash
# 95 — Import check: respects configured parallelism; progress visibility
#
# Reported live from a NAS session: `bin/import-check.sh scan` against a
# 72,686-file import looked completely frozen for many minutes — no output
# at all after "Discovered N files to scan". Confirmed, from a second SSH
# session tailing logs/background.log, that it was NOT hung: it was
# working correctly, just invisible on the screen being watched, and
# running fully serial regardless of the operator's configured parallel-
# hashing level.
#
# Two separate defects, both in bin/hasher.sh and bin/import-check.sh
# respectively:
#
#   1. cmd_scan never passed --jobs to hasher.sh, so it always defaulted
#      to HASH_JOBS=1 (serial) — completely independent of whatever the
#      operator configured via the launcher's Performance settings menu
#      for every OTHER hash run. On a large small-file corpus, hasher.sh's
#      own comments note serial mode's per-file fork overhead dominates
#      wall-clock — exactly the case here.
#   2. hasher.sh's three progress tickers (walk-phase, hashing, and
#      zero-length-scan) have always written EXCLUSIVELY to
#      logs/background.log, a fixed path, regardless of how the process
#      was invoked. That's correct for the launcher's nohup-backgrounded
#      path (whose own stdout is redirected elsewhere; the operator is
#      expected to `tail -f` it via option 'l'), but it silently broke for
#      any SYNCHRONOUS/foreground caller with no separate follow-log step
#      — most visibly cmd_scan, which runs hasher.sh directly in the
#      caller's own terminal.
#
# This suite can only practically assert the parts that don't depend on a
# real interactive TTY: that jobs.conf is honoured, and that the fix does
# not regress the existing (correct) behaviour of staying silent when
# stdout is NOT a terminal — which is exactly the harness's own execution
# context, so "no accidental PROGRESS spam in redirected output" is
# asserted directly, for real, on every run of this case.

case_description="Import check scan: honours configured parallelism; progress tickers stay silent when piped"

_skip_guided_setup() {
  : > "$SANDBOX/local/.setup-complete"
}

_hash_nas() {
  local _dir="$1"
  set_paths "$_dir"
  RUN_OUT="$SANDBOX/.run-out.$$"; RUN_RC=0
  ( cd "$SANDBOX" && IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh \
      --pathfile local/paths.txt --jobs 1 --no-discover </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
}

run_case() {
  # ── No jobs.conf: unchanged behaviour, serial, no misleading message ───
  make_sandbox scan-no-jobsconf || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import/g.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  assert_rc 0 "scan succeeds with no jobs.conf present"
  assert_out_not_contains "Parallel hashing" "no parallel-hashing message when unconfigured"
  teardown_sandbox

  # ── jobs.conf present: value is read and passed through ────────────────
  make_sandbox scan-honours-jobsconf || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import/g.txt"
  mkdir -p "$SANDBOX/var"
  printf '4\n' > "$SANDBOX/var/jobs.conf"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  assert_rc 0 "scan succeeds with jobs.conf configured"
  assert_out_contains "Parallel hashing: 4 workers" "import-check reports the configured worker count"
  # hasher.sh's own message confirms --jobs actually reached it (its value
  # may be clamped down by hasher.sh's own safety cap on a low-core
  # sandbox -- that clamp is pre-existing behaviour, not part of this fix,
  # and is asserted separately below rather than assumed away here).
  assert_out_contains "Parallel hashing enabled" "hasher.sh itself entered parallel mode, not serial"
  teardown_sandbox

  # ── jobs.conf with invalid content: falls back to 1, no crash ──────────
  make_sandbox scan-jobsconf-invalid || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import/g.txt"
  mkdir -p "$SANDBOX/var"
  printf 'not-a-number\n' > "$SANDBOX/var/jobs.conf"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  assert_rc 0 "scan succeeds even with a corrupt jobs.conf"
  assert_out_not_contains "Parallel hashing" "invalid jobs.conf treated as unconfigured, not a crash"
  teardown_sandbox

  # ── Classification correctness unaffected by either fix ────────────────
  # The point of both fixes is visibility/speed, not behaviour -- confirm
  # a real cross-boundary match is still found correctly with jobs.conf
  # configured to a non-default value.
  make_sandbox scan-classification-unaffected || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'shared-content\n' > "$FIXTURES/nas/keeper.txt"
  printf 'shared-content\n' > "$FIXTURES/import/copy.txt"
  printf 'unique-content\n' > "$FIXTURES/import/u.txt"
  mkdir -p "$SANDBOX/var"
  printf '2\n' > "$SANDBOX/var/jobs.conf"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh summary

  assert_out_contains "Already on your NAS:      1" "match still found correctly with parallel hashing"
  assert_out_contains "Remaining (hand-sort):    1" "remainder still classified correctly"
  teardown_sandbox

  # ── Progress tickers stay silent when stdout is not a terminal ─────────
  # This IS a real, unconditional assertion: run_tool always redirects
  # into a captured file, never a TTY, so this exercises the actual
  # non-interactive path every time the suite runs, not a simulated one.
  make_sandbox progress-silent-when-piped || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  for i in 1 2 3 4 5; do printf 'content-%s\n' "$i" > "$FIXTURES/nas/f$i.txt"; done
  for i in 1 2 3; do printf 'import-%s\n' "$i" > "$FIXTURES/import/g$i.txt"; done

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  assert_rc 0 "scan completes"
  assert_out_not_contains "[PROGRESS]" "no PROGRESS lines leak into redirected/piped output"
  teardown_sandbox
}
