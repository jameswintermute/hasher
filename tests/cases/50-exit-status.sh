#!/bin/bash
# 50 — Exit-status fidelity
#
# Automation reads exit codes, not prose. A run that hashed nothing must not
# return 0, and a destructive tool that failed to move a file must not
# report success. Both were true at various points in the 1.3.x series.
#
# The contract:
#   0  everything requested succeeded
#   1  one or more hard failures
#   2  invalid input, or a safety refusal before acting
#   3  missing prerequisites (tools, paths)
#   4  completed, but some items were skipped for safety
#
# 4 is deliberately distinct from 1: a run that skipped items because the
# world changed underneath it is not the same as a run that broke.

case_description="Exit-status fidelity: failures and safety skips are distinguishable"

run_case() {
  # ── Total hash failure ────────────────────────────────────────────────
  make_sandbox hashfail || return 1
  fixture_files "$FIXTURES/data" 3
  set_paths "$FIXTURES/data"

  local _shim; _shim="$(shim_hash_always_fails)"
  run_hasher_with_shim "$_shim" --pathfile local/paths.txt --jobs 1 --no-discover

  assert_rc 1 "run where every hash failed"
  assert_out_contains "failed=3" "failure count"
  assert_out_contains "PARTIAL SNAPSHOT" "partial-snapshot banner"
  # The unusable manifest is moved out of the discoverable namespace.
  assert_glob_count "$SANDBOX/hashes/partial-*.csv" "1" "partial manifest"
  assert_glob_count "$SANDBOX/hashes/hasher-*.csv" "0" "no complete manifest"
  teardown_sandbox

  # ── Empty input ───────────────────────────────────────────────────────
  # With --jobs 2 this used to reach xargs with no input. On platforms
  # whose xargs lacks -r the command ran once with an empty argument,
  # producing a fabricated "Hashed 1/0 files (failures=1)".
  make_sandbox empty || return 1
  mkdir -p "$FIXTURES/nothing"
  set_paths "$FIXTURES/nothing"

  run_hasher --pathfile local/paths.txt --jobs 2 --no-discover

  assert_rc 0 "empty directory scan"
  assert_out_not_contains "failures=1" "no fabricated failure"
  assert_out_contains "No files to hash" "explicit empty-input message"

  local _csv; _csv="$(latest_csv)"
  assert_file_exists "$_csv" "header-only manifest"
  assert_eq "$(csv_rows "$_csv")" "0" "row count"
  teardown_sandbox

  # ── Destructive tool: failures are reported as failures ───────────────
  make_sandbox rmfail || return 1
  mkdir -p "$FIXTURES/junk"
  printf 'junk\n' > "$FIXTURES/junk/scratch.tmp"
  set_paths "$FIXTURES/junk"
  printf 'tmp\n' > "$SANDBOX/local/junk-extensions.txt"

  local _rmshim; _rmshim="$(shim_rm_fails)"
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && PATH="$_rmshim:$PATH" \
    timeout "${TEST_TIMEOUT:-60}" bash bin/delete-junk.sh --force </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?

  if [ "$RUN_RC" = "0" ]; then
    _assert_fail "delete-junk returned 0 despite every deletion failing"
  else _assert_pass; fi
  teardown_sandbox

  # ── Safety skip is rc=4, not rc=1 ─────────────────────────────────────
  # A plan is generated, then the keeper is removed before the plan is
  # applied. The DEL candidate can no longer be verified against anything,
  # so it must be skipped rather than moved on trust.
  make_sandbox keeper || return 1
  mkdir -p "$FIXTURES/data"
  printf 'shared-payload\n' > "$FIXTURES/data/aaa-keeper.txt"
  printf 'shared-payload\n' > "$FIXTURES/data/zzz-duplicate.txt"
  set_paths "$FIXTURES/data"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv2; _csv2="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv2" --mode bulk

  local _plan
  _plan="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"
  if [ -r "$_plan" ]; then
    local _keeper
    _keeper="$(grep '^KEEP|' "$_plan" | head -n1 | cut -d'|' -f2)"
    note "keeper: $_keeper"
    rm -f "$_keeper"

    run_tool delete-duplicates.sh "$_plan"
    assert_rc 4 "apply with a missing keeper"
    # v1.4.20: this assertion checked for the OLD per-item wording
    # ("Keeper is missing or not a regular file — SKIPPING: <path>"),
    # which v1.4.18 deliberately moved off the terminal and into the
    # apply log only, replaced on-screen by a categorised summary line
    # (see tests/cases/99-delete-duplicates-skip-summary.sh for why).
    # This test predates that change and was never updated for it —
    # found by running the full suite against a real merged repo,
    # where it failed on exactly this line. The terminal now shows the
    # category, not the per-item message; the full original wording is
    # confirmed separately, in the apply log, right below.
    assert_out_contains "keeper missing or not a regular file" "keeper verification message"
    assert_out_contains "safety skips" "safety-skip summary"

    local _apply_log
    _apply_log="$(ls -1t "$SANDBOX"/logs/delete-duplicates-apply-*.log 2>/dev/null | head -n1)"
    if [ -r "$_apply_log" ] && grep -q "Keeper is missing" "$_apply_log"; then
      _assert_pass
    else
      _assert_fail "full per-item detail no longer present in the apply log"
    fi

    # Nothing may have been quarantined.
    assert_glob_count "$SANDBOX/quarantine-*/*" "0" "quarantined files"
  else
    _assert_fail "no plan produced; keeper-verification path untested"
  fi
  teardown_sandbox
}
