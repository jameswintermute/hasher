#!/bin/bash
# 40 — Duplicate-discovery safety
#
# Three ways discovery can propose an action that is wrong rather than
# merely unhelpful:
#
#   Hard links      — moving one name for an inode reclaims nothing, since
#                     the other names keep the data alive. If quarantine is
#                     on another filesystem the mv becomes a copy and usage
#                     goes UP. The reported saving is fiction.
#   Folder symlinks — folder signatures compare regular files only. A folder
#                     holding a unique symlink looks identical to one that
#                     does not, so quarantining it silently discards the
#                     symlink.
#   Provenance      — hasher.sh writes a quick post-scan duplicate summary
#                     that has not been hard-link filtered. Consumers must
#                     refuse it and use only verified finder output.

case_description="Dedup safety: hard links, folder symlinks, report provenance"

run_case() {
  # ── Hard links excluded from reclaim ──────────────────────────────────
  make_sandbox hardlink || return 1
  fixture_hardlinks "$FIXTURES/data"
  set_paths "$FIXTURES/data"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  assert_rc 0 "hash run over hard links"
  local _csv; _csv="$(latest_csv)"
  # All four names are real directory entries and all get hashed.
  assert_eq "$(csv_rows "$_csv")" "4" "all names hashed"

  run_tool find-duplicates.sh --input "$_csv"
  assert_rc 0 "duplicate discovery over hard links"
  assert_out_contains "hard links" "hard-link exclusion notice"
  assert_glob_count "$SANDBOX/logs/hardlinks-excluded-*.log" "1" "hard-link log"

  # 3 names share one inode → 2 are dropped, leaving one representative
  # plus the genuine independent copy.
  local _hl
  _hl="$(ls -1t "$SANDBOX"/logs/hardlinks-excluded-*.log 2>/dev/null | head -n1)"
  if [ -r "$_hl" ]; then
    assert_eq "$(grep -c '^HARDLINK' "$_hl" | tr -d ' ')" "2" "hard links excluded"
  fi

  local _dupcsv
  _dupcsv="$(ls -1t "$SANDBOX"/logs/duplicates-*.csv 2>/dev/null | head -n1)"
  if [ -r "$_dupcsv" ]; then
    assert_eq "$(wc -l < "$_dupcsv" | tr -d ' ')" "2" "candidates after collapse"
  fi

  # And the generated plan must not offer to quarantine a hard link.
  run_tool find-duplicates.sh --input "$_csv" --mode bulk
  local _plan
  _plan="$(ls -1t "$SANDBOX"/logs/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"
  if [ -r "$_plan" ]; then
    if grep -qE '^DEL\|.*/link-[12]\.txt' "$_plan"; then
      _assert_fail "plan proposes deleting a hard link (reclaims nothing)"
    else _assert_pass; fi
  fi
  teardown_sandbox

  # ── Folders containing non-regular entries are excluded ───────────────
  make_sandbox foldersym || return 1
  fixture_twin_folders_one_symlink "$FIXTURES"
  set_paths "$FIXTURES/twin-a" "$FIXTURES/twin-b"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv2; _csv2="$(latest_csv)"
  # The symlink is skipped by `find -type f`, so both folders look identical
  # from the manifest alone. This is exactly the trap.
  assert_eq "$(csv_rows "$_csv2")" "2" "regular files only in manifest"

  run_tool find-duplicate-folders.sh --input "$_csv2"
  assert_out_contains "non-regular entries" "non-regular exclusion notice"
  assert_glob_count "$SANDBOX/logs/duplicate-folders-excluded-*.log" "1" "exclusion log"

  # The offending path must be named so the operator can judge for themselves.
  local _ex
  _ex="$(ls -1t "$SANDBOX"/logs/duplicate-folders-excluded-*.log 2>/dev/null | head -n1)"
  if [ -r "$_ex" ]; then
    if grep -qF 'unique-link' "$_ex"; then _assert_pass
    else _assert_fail "exclusion log does not name the offending symlink"; fi
  fi
  teardown_sandbox

  # ── Report provenance ─────────────────────────────────────────────────
  make_sandbox provenance || return 1
  fixture_duplicate_pair "$FIXTURES/data"
  set_paths "$FIXTURES/data"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  local _csv3; _csv3="$(latest_csv)"
  run_tool find-duplicates.sh --input "$_csv3"

  local _canon
  _canon="$(ls -1t "$SANDBOX"/logs/duplicate-hashes-*.txt 2>/dev/null | grep -v latest | head -n1)"
  if [ -r "$_canon" ]; then
    if grep -qxF '# HASHER_VERIFIED_DUPLICATE_REPORT v1' "$_canon"; then _assert_pass
    else _assert_fail "verified report is missing its provenance header"; fi
  fi

  # A report without the marker must be refused by the consumers, even
  # though its body would parse perfectly well.
  printf 'HASH abc123\n  /tmp/one.txt\n  /tmp/two.txt\n' > "$FIXTURES/unverified.txt"
  run_tool review-duplicates.sh --from-report "$FIXTURES/unverified.txt"
  if [ "$RUN_RC" = "0" ]; then
    _assert_fail "review-duplicates accepted a report with no provenance header"
  else _assert_pass; fi

  teardown_sandbox
}
