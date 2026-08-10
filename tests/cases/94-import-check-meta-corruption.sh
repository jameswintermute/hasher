#!/bin/bash
# 94 — Import check: corrupt scan metadata is refused, not silently ignored
#
# External review of v1.4.10 found that load_verified_import_scan()'s
# single condition -- "meta unreadable OR marker missing" -- treated two
# different situations identically:
#
#   meta file genuinely does not exist   -> legitimate pre-v1.4.7 upgrade
#                                            continuity, safe to fall back
#   meta file EXISTS but fails validation -> corruption (crash mid-write,
#                                            since the meta is written as
#                                            several printf calls inside
#                                            one redirect rather than one
#                                            atomic write; or direct user
#                                            editing, plausible on a NAS)
#
# Both fell through to the SAME legacy fallback: an unpinned
# import-scan-latest.csv plus an independently-resolved
# latest_nas_manifest(), completely bypassing the pinning guarantee this
# function exists to provide. That is a full, silent reversion to the
# exact provenance problem v1.4.7/v1.4.10 fixed -- not a smaller version
# of it. Fixed by splitting the two conditions: only a genuinely absent
# meta file falls back; a present-but-invalid one is refused outright.

case_description="Import check: a corrupt or invalid meta sidecar is refused, never silently bypassed"

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
  # ── Baseline: a genuinely absent meta still falls back (unchanged) ─────
  # This is the ONE case that must still succeed via the legacy path --
  # guards against the fix becoming too strict and breaking upgrade
  # continuity for installs whose scans predate v1.4.7.
  make_sandbox meta-absent || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'match\n' > "$FIXTURES/nas/keeper.txt"
  printf 'match\n' > "$FIXTURES/import/copy.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  assert_rc 0 "scan succeeds"

  # Simulate a pre-v1.4.7 install: no meta sidecar was ever written.
  rm -f "$SANDBOX/hashes/import-scan-latest.meta"

  run_tool import-check.sh summary
  assert_rc 0 "summary succeeds via legacy fallback when meta is genuinely absent"
  assert_out_contains "Already on your NAS:      1" "legacy fallback still classifies correctly"
  teardown_sandbox

  # ── Corrupt meta: truncated/garbage content must be REFUSED ────────────
  make_sandbox meta-corrupt-garbage || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'match\n' > "$FIXTURES/nas/keeper.txt"
  printf 'match\n' > "$FIXTURES/import/copy.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  # Simulate a crash mid-write or a user directly editing the file.
  printf 'this-is-not-a-valid-meta-file\n' > "$SANDBOX/hashes/import-scan-latest.meta"

  run_tool import-check.sh summary
  assert_rc 3 "summary refuses on a corrupt meta file rather than silently falling back"
  assert_out_contains "invalid, unreadable, or incomplete" "corruption message shown"
  assert_out_not_contains "Already on your NAS" "no classification attempted on unverified data"
  teardown_sandbox

  # ── Corrupt meta: present but marker line specifically missing ─────────
  # Distinct from total garbage -- a meta file that has SOME of the right
  # shape (other fields present) but not the marker line must still be
  # refused, not partially trusted.
  make_sandbox meta-corrupt-no-marker || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'match\n' > "$FIXTURES/nas/keeper.txt"
  printf 'match\n' > "$FIXTURES/import/copy.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  local _real_meta
  _real_meta="$(readlink "$SANDBOX/hashes/import-scan-latest.meta" 2>/dev/null)"
  [ -n "$_real_meta" ] || _real_meta="import-scan-latest.meta"
  # Rewrite without the marker line -- e.g. a truncated write that got as
  # far as the other fields but not the first line, or the first line
  # specifically corrupted.
  {
    printf 'import_csv=/tmp/somewhere.csv\n'
    printf 'nas_csv=/tmp/somewhere-else.csv\n'
  } > "$SANDBOX/hashes/import-scan-latest.meta"

  run_tool import-check.sh discard --force
  assert_rc 3 "discard refuses when the marker line specifically is missing"
  assert_out_contains "invalid, unreadable, or incomplete" "corruption message shown for discard too"
  teardown_sandbox

  # ── Empty meta file (zero bytes) ────────────────────────────────────────
  make_sandbox meta-corrupt-empty || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import/g.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  : > "$SANDBOX/hashes/import-scan-latest.meta"

  run_tool import-check.sh summary
  assert_rc 3 "summary refuses on a zero-byte meta file"
  teardown_sandbox

  # ── Valid meta still works normally (no false positives from the fix) ──
  make_sandbox meta-valid-unaffected || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'match\n' > "$FIXTURES/nas/keeper.txt"
  printf 'match\n' > "$FIXTURES/import/copy.txt"
  printf 'unique\n' > "$FIXTURES/import/u.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh summary
  assert_rc 0 "unmodified, valid meta still works"
  assert_out_contains "Already on your NAS:      1" "correct classification with valid meta"
  assert_out_contains "Remaining (hand-sort):    1" "correct classification with valid meta"

  run_tool import-check.sh discard --force
  assert_rc 0 "discard still works normally with a valid meta"
  teardown_sandbox
}
