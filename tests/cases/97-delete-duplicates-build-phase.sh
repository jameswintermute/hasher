#!/bin/bash
# 97 — delete-duplicates.sh: BUILD phase progress, correctness unaffected
#
# v1.4.13 added progress reporting to two of the three slow validation
# passes in delete-duplicates.sh (SCAN, VERIFY) after a live report of a
# blank screen during plan application. Reported again, live, from the
# SAME NAS session: the [SCAN] bar completed, then the screen went blank
# a second time — a THIRD loop had been missed.
#
# That loop (building the hash->keeper map and the per-group DEL index)
# is arguably the most expensive of the three: for nearly every DEL line
# it forks an awk process to linearly scan the growing DEL_GROUPS file
# for hash membership, and for every hashed KEEP line it does the same
# against the growing KEEPER_MAP — another O(n²)-shaped pattern, this
# time per LINE rather than per GROUP.
#
# This loop also carries the most intricate error-detection logic in the
# whole script (duplicate KEEP entries per hash group, legacy-format
# KEEP/DEL pairing, mixed legacy-and-hashed groups), so this case pays
# particular attention to confirming that logic is completely unaffected
# by the added instrumentation, not just checking the bar appears.

case_description="delete-duplicates.sh: BUILD phase progress added, keeper-map error detection unaffected"

run_case() {
  # ── Correctness: a straightforward plan still applies exactly right ────
  make_sandbox build-correctness || return 1
  mkdir -p "$FIXTURES/data"
  local _i
  for _i in $(seq 1 40); do
    printf 'dupcontent-%s\n' "$_i" > "$FIXTURES/data/f$_i.txt"
    printf 'dupcontent-%s\n' "$_i" > "$FIXTURES/data/g$_i.txt"
  done
  set_paths "$FIXTURES/data"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv; _csv="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv" --mode bulk

  local _plan
  _plan="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"
  assert_file_exists "$_plan" "plan generated"

  run_tool delete-duplicates.sh "$_plan"
  assert_rc 0 "plan applies successfully"
  assert_out_contains "Plan structure valid: 40 hash groups" "correct group count after BUILD phase"
  assert_out_contains "Move complete: 40 files moved to quarantine" "correct quarantine count"

  local _remaining
  _remaining=$(find "$FIXTURES/data" -type f 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$_remaining" "40" "exactly the keepers remain (40 of 80 original files)"
  teardown_sandbox

  # ── Error detection: duplicate KEEP entries for one hash still refused ──
  # This is the specific validation logic the BUILD-phase loop performs;
  # confirms the added progress instrumentation didn't disturb it.
  make_sandbox build-duplicate-keep-refused || return 1
  mkdir -p "$FIXTURES/data"
  printf 'shared-content\n' > "$FIXTURES/data/a.txt"
  printf 'shared-content\n' > "$FIXTURES/data/b.txt"
  printf 'shared-content\n' > "$FIXTURES/data/c.txt"
  local _h
  _h="$(printf 'shared-content\n' | sha256sum | awk '{print $1}')"

  local _badplan="$SANDBOX/bad-plan.txt"
  {
    printf 'KEEP|%s/a.txt|%s\n' "$FIXTURES/data" "$_h"
    printf 'KEEP|%s/b.txt|%s\n' "$FIXTURES/data" "$_h"
    printf 'DEL|%s/c.txt|%s\n'  "$FIXTURES/data" "$_h"
  } > "$_badplan"

  run_tool delete-duplicates.sh "$_badplan"
  assert_rc 2 "plan with two KEEP entries for one hash is refused"
  assert_out_contains "contains more than one KEEP entry" "correct error message"
  # Nothing should have moved -- the refusal must happen before any action.
  assert_file_exists "$FIXTURES/data/a.txt" "no file touched after refusal"
  assert_file_exists "$FIXTURES/data/b.txt" "no file touched after refusal"
  assert_file_exists "$FIXTURES/data/c.txt" "no file touched after refusal"
  teardown_sandbox

  # ── Error detection: legacy KEEP with no following hashed DEL group ────
  # A plan with zero DEL entries exits earlier ("nothing to do") without
  # ever reaching the BUILD loop, so this needs at least one genuine
  # hashed DEL/KEEP pair to get past that check, PLUS a second, separate
  # legacy-format KEEP as the LAST line with nothing after it to consume
  # it -- that is what triggers the specific "no following hashed DEL
  # group" check at the end of the BUILD loop.
  make_sandbox build-orphan-legacy-keep-refused || return 1
  mkdir -p "$FIXTURES/data"
  printf 'resolved\n' > "$FIXTURES/data/keeper.txt"
  printf 'resolved\n' > "$FIXTURES/data/dup.txt"
  printf 'orphan\n' > "$FIXTURES/data/orphan.txt"
  local _h2
  _h2="$(printf 'resolved\n' | sha256sum | awk '{print $1}')"

  local _badplan2="$SANDBOX/bad-plan-2.txt"
  {
    printf 'KEEP|%s/keeper.txt|%s\n' "$FIXTURES/data" "$_h2"
    printf 'DEL|%s/dup.txt|%s\n'     "$FIXTURES/data" "$_h2"
    printf 'KEEP|%s/orphan.txt\n'    "$FIXTURES/data"   # legacy, unconsumed, last line
  } > "$_badplan2"

  run_tool delete-duplicates.sh "$_badplan2"
  assert_rc 2 "an orphaned legacy KEEP entry is refused, not silently accepted"
  assert_out_contains "has no following hashed DEL group" "correct orphan-keep error message"
  assert_file_exists "$FIXTURES/data/dup.txt" "no file touched after refusal"
  teardown_sandbox
}
