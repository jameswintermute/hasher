#!/bin/bash
# 60 — Process and lock safety
#
# Two concurrent hash runs over the same corpus is the worst outcome the
# tool can produce: interleaved writes to the manifest and two sets of
# workers competing for the same disk. The lock exists to prevent that,
# and its failure modes are subtle.
#
# The historical bug: stale-lock recovery checked only whether the recorded
# PID was alive. SIGKILL the parent and its workers survive under the old
# process group, but the PID is gone — so the lock looked stale, was
# adopted, and a second run started alongside the orphans.
#
# Note on scope: these cases exercise lock *decisions* using synthetic lock
# directories. Killing real worker trees is left to manual testing, since
# doing it reliably inside a test harness risks leaving strays behind.

case_description="Process safety: lock ownership, orphan detection, broken pgrep"

run_case() {
  # ── Live PID holds the lock ───────────────────────────────────────────
  make_sandbox lock-live || return 1
  fixture_files "$FIXTURES/data" 2
  set_paths "$FIXTURES/data"

  # A process that genuinely exists and is not us.
  sleep 30 &
  local _live=$!

  mkdir -p "$SANDBOX/var/hasher.lock"
  printf '%s\n' "$_live" > "$SANDBOX/var/hasher.lock/pid"
  ps -o pgid= -p "$_live" 2>/dev/null | tr -d ' ' > "$SANDBOX/var/hasher.lock/pgid"
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id > "$SANDBOX/var/hasher.lock/boot_id"
  else
    printf 'unknown\n' > "$SANDBOX/var/hasher.lock/boot_id"
  fi
  date +%s > "$SANDBOX/var/hasher.lock/start_ts"

  # run_hasher clears the lock by design, so invoke directly here.
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh \
      --pathfile local/paths.txt --jobs 1 --no-discover </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?

  assert_rc 2 "second run while a live run holds the lock"
  assert_out_contains "already active" "active-run refusal"

  kill "$_live" 2>/dev/null || true
  wait "$_live" 2>/dev/null || true
  teardown_sandbox

  # ── Dead PID, but the recorded group still has live members ───────────
  # This is the SIGKILL-the-parent scenario. Whether those PIDs are genuine
  # orphaned workers or unrelated processes sharing our group, the tool
  # cannot tell them apart — so it must refuse rather than guess.
  make_sandbox lock-orphan || return 1
  fixture_files "$FIXTURES/data" 2
  set_paths "$FIXTURES/data"

  sleep 30 &
  local _sibling=$!
  local _sib_pgid
  _sib_pgid="$(ps -o pgid= -p "$_sibling" 2>/dev/null | tr -d ' ')"

  mkdir -p "$SANDBOX/var/hasher.lock"
  # A PID that cannot be alive.
  printf '999999\n' > "$SANDBOX/var/hasher.lock/pid"
  printf '%s\n' "$_sib_pgid" > "$SANDBOX/var/hasher.lock/pgid"
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id > "$SANDBOX/var/hasher.lock/boot_id"
  else
    printf 'unknown\n' > "$SANDBOX/var/hasher.lock/boot_id"
  fi
  date +%s > "$SANDBOX/var/hasher.lock/start_ts"

  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh \
      --pathfile local/paths.txt --jobs 1 --no-discover </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?

  assert_rc 2 "stale lock whose process group still has members"
  assert_out_contains "still has live processes" "orphan-detection message"

  kill "$_sibling" 2>/dev/null || true
  wait "$_sibling" 2>/dev/null || true
  teardown_sandbox

  # ── Dead PID and an empty group: safe to adopt ────────────────────────
  make_sandbox lock-stale || return 1
  fixture_files "$FIXTURES/data" 2
  set_paths "$FIXTURES/data"

  mkdir -p "$SANDBOX/var/hasher.lock"
  printf '999999\n' > "$SANDBOX/var/hasher.lock/pid"
  printf '999998\n' > "$SANDBOX/var/hasher.lock/pgid"
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id > "$SANDBOX/var/hasher.lock/boot_id"
  else
    printf 'unknown\n' > "$SANDBOX/var/hasher.lock/boot_id"
  fi
  date +%s > "$SANDBOX/var/hasher.lock/start_ts"

  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh \
      --pathfile local/paths.txt --jobs 1 --no-discover </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?

  assert_rc 0 "genuinely stale lock is adopted"
  assert_out_contains "Stale lock" "adoption notice"
  assert_eq "$(csv_rows "$(latest_csv)")" "2" "run completed after adoption"
  teardown_sandbox

  # ── pgrep present but non-functional ──────────────────────────────────
  # `command -v pgrep` succeeding says nothing about whether it works. A
  # broken build that exits clean with no output would silently make every
  # descendant enumeration return empty. The startup probe must notice and
  # fall back to ps.
  make_sandbox pgrep-broken || return 1
  fixture_files "$FIXTURES/data" 3
  set_paths "$FIXTURES/data"

  local _pshim; _pshim="$(shim_pgrep_broken)"
  run_hasher_with_shim "$_pshim" --pathfile local/paths.txt --jobs 2 --no-discover

  assert_rc 0 "run with a broken pgrep on PATH"
  assert_eq "$(csv_rows "$(latest_csv)")" "3" "all files hashed via ps fallback"
  teardown_sandbox
}
