#!/bin/bash
# 93 — Import check: v1.4.10 peer-review fixes
#
# Five findings from an external review of v1.4.9, all confirmed against
# the actual source before being fixed:
#
#   #1 dedup-internal was silently overwriting logs/duplicate-hashes-
#      latest.txt -- the SAME pointer review-duplicates.sh, auto-dedup.sh,
#      and launch-review.sh all default to reading for the NORMAL NAS
#      workflow. Fixed with --report-out/--no-publish-latest on
#      find-duplicates.sh.
#   #2 The v1.4.6-legacy migration offer in cmd_setup was unreachable: the
#      overlap check ran first and refused before the migration code a
#      few lines later could ever fire. Fixed by reordering, gated on
#      IMPORT_DIR already matching the entered folder (not just a bare
#      paths.txt line match, which would otherwise also swallow a
#      genuinely unsafe first-time configuration — a regression caught by
#      this suite's own predecessor case, ov-equal in 91, immediately
#      after the first attempt at this fix).
#   #3 import-scan-latest.csv and import-scan-latest.meta are published
#      as two separate, non-atomic symlink operations; a crash between
#      them could leave them describing different scans. Fixed by making
#      the meta file authoritative — its own import_csv= field is used
#      directly, and meta.import_dir is cross-checked against the
#      currently configured IMPORT_DIR.
#   #4 The destructive-action staleness marker was only checked by
#      dedup-internal, not discard or summary. Fixed consistently:
#      summary warns (read-only), discard refuses (destructive, matches
#      dedup-internal), sort is deliberately left alone (already tolerant
#      of missing files, no keep/delete judgement to protect).
#   #5 "Files scanned in import" undercounted by however many files hit
#      the pipe-character guard. Fixed, and along the way a related
#      double-counting bug was found and fixed: the skipped-report file
#      logs a NAS-side KEEP-CANDIDATE line alongside each import-side
#      DEL-CANDIDATE line for a cross-boundary match, so a naive line
#      count over-attributed matches to "files in import".

case_description="v1.4.10 fixes: NAS-pointer isolation, migration reachability, atomic scan pinning, consistent staleness, accurate counts"

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

run_case() {
  # ── #1: dedup-internal must never touch the NAS's global latest pointer ─
  make_sandbox nas-pointer-isolation || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'nas-internal-dup\n' > "$FIXTURES/nas/a.txt"
  printf 'nas-internal-dup\n' > "$FIXTURES/nas/b.txt"
  printf 'import-internal-dup\n' > "$FIXTURES/import/x.txt"
  printf 'import-internal-dup\n' > "$FIXTURES/import/y.txt"

  _hash_nas "$FIXTURES/nas"
  local _nas_csv
  _nas_csv="$(ls -1t "$SANDBOX"/hashes/hasher-*.csv | head -n1)"
  run_tool find-duplicates.sh --input "$_nas_csv" --mode bulk
  local _nas_pointer_before
  _nas_pointer_before="$(readlink "$SANDBOX/logs/duplicate-hashes-latest.txt" 2>/dev/null || cat "$SANDBOX/logs/duplicate-hashes-latest.txt")"

  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh dedup-internal --force
  assert_rc 0 "dedup-internal succeeds"

  local _nas_pointer_after
  _nas_pointer_after="$(readlink "$SANDBOX/logs/duplicate-hashes-latest.txt" 2>/dev/null || cat "$SANDBOX/logs/duplicate-hashes-latest.txt")"
  assert_eq "$_nas_pointer_after" "$_nas_pointer_before" "NAS's duplicate-hashes-latest.txt untouched by dedup-internal"

  # The import-internal report must exist in its OWN namespace.
  local _import_reports
  _import_reports="$(ls -1 "$SANDBOX"/logs/import-internal-duplicates-*.txt 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${_import_reports:-0}" -ge 1 ]; then _assert_pass
  else _assert_fail "no import-internal-duplicates-*.txt report was written"; fi

  # No import-side review-index should have been created (--no-review-index).
  # Excludes duplicate-review-index-latest.tsv itself, which the same bare
  # glob would otherwise also match, over-counting by one regardless of
  # whether dedup-internal leaked anything.
  local _index_count
  _index_count="$(ls -1 "$SANDBOX"/logs/duplicate-review-index-2*.tsv 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$_index_count" "1" "only the NAS run's review index exists"
  teardown_sandbox

  # ── #2: legacy migration reachable, genuine overlap still refused ──────
  make_sandbox migration-reachable || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  # Simulate a pre-v1.4.7 config: both listed in paths.txt AND already
  # recorded as import_dir in hasher.conf -- the genuine legacy signature.
  set_paths "$FIXTURES/nas" "$FIXTURES/import"
  {
    echo "[import_check]"
    echo "import_dir = $FIXTURES/import"
  } >> "$SANDBOX/local/hasher.conf"

  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  assert_rc 0 "legacy migration reaches success, not the overlap refusal"
  assert_out_contains "Removed from" "migration actually removed the entry"
  if grep -qxF "$FIXTURES/import" "$SANDBOX/local/paths.txt" 2>/dev/null; then
    _assert_fail "import folder still present in paths.txt after migration"
  else _assert_pass; fi
  if grep -qxF "$FIXTURES/nas" "$SANDBOX/local/paths.txt" 2>/dev/null; then
    _assert_pass
  else _assert_fail "trusted NAS root lost during migration"; fi
  teardown_sandbox

  # ── #2 regression guard: a genuine first-time overlap must still refuse ─
  # This is the exact case that broke when the migration fix was first
  # written: a bare "is this folder an exact paths.txt line" test cannot
  # tell a legacy migration apart from a user picking an existing NAS
  # root as their import folder for the first time.
  make_sandbox migration-does-not-bypass-safety || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/shared"
  set_paths "$FIXTURES/shared"
  # Deliberately NO prior import_dir recorded — first-time setup.

  run_tool_with_input "$FIXTURES/shared" import-check.sh setup
  assert_rc 2 "first-time setup against an existing NAS root still refuses"
  assert_out_contains "overlaps a trusted NAS scan root" "genuine overlap message shown"
  assert_out_not_contains "Removed from" "migration path did not fire"
  teardown_sandbox

  # ── #3: switched import folder is detected via meta cross-check ────────
  make_sandbox meta-folder-switch || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import-a" "$FIXTURES/import-b"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import-a/a.txt"
  printf 'z\n' > "$FIXTURES/import-b/b.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import-a" import-check.sh setup
  run_tool import-check.sh scan
  assert_rc 0 "initial scan against import-a succeeds"

  # Switch the configured import folder without a fresh scan.
  run_tool_with_input "$FIXTURES/import-b" import-check.sh setup

  run_tool import-check.sh summary
  assert_rc 3 "summary refuses when the last scan was against a different import folder"
  assert_out_contains "different import folder" "folder-mismatch message shown"
  teardown_sandbox

  # ── #4: summary warns (not refuses) on a stale scan; discard refuses ───
  make_sandbox staleness-consistency || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'match\n' > "$FIXTURES/nas/keeper.txt"
  printf 'match\n' > "$FIXTURES/import/copy.txt"
  printf 'unique\n' > "$FIXTURES/import/u.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh discard --force
  assert_rc 0 "first discard succeeds"

  # summary against the now-stale scan: warns, still shows numbers.
  run_tool import-check.sh summary
  assert_rc 0 "summary does not refuse on stale data"
  assert_out_contains "changed since this scan" "staleness warning shown"

  # discard against the now-stale scan: refuses outright.
  run_tool import-check.sh discard --force
  assert_rc 2 "second discard refuses on stale data"
  assert_out_contains "Re-scan first" "discard staleness refusal shown"
  teardown_sandbox

  # ── #5: "Files scanned" total is accurate, including pipe-skipped files ─
  make_sandbox summary-count-accuracy || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'matched\n' > "$FIXTURES/nas/keeper.txt"
  printf 'matched\n' > "$FIXTURES/import/copy.txt"
  printf 'uniq\n' > "$FIXTURES/import/u1.txt"
  printf 'shared\n' > "$FIXTURES/nas/other.txt"
  printf 'shared\n' > "$FIXTURES/import/weird|name.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh summary

  # Exactly 3 files physically exist in the import folder.
  assert_out_contains "Files scanned in import:    3" "total matches actual file count"
  assert_out_contains "Excluded (unsafe name):   1" "skipped count is per-import-file, not per-report-line"
  teardown_sandbox
}
