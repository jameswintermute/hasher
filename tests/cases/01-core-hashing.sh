#!/bin/bash
# 01 — Core hashing regression
#
# The happy path. If this fails, nothing else in the suite is meaningful.
# Also guards the properties every later case assumes: one row per file,
# accurate counts, a sorted CSV, and rc=0.

case_description="Core hashing: clean run produces a complete sorted manifest"

run_case() {
  make_sandbox core || return 1
  fixture_files "$FIXTURES/data" 5
  set_paths "$FIXTURES/data"

  run_hasher --pathfile local/paths.txt --jobs 2 --no-discover

  assert_rc 0 "clean hash run"
  assert_out_contains "hashed=5, failed=0, unstable=0" "summary counts"

  local _csv; _csv="$(latest_csv)"
  assert_file_exists "$_csv" "manifest"
  assert_eq "$(csv_rows "$_csv")" "5" "manifest row count"

  # No partial manifest should be produced by a clean run.
  assert_glob_count "$SANDBOX/hashes/partial-*.csv" "0" "partial manifests"

  # v1.3.22 fail-safe sort: body must be byte-identical to LC_ALL=C sort.
  if [ -r "$_csv" ]; then
    tail -n +2 "$_csv" > "$SANDBOX/.body"
    LC_ALL=C sort "$SANDBOX/.body" > "$SANDBOX/.sorted"
    if cmp -s "$SANDBOX/.body" "$SANDBOX/.sorted"; then _assert_pass
    else _assert_fail "manifest body is not LC_ALL=C sorted"; fi
  fi

  teardown_sandbox
}
