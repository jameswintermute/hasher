#!/bin/bash
# 98 — delete-duplicates.sh: single-pass AWK validation rewrite (v1.4.17)
#
# v1.4.13/v1.4.14 added progress reporting to three loops in
# delete-duplicates.sh (SCAN, BUILD, VERIFY) that forked a bash-level awk
# process per line or per group against files that grew as the plan was
# processed — an O(n^2)-shaped pattern confirmed live on a 72,685-entry
# plan: BUILD alone reported a 17-minute ETA. Both releases deferred the
# actual rewrite by design, adding visibility to the cost rather than
# removing it.
#
# This is that rewrite: SCAN+BUILD+VERIFY replaced by one AWK pass using
# native associative arrays (PASS 1), plus a second AWK pass (PASS 2)
# that also eliminates keeper_for_hash() — found while tracing this,
# not previously flagged — which had been forking its own awk scan once
# PER DEL ENTRY inside the MOVE loop itself.
#
# This suite verifies two different things and keeps them in separate
# cases: that every existing safety rejection still fires with the exact
# same wording and exit code as before (correctness), and that the
# number of awk processes forked no longer scales with plan size
# (the actual algorithmic-shape proof — deterministic and hardware-
# independent, unlike a wall-clock threshold, which is why this is
# structural rather than timing-based).

case_description="delete-duplicates.sh rewrite: correctness preserved exactly, awk invocation count no longer scales with plan size"

_make_dup_plan() {
  # Writes $1 duplicate-pairs worth of fixture files under $FIXTURES/data
  # and returns (via echo) the generated plan file's path.
  local _n="$1" _i
  mkdir -p "$FIXTURES/data"
  for _i in $(seq 1 "$_n"); do
    printf 'dupcontent-%s\n' "$_i" > "$FIXTURES/data/f$_i.txt"
    printf 'dupcontent-%s\n' "$_i" > "$FIXTURES/data/g$_i.txt"
  done
  set_paths "$FIXTURES/data"
  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv; _csv="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv" --mode bulk
  ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1
}

run_case() {
  # ── Correctness: unchanged from the reader's perspective ────────────────
  make_sandbox rewrite-correctness || return 1
  local _plan; _plan="$(_make_dup_plan 30)"
  assert_file_exists "$_plan" "plan generated"

  run_tool delete-duplicates.sh "$_plan"
  assert_rc 0 "plan applies successfully"
  assert_out_contains "Plan structure valid: 30 hash groups" "correct group count"
  assert_out_contains "Move complete: 30 files moved to quarantine" "correct quarantine count"
  local _remaining
  _remaining=$(find "$FIXTURES/data" -type f 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$_remaining" "30" "exactly the keepers remain"
  teardown_sandbox

  # ── Duplicate KEEP still refused, with a path containing a space ────────
  # A space in a path broke an early draft of this rewrite's error-line
  # parsing (bash word-splitting on unquoted fields) — caught by testing
  # this exact case before it shipped, not by inspection. Kept as a
  # permanent regression guard.
  make_sandbox rewrite-duplicate-keep-space || return 1
  mkdir -p "$FIXTURES/data"
  printf 'shared\n' > "$FIXTURES/data/a b.txt"
  printf 'shared\n' > "$FIXTURES/data/c d.txt"
  printf 'shared\n' > "$FIXTURES/data/e f.txt"
  local _h
  _h="$(printf 'shared\n' | sha256sum | awk '{print $1}')"
  local _badplan="$SANDBOX/bad-plan.txt"
  {
    printf 'KEEP|%s/a b.txt|%s\n' "$FIXTURES/data" "$_h"
    printf 'KEEP|%s/c d.txt|%s\n' "$FIXTURES/data" "$_h"
    printf 'DEL|%s/e f.txt|%s\n'  "$FIXTURES/data" "$_h"
  } > "$_badplan"

  run_tool delete-duplicates.sh "$_badplan"
  assert_rc 2 "duplicate KEEP with space-containing paths still refused"
  assert_out_contains "contains more than one KEEP entry" "correct error message"
  assert_out_contains "a b.txt" "space-containing path preserved intact in error output"
  assert_out_contains "c d.txt" "second space-containing path preserved intact"
  assert_file_exists "$FIXTURES/data/a b.txt" "no file touched after refusal"
  teardown_sandbox

  # ── Missing keeper: ALL affected groups reported, not just the first ────
  make_sandbox rewrite-missing-keeper-collects-all || return 1
  mkdir -p "$FIXTURES/data"
  local _h1 _h2
  _h1="$(printf 'orphan-one\n' | sha256sum | awk '{print $1}')"
  _h2="$(printf 'orphan-two\n' | sha256sum | awk '{print $1}')"
  local _badplan2="$SANDBOX/bad-plan-2.txt"
  {
    printf 'DEL|%s/orphan1.txt|%s\n' "$FIXTURES/data" "$_h1"
    printf 'DEL|%s/orphan2.txt|%s\n' "$FIXTURES/data" "$_h2"
  } > "$_badplan2"

  run_tool delete-duplicates.sh "$_badplan2"
  assert_rc 2 "plan with two missing keepers is refused"
  assert_out_contains "2 group(s) have no unique keeper" "both missing groups counted, not just the first"
  teardown_sandbox

  # ── Legacy (unverified) plan path still works, unaffected by the rewrite ─
  make_sandbox rewrite-legacy-plan-unaffected || return 1
  mkdir -p "$FIXTURES/data"
  printf 'x\n' > "$FIXTURES/data/only.txt"
  local _legacyplan="$SANDBOX/legacy-plan.txt"
  {
    printf 'KEEP|%s/keeper.txt\n' "$FIXTURES/data"
    printf 'DEL|%s/only.txt\n' "$FIXTURES/data"
  } > "$_legacyplan"
  printf 'x\n' > "$FIXTURES/data/keeper.txt"

  run_tool_with_input "apply-unverified" delete-duplicates.sh "$_legacyplan" --allow-unverified-plan
  assert_rc 0 "legacy/unverified plan still applies with explicit opt-in"
  assert_file_missing "$FIXTURES/data/only.txt" "legacy DEL entry was moved"
  teardown_sandbox

  # ── Structural proof: awk invocation count does not scale with plan size ─
  # The actual algorithmic-shape assertion the rewrite is for. Deterministic
  # and hardware-independent, unlike a wall-clock threshold -- this is what
  # distinguishes "genuinely linear now" from "just fast on this machine
  # today". Two very different plan sizes must produce the SAME small,
  # fixed count.
  make_sandbox rewrite-awk-count-small || return 1
  local _plan_small; _plan_small="$(_make_dup_plan 20)"
  local _count_small
  _count_small="$( (cd "$SANDBOX" && bash -x bin/delete-duplicates.sh "$_plan_small" 2>&1 >/dev/null) | grep -c '^+ awk' )"
  teardown_sandbox

  make_sandbox rewrite-awk-count-large || return 1
  local _plan_large; _plan_large="$(_make_dup_plan 500)"
  local _count_large
  _count_large="$( (cd "$SANDBOX" && bash -x bin/delete-duplicates.sh "$_plan_large" 2>&1 >/dev/null) | grep -c '^+ awk' )"
  teardown_sandbox

  assert_eq "$_count_small" "$_count_large" "awk invocation count identical across a 25x plan-size difference (20 vs 500 groups)"
  if [ "${_count_small:-99}" -le 3 ]; then _assert_pass
  else _assert_fail "expected at most a handful of awk invocations, got $_count_small"; fi
}
