#!/bin/bash
# 10 — Input validation
#
# Adversarial paths.txt content. Both bugs here shipped: overlapping roots
# double-hashed files and silently broke folder dedup (a folder whose files
# appeared twice got a different signature from its identical twin);
# explicitly listed symlinks were hashed as regular files, producing a row
# with the symlink's own metadata and the target's content hash.
#
# Neither was caught before release because every hand-written fixture used
# a single flat directory of ordinary files.

case_description="Input validation: overlapping roots, explicit symlinks"

run_case() {
  # ── Overlapping scan roots ────────────────────────────────────────────
  make_sandbox overlap || return 1
  fixture_overlapping_roots "$FIXTURES"
  # A careless (but entirely plausible) configuration: parent AND child.
  set_paths "$FIXTURES/parent" "$FIXTURES/parent/child"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover

  assert_rc 0 "overlapping roots run"
  local _csv; _csv="$(latest_csv)"
  # 2 distinct files, not 3 — nested.txt must not appear twice.
  assert_eq "$(csv_rows "$_csv")" "2" "deduplicated discovery row count"
  assert_out_contains "Removed 1 duplicate" "overlap warning"

  if [ -r "$_csv" ]; then
    local _dupes
    _dupes="$(tail -n +2 "$_csv" | awk -F',' '{print $1}' | sort | uniq -d | wc -l | tr -d ' ')"
    assert_eq "$_dupes" "0" "duplicate paths within manifest"
  fi
  teardown_sandbox

  # ── Explicitly listed symlink ─────────────────────────────────────────
  make_sandbox symlink || return 1
  fixture_symlink "$FIXTURES/links"
  set_paths "$FIXTURES/links/link.txt"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover

  # Every listed path was a symlink, so there is nothing to hash: rc=3 with
  # a message that names symlinks specifically, not the generic
  # "missing or unreadable" text.
  assert_rc 3 "all-symlink pathfile"
  assert_out_contains "symlinks" "symlink-specific error"
  assert_out_not_contains "missing or unreadable" "generic error suppressed"
  teardown_sandbox

  # ── Symlink alongside real directories ────────────────────────────────
  # The symlink is refused; the real directory still hashes.
  make_sandbox symlink-mixed || return 1
  fixture_symlink "$FIXTURES/links"
  fixture_files "$FIXTURES/real" 3
  set_paths "$FIXTURES/links/link.txt" "$FIXTURES/real"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover

  assert_rc 0 "mixed symlink and directory"
  local _csv2; _csv2="$(latest_csv)"
  # 3 from the real directory. The symlink contributes nothing, and its
  # target must not be pulled in by the symlink entry.
  assert_eq "$(csv_rows "$_csv2")" "3" "row count excludes symlink"
  if [ -r "$_csv2" ]; then
    if grep -qF '/links/link.txt' "$_csv2"; then
      _assert_fail "symlink path present in manifest"
    else _assert_pass; fi
  fi
  teardown_sandbox
}
