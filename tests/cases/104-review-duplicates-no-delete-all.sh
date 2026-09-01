#!/bin/bash
# 104 — review-duplicates.sh: the disabled "D = delete all" option has
# been removed entirely, not left as a permanently-disabled menu item
#
# Raised directly: the "D = delete all" choice had been disabled since
# apply-time safety requires exactly one live keeper per hash group (the
# whole verified-plan model delete-duplicates.sh's validator enforces —
# see the v1.4.17 rewrite). A user with a duplicate pair they want to
# discard entirely (not "keep one, remove the other") had no way to
# actually use the option that appeared to offer that. Rather than build
# a genuinely new no-keeper plan format to support it (a real, separate
# feature with its own safety implications for the whole apply-time
# model), the decision was to remove the disabled option outright: this
# project is a dedup/hash tool, not a general unused-file cleaner, and
# the option never did anything useful in the first place.
#
# This is a UI/menu-only change — the underlying plan format and
# delete-duplicates.sh's validator are completely untouched.

case_description="review-duplicates.sh: the disabled delete-all option no longer appears; pressing d/D is a plain invalid choice, not special-cased"

_setup_review_fixture() {
  mkdir -p "$FIXTURES/data"
  printf 'duplicate content\n' > "$FIXTURES/data/a.txt"
  printf 'duplicate content\n' > "$FIXTURES/data/b.txt"
  set_paths "$FIXTURES/data"
  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv; _csv="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv"
}

run_case() {
  # ── The menu itself no longer lists D at all ────────────────────────────
  make_sandbox review-no-delete-all-in-menu || return 1
  _setup_review_fixture
  local _report="$SANDBOX/logs/duplicate-hashes-latest.txt"

  run_tool_pty $'\nq\n' review-duplicates.sh --from-report "$_report"
  assert_out_not_contains "delete all" "the option itself is gone from the menu, not just re-labelled"
  assert_out_not_contains "one live keeper is required" "the old disabled-option hint text is gone too"
  teardown_sandbox

  # ── Pressing d/D falls through to the plain invalid-choice handler ──────
  make_sandbox review-d-is-plain-invalid-choice || return 1
  _setup_review_fixture
  local _report2="$SANDBOX/logs/duplicate-hashes-latest.txt"

  run_tool_pty $'\nd\n1\n' review-duplicates.sh --from-report "$_report2"
  assert_out_contains "Invalid choice" "d falls through to the generic invalid-choice message"
  assert_out_not_contains "Delete-all is disabled" "the old special-cased warning no longer fires"
  # The hint text listing valid options must not still mention a D that
  # no longer exists as a choice.
  assert_out_not_contains "or s, A, D, q" "the invalid-choice hint text was updated to match, not left stale"
  assert_out_contains "or s, A, q" "the corrected hint text is shown instead"
  teardown_sandbox

  # ── The rest of the interactive loop is completely unaffected ──────────
  # Confirms the removal didn't disturb the numeric-choice path: a normal
  # keep/discard selection, made right after an invalid 'd' keypress,
  # must still work and produce a correct plan.
  make_sandbox review-numeric-choice-still-works || return 1
  _setup_review_fixture
  local _report3="$SANDBOX/logs/duplicate-hashes-latest.txt"

  run_tool_pty $'\nd\n1\n' review-duplicates.sh --from-report "$_report3"
  assert_out_contains "Choice recorded: keeping #1" "the numeric choice after the invalid keypress still works"
  assert_out_contains "Plan saved to" "review completes and saves a plan"

  local _plan
  _plan="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"
  assert_file_exists "$_plan" "plan file was written"
  if [ -r "$_plan" ] && grep -q '^KEEP|' "$_plan" && grep -q '^DEL|' "$_plan"; then
    _assert_pass
  else
    _assert_fail "plan file missing expected KEEP/DEL lines"
  fi
  teardown_sandbox
}
