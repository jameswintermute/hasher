#!/bin/bash
# 99 — delete-duplicates.sh: categorised skip summary, not per-item flooding
#
# Reported live from a NAS session applying a 72,685-entry plan: a large
# fraction of DEL candidates had their keeper reorganised on disk since
# the plan was made (a stale scan against a live Photos Library — an
# expected, safe outcome, not an error). Each one produced 1-4 lines of
# per-item warn() output, flooding the terminal and burying the [MOVE]
# progress bar under thousands of lines. To someone watching it happen,
# that reads as an error storm even though nothing unsafe occurred —
# every single skip left a file in place, none were moved incorrectly.
#
# Fixed: per-item detail moved to the apply log only; the terminal shows
# one categorised summary line per skip REASON that actually occurred,
# with its count, plus a pointer to the log for anyone who wants the
# individual paths. This suite checks both halves: the terminal stays
# clean and the full detail is genuinely still on disk, not lost.

case_description="delete-duplicates.sh: skip detail moves to the apply log, terminal shows one categorised line per reason"

run_case() {
  # ── Many skips of the SAME reason produce ONE summary line, not N ───────
  make_sandbox skip-summary-many-same-reason || return 1
  mkdir -p "$FIXTURES/data"
  local _i
  for _i in $(seq 1 15); do
    printf 'content-%s\n' "$_i" > "$FIXTURES/data/dup$_i.txt"
    printf 'content-%s\n' "$_i" > "$FIXTURES/data/orig$_i.txt"
  done
  set_paths "$FIXTURES/data"
  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv; _csv="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv" --mode bulk

  local _plan
  _plan="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"
  assert_file_exists "$_plan" "plan generated"

  # Delete every KEEP target so every one of the 15 DEL candidates hits
  # the same "keeper missing" skip reason.
  local _keeper
  while IFS='|' read -r _tag _kp _kh; do
    [ "$_tag" = "KEEP" ] && rm -f -- "$_kp"
  done < "$_plan"

  run_tool delete-duplicates.sh "$_plan"
  assert_rc 4 "all 15 candidates safety-skipped"

  # The terminal output must contain exactly ONE categorised line for
  # this reason (with the count folded in), not 15 separate per-item
  # warn() bursts.
  local _summary_line_count
  _summary_line_count="$(grep -c 'keeper missing or not a regular file' "$RUN_OUT")"
  assert_eq "$_summary_line_count" "1" "exactly one summary line, not one per skipped file"
  assert_out_contains "keeper missing or not a regular file: 15" "correct count folded into the one summary line"

  # The terminal must NOT contain the old per-item detail phrasing.
  if grep -q 'SKIPPING: ' "$RUN_OUT"; then
    _assert_fail "per-item skip detail leaked onto the terminal"
  else
    _assert_pass
  fi

  # Full per-file detail must still exist -- just in the apply log, not
  # on screen. This is the other half of the guarantee: nothing was
  # actually lost, only moved off the live terminal.
  local _apply_log
  _apply_log="$(ls -1t "$SANDBOX"/logs/delete-duplicates-apply-*.log 2>/dev/null | head -n1)"
  assert_file_exists "$_apply_log" "apply log written"
  local _log_detail_count
  _log_detail_count="$(grep -c 'Keeper is missing or not a regular file' "$_apply_log" 2>/dev/null)"
  assert_eq "$_log_detail_count" "15" "all 15 individual skip details preserved in the apply log"

  # Nothing was quarantined -- every candidate was correctly left alone.
  assert_glob_count "$SANDBOX/quarantine-*/*" "0" "quarantined files"
  teardown_sandbox

  # ── Different skip reasons each get their own line ───────────────────
  make_sandbox skip-summary-mixed-reasons || return 1
  mkdir -p "$FIXTURES/data"
  printf 'aaa\n' > "$FIXTURES/data/keep-a.txt"
  printf 'aaa\n' > "$FIXTURES/data/del-a.txt"
  printf 'bbb\n' > "$FIXTURES/data/keep-b.txt"
  printf 'bbb\n' > "$FIXTURES/data/del-b.txt"
  set_paths "$FIXTURES/data"
  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv2; _csv2="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv2" --mode bulk

  local _plan2
  _plan2="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"

  # Group A/B: don't assume which filename the tool picked as KEEP (it
  # doesn't necessarily match either name) -- read the plan itself to
  # find the actual KEEP path for each hash.
  local _h_a _h_b _kp_a _kp_b
  _h_a="$(printf 'aaa\n' | sha256sum | awk '{print $1}')"
  _h_b="$(printf 'bbb\n' | sha256sum | awk '{print $1}')"
  _kp_a="$(awk -F'|' -v h="$_h_a" '$1=="KEEP" && $3==h {print $2}' "$_plan2")"
  _kp_b="$(awk -F'|' -v h="$_h_b" '$1=="KEEP" && $3==h {print $2}' "$_plan2")"
  [ -n "$_kp_a" ] && rm -f -- "$_kp_a"
  [ -n "$_kp_b" ] && printf 'changed-content\n' > "$_kp_b"

  run_tool delete-duplicates.sh "$_plan2"
  assert_rc 4 "two different skip reasons, both fire"
  assert_out_contains "keeper missing or not a regular file: 1" "first reason reported with its own count"
  assert_out_contains "keeper changed or could not be re-hashed: 1" "second reason reported with its own count, not merged with the first"
  teardown_sandbox

  # ── moves_fail and moves_skipped_changed categories in the SAME run ────
  # These are two genuinely separate counters (matching the pre-existing
  # "N failures; N safety skips" distinction in the final summary line),
  # but an early version of this feature listed BOTH kinds of category
  # under one header whose total came from only ONE of the two counters
  # (moves_skipped_changed) -- so a run with e.g. 2 keeper-missing skips
  # (moves_skipped_changed) and 1 symlink skip (moves_fail) printed
  # "2 file(s) skipped..." as the header, then listed BOTH categories
  # underneath, summing to 3 -- a header that didn't match its own list.
  # Caught by testing this exact combination, not by inspection. Kept
  # here permanently since the earlier two cases in this file, testing
  # only same-counter combinations, did not exercise this at all.
  make_sandbox skip-summary-mixed-counters || return 1
  mkdir -p "$FIXTURES/data"
  local _j
  for _j in 1 2 3; do
    printf 'content-%s\n' "$_j" > "$FIXTURES/data/dup$_j.txt"
    printf 'content-%s\n' "$_j" > "$FIXTURES/data/orig$_j.txt"
  done
  set_paths "$FIXTURES/data"
  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv3; _csv3="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv3" --mode bulk

  local _plan3
  _plan3="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"

  local _keepers3 _dels3
  _keepers3="$(grep '^KEEP' "$_plan3" | awk -F'|' '{print $2}')"
  _dels3="$(grep '^DEL' "$_plan3" | awk -F'|' '{print $2}')"
  local _k1 _k2 _d3
  _k1="$(printf '%s\n' "$_keepers3" | sed -n '1p')"
  _k2="$(printf '%s\n' "$_keepers3" | sed -n '2p')"
  _d3="$(printf '%s\n' "$_dels3" | sed -n '3p')"
  # Two moves_skipped_changed skips (keeper missing):
  rm -f -- "$_k1" "$_k2"
  # One moves_fail skip (symlink), a DIFFERENT counter entirely:
  rm -f -- "$_d3"
  ln -s /etc/hostname "$_d3"

  run_tool delete-duplicates.sh "$_plan3"
  assert_out_contains "2 file(s) skipped because the DEL or its keeper could not be safely re-verified:" "safety-skip header shows exactly 2, matching what it lists below"
  assert_out_contains "keeper missing or not a regular file: 2" "both keeper-missing skips counted under the safety-skip header"
  assert_out_contains "1 file(s) could not be moved:" "a SEPARATE header for the moves_fail bucket, with its own correct count"
  assert_out_contains "planned path is now a symlink: 1" "the symlink skip listed under its own header, not folded into the other one"

  # The actual bug this guards against: the symlink line appearing
  # directly under the safety-skip header (immediately after its "2
  # file(s)..." line and before "Every skip leaves the file in place"),
  # which is what happened when both categories shared one un-split
  # block -- a header stating "2" while three items were actually
  # listed beneath it. Checking for the string's mere presence
  # anywhere in the output (as the two assertions above do) would not
  # have caught this: it appears legitimately, just under the correct
  # second header. This checks it does NOT appear between the two
  # header lines specifically.
  if awk '
    /2 file\(s\) skipped because the DEL/ { in_block=1; next }
    /Every skip leaves the file in place/ { in_block=0 }
    in_block && /planned path is now a symlink/ { found=1 }
    END { exit !found }
  ' "$RUN_OUT"; then
    _assert_fail "symlink skip leaked into the safety-skip block, not its own moves_fail block"
  else
    _assert_pass
  fi
  teardown_sandbox
}
