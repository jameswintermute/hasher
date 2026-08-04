#!/bin/bash
# 90 — Import check: NAS-precedence duplicate classification
#
# Import Check lets a user stage files from an SD card, old backup disk, or
# similar into a folder, then find out which are already on the NAS. The
# one rule that must never break: the NAS side of a match is never a
# delete candidate, structurally, not just by default. These cases exist
# to keep that rule honest as the classifier evolves.

case_description="Import check: NAS always wins, remainder handling, boundary safety"

# import-check.sh writes only to local/hasher.conf's [import_check] section.
# Since v1.4.7 it does NOT touch local/paths.txt — the import folder is
# deliberately kept out of the trusted NAS inventory (peer review #2).

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
  # ── Cross-boundary match: NAS copy is kept, import copy is quarantined ──
  make_sandbox ic-basic || return 1
  mkdir -p "$FIXTURES/nas/Photos" "$FIXTURES/import/DCIM"
  printf 'sunset-content\n' > "$FIXTURES/nas/Photos/IMG_0421.JPG"
  printf 'sunset-content\n' > "$FIXTURES/import/DCIM/IMG_0421.JPG"
  printf 'unique-content\n'  > "$FIXTURES/import/newfile.txt"

  _hash_nas "$FIXTURES/nas"
  assert_rc 0 "NAS hash"

  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  assert_rc 0 "import-check setup"
  assert_out_contains "Import Check is set up" "setup confirmation"

  run_tool import-check.sh scan
  assert_rc 0 "import scan"

  run_tool import-check.sh summary
  assert_out_contains "Already on your NAS:      1" "one NAS duplicate found"
  assert_out_contains "Remaining (hand-sort):    1" "one remainder file"

  run_tool import-check.sh discard --force
  assert_rc 0 "discard"
  assert_out_contains "0 file(s) on your NAS will be touched" "NAS-safety statement shown"

  assert_file_exists "$FIXTURES/nas/Photos/IMG_0421.JPG" "NAS copy survives"
  assert_file_missing "$FIXTURES/import/DCIM/IMG_0421.JPG" "import copy quarantined"
  assert_file_exists "$FIXTURES/import/newfile.txt" "unmatched file untouched by discard"

  local _qn
  _qn="$(find "$SANDBOX"/quarantine-*/ -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$_qn" "1" "exactly one file quarantined"
  teardown_sandbox

  # ── Remainder move: unique-files/, top level cleared ────────────────────
  make_sandbox ic-sort || return 1
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'nas-only\n' > "$FIXTURES/nas/keep.txt"
  printf 'never-seen-before\n' > "$FIXTURES/import/orphan.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh sort --force

  assert_rc 0 "sort"
  assert_file_exists "$FIXTURES/import/unique-files/orphan.txt" "remainder moved into unique-files/"
  assert_file_missing "$FIXTURES/import/orphan.txt" "original location cleared"
  teardown_sandbox

  # ── Boundary safety: a sibling folder with a shared name prefix ─────────
  # /tmp/x/import and /tmp/x/import-archive must never be confused. Without
  # a trailing-slash boundary check, "starts with $IMPORT_DIR" would
  # false-match the second against the first.
  make_sandbox ic-boundary || return 1
  mkdir -p "$FIXTURES/nas/import-archive" "$FIXTURES/import"
  printf 'archived-content\n' > "$FIXTURES/nas/import-archive/decoy.txt"
  printf 'archived-content\n' > "$FIXTURES/import/copy.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh summary
  assert_out_contains "Already on your NAS:      1" "matched despite prefix-sharing sibling"

  run_tool import-check.sh discard --force
  assert_file_exists "$FIXTURES/nas/import-archive/decoy.txt" \
    "sibling NAS folder untouched despite name collision"
  teardown_sandbox

  # ── Import-internal duplicates are left alone, not auto-resolved ────────
  # Two files inside import matching EACH OTHER but not the NAS: neither
  # should be discarded. This is deliberately out of scope — see the
  # design note at the top of import-check.sh.
  make_sandbox ic-internal || return 1
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'nas-file\n' > "$FIXTURES/nas/x.txt"
  printf 'internal-dup\n' > "$FIXTURES/import/a.txt"
  printf 'internal-dup\n' > "$FIXTURES/import/b.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh summary
  assert_out_contains "Already on your NAS:      0" "no cross-boundary match"
  assert_out_contains "Remaining (hand-sort):    2" "both internal dupes left for hand-sorting"

  run_tool import-check.sh discard --force
  assert_rc 4 "discard with nothing to discard reports rc=4, not an error"
  assert_file_exists "$FIXTURES/import/a.txt" "import-internal dup a untouched"
  assert_file_exists "$FIXTURES/import/b.txt" "import-internal dup b untouched"
  teardown_sandbox

  # ── No NAS manifest yet: scan refuses with guidance, not a crash ────────
  make_sandbox ic-no-manifest || return 1
  mkdir -p "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/import/f.txt"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  assert_rc 3 "scan with no NAS manifest"
  assert_out_contains "No complete NAS manifest found" "clear guidance"
  teardown_sandbox

  # ── Empty import folder: scan reports rc=4, not an error ────────────────
  make_sandbox ic-empty || return 1
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  assert_rc 4 "scan of an empty import folder"
  teardown_sandbox

  # ── NAS-side rows under IMPORT_DIR are never treated as NAS ─────────────
  # If a full NAS hash was ever run while paths.txt still included the
  # import folder, rows from inside it could end up in the NAS manifest.
  # classify_and_plan must exclude those from nas_path[] regardless.
  make_sandbox ic-self-reference || return 1
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'real-nas-file\n' > "$FIXTURES/nas/keep.txt"
  printf 'shared-payload\n' > "$FIXTURES/import/stale.txt"
  # Simulate a NAS manifest that (incorrectly) also hashed the import dir.
  _hash_nas "$FIXTURES/nas"
  local _csv
  _csv="$(ls -1t "$SANDBOX"/hashes/hasher-*.csv | head -n1)"
  local _h
  _h="$(printf 'shared-payload\n' | sha256sum | awk '{print $1}')"
  printf '"%s/self-ref.txt",15,1700000000,sha256,%s\n' "$FIXTURES/import" "$_h" >> "$_csv"

  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  printf 'shared-payload\n' > "$FIXTURES/import/copy2.txt"
  run_tool import-check.sh scan
  run_tool import-check.sh summary
  # The injected self-referencing row must not have been used as a keeper;
  # since it is the ONLY "NAS-side" candidate for that hash, the group must
  # fall through to the remainder rather than emit a same-folder KEEP/DEL.
  assert_out_contains "Remaining (hand-sort):    2" "self-referencing NAS row excluded from matching"
  teardown_sandbox
}
