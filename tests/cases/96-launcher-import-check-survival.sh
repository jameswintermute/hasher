#!/bin/bash
# 96 — Launcher: survives non-zero returns from Import Check subcommands
#
# Reported live from a NAS session: selecting "5) Remove duplicate copies
# within import" when nothing needed deduplicating (a normal, everyday,
# non-error outcome — dedup-internal correctly exits 4 for it) caused the
# ENTIRE launcher to quit back to the shell prompt, rather than returning
# to the Import Check submenu the way every other menu action does.
#
# Root cause: launcher.sh runs under `set -eu` (confirmed), and all six
# `run_script "$_ic" <subcommand>` calls in the Import Check dispatch were
# unguarded — a bare command whose failure trips `set -e`. Every OTHER
# run_script call site in launcher.sh already guards against this (an
# `if`/`if ! ... then :; else _rc=$?; fi` wrapper, or an explicit
# `|| true`); these six were the only unguarded ones in the entire file.
# Import Check's own conventions (rc=2 invalid input, rc=3 missing
# prerequisite, rc=4 nothing to do) made this land constantly in normal
# use — "nothing to deduplicate" is one of the MOST common outcomes, not
# an edge case, so this bug was hit on essentially every routine use of
# option 5 once an import folder had already been cleaned.
#
# Fixed with `|| true` on all six calls, matching the pattern already
# used everywhere else in the file. This case exercises the launcher's
# actual menu dispatch (not import-check.sh directly, which the 90-95
# suites already cover thoroughly) specifically BECAUSE the earlier test
# suites never drove import-check.sh THROUGH the launcher's own `set -eu`
# context — that gap is exactly how this shipped unnoticed across five
# prior Import Check releases.
#
# State (import folder configured, scanned) is prepared via the same
# direct run_tool_with_input()/run_tool() helpers 90-95 already use —
# reliable and already proven. Only the specific behaviour under test
# (does the launcher's own menu dispatch survive) goes through the actual
# interactive launcher.sh, kept to the minimum key sequence needed.

case_description="Launcher: Import Check submenu survives a subcommand returning non-zero (rc 2/3/4)"

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

# Drive the interactive launcher with a scripted key sequence.
_launcher_sequence() {
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && printf '%s\n' "$@" | \
    timeout "${TEST_TIMEOUT:-60}" bash launcher.sh \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

run_case() {
  # ── Option 5, the exact reported case: nothing to deduplicate ──────────
  make_sandbox launcher-dedup-nothing || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'a\n' > "$FIXTURES/import/one.txt"
  printf 'b\n' > "$FIXTURES/import/two.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  # Only the actual behaviour under test goes through launcher.sh:
  # i (enter Import Check) -> 5 (dedup-internal, will return rc=4) ->
  # <blank> (the "Press Enter to continue" prompt) -> b (back) -> q (quit).
  _launcher_sequence i 5 "" b q
  assert_rc 0 "launcher exits cleanly (via 'q'), not killed by set -e"
  assert_out_contains "Nothing to deduplicate" "the reported outcome occurred"
  # If set -e had killed the launcher, "Bye." (its own deliberate quit
  # message) would never print -- the process would have died at the
  # dispatch line instead of ever reaching option 'b' or 'q'.
  assert_out_contains "Bye." "launcher reached its own intentional quit path"
  teardown_sandbox

  # ── Option 3 (summary) with no NAS manifest at all: rc=3 ────────────────
  make_sandbox launcher-summary-rc3 || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/import/f.txt"
  # Deliberately no _hash_nas call -- no NAS manifest exists yet.

  run_tool_with_input "$FIXTURES/import" import-check.sh setup

  _launcher_sequence i 3 "" b q
  assert_rc 0 "launcher survives summary's rc=3 (no NAS manifest)"
  assert_out_contains "Bye." "launcher reached its own intentional quit path"
  teardown_sandbox

  # ── Option 4 (discard) run twice: second run hits staleness refusal ────
  # Exercises the v1.4.10 staleness-refusal path (a deliberate, expected
  # non-zero exit) specifically THROUGH the launcher, not import-check.sh
  # directly, which is exactly the gap that let the original bug ship.
  make_sandbox launcher-discard-stale || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'shared\n' > "$FIXTURES/nas/keeper.txt"
  printf 'shared\n' > "$FIXTURES/import/copy.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  # First discard succeeds; second, without an intervening scan, refuses
  # (rc=2, staleness guard) -- both handled through the launcher's own
  # confirmation prompt ('y') and continue-prompt (blank) in sequence.
  _launcher_sequence i 4 y "" 4 y "" b q
  assert_rc 0 "launcher survives a second discard's staleness refusal"
  assert_out_contains "Bye." "launcher reached its own intentional quit path"
  teardown_sandbox
}
