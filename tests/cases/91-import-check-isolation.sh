#!/bin/bash
# 91 — Import check: overlap isolation, trust-boundary hygiene, manifest pinning
#
# v1.4.7 fixes three peer-review findings against the original Import Check
# release (v1.4.6):
#
#   #1 Import-folder overlap was not prohibited. An import_dir equal to,
#      inside, or containing a trusted NAS scan root let `discard` relocate
#      real primary NAS content whenever a backup copy happened to exist
#      elsewhere on the NAS — an entirely ordinary thing for a NAS user to
#      have. This is the most serious finding and the reason import-check's
#      "structurally guaranteed" language could not be trusted until an
#      isolation check existed independent of classify_and_plan().
#   #2 `setup` added import_dir to local/paths.txt, blurring the trust
#      boundary and — as a SEPARATE defect found while fixing this — the old
#      code truncated paths.txt unconditionally before checking whether the
#      folder was already listed, silently discarding the user's real NAS
#      roots on every setup run.
#   #3 Each of summary/discard/sort independently re-resolved "the latest
#      NAS manifest", so a full NAS hash completing between viewing the
#      summary and running discard could silently change what discard
#      compared against, with no indication anything had shifted.
#
# This case is deliberately separate from 90-import-check.sh, which covers
# the classifier's own logic (NAS precedence, boundary safety inside a
# single tree, remainder handling) and is unaffected by any of the above.

case_description="Import check: overlap refusal, paths.txt isolation, manifest pinning"

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
  # ── Overlap: import_dir EQUALS a trusted root ───────────────────────────
  make_sandbox ov-equal || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/shared"
  printf 'x\n' > "$FIXTURES/shared/f.txt"
  set_paths "$FIXTURES/shared"

  run_tool_with_input "$FIXTURES/shared" import-check.sh setup
  assert_rc 2 "setup refuses when import_dir equals a trusted root"
  assert_out_contains "overlaps a trusted NAS scan root" "overlap message shown"
  assert_out_contains "No configuration was changed" "no-op confirmed in output"
  local _conf="$SANDBOX/local/hasher.conf"
  if [ -r "$_conf" ]; then
    if grep -q 'import_dir' "$_conf" 2>/dev/null; then
      _assert_fail "import_dir was written despite the refusal"
    else _assert_pass; fi
  else
    _assert_pass  # no config file at all is equally fine — nothing was written
  fi
  teardown_sandbox

  # ── Overlap: import_dir INSIDE a trusted root ───────────────────────────
  make_sandbox ov-inside || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas/staging"
  set_paths "$FIXTURES/nas"

  run_tool_with_input "$FIXTURES/nas/staging" import-check.sh setup
  assert_rc 2 "setup refuses when import_dir is inside a trusted root"
  teardown_sandbox

  # ── Overlap: a trusted root INSIDE import_dir ───────────────────────────
  make_sandbox ov-contains || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/broad/nas-subset" "$FIXTURES/broad"
  set_paths "$FIXTURES/broad/nas-subset"

  run_tool_with_input "$FIXTURES/broad" import-check.sh setup
  assert_rc 2 "setup refuses when a trusted root is inside import_dir"
  teardown_sandbox

  # ── Overlap via symlink: canonicalisation must not be bypassable ───────
  make_sandbox ov-symlink || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/real-nas/Family"
  set_paths "$FIXTURES/real-nas"
  ln -sf "$FIXTURES/real-nas/Family" "$FIXTURES/family-link"

  run_tool_with_input "$FIXTURES/family-link" import-check.sh setup
  assert_rc 2 "setup refuses a symlink resolving inside a trusted root"
  teardown_sandbox

  # ── Non-overlapping sibling: must NOT be refused ────────────────────────
  # Guards against the isolation check being so broad it rejects legitimate
  # configurations — a sibling directory sharing a parent is fine.
  make_sandbox ov-sibling-ok || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/parent/nas" "$FIXTURES/parent/import"
  set_paths "$FIXTURES/parent/nas"

  run_tool_with_input "$FIXTURES/parent/import" import-check.sh setup
  assert_rc 0 "setup accepts a non-overlapping sibling folder"
  assert_out_contains "Import Check is set up" "setup succeeded"
  teardown_sandbox

  # ── Overlap re-checked on every subcommand, not only at setup time ─────
  # A user can hand-edit local/paths.txt after setup. scan/summary/discard/
  # sort must each catch that, not only the original setup call.
  make_sandbox ov-post-setup-edit || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  set_paths "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  assert_rc 0 "initial setup succeeds while non-overlapping"

  # Now hand-edit paths.txt to add the import folder as a "trusted root".
  printf '%s\n' "$FIXTURES/import" >> "$SANDBOX/local/paths.txt"
  run_tool import-check.sh scan
  assert_rc 2 "scan refuses after paths.txt is edited to overlap"
  teardown_sandbox

  # ── setup does not write import_dir into local/paths.txt ───────────────
  make_sandbox no-paths-write || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  set_paths "$FIXTURES/nas"

  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  if grep -qxF "$FIXTURES/import" "$SANDBOX/local/paths.txt" 2>/dev/null; then
    _assert_fail "import_dir was written into local/paths.txt"
  else _assert_pass; fi
  # The NAS root must still be there — this also covers the truncation bug.
  if grep -qxF "$FIXTURES/nas" "$SANDBOX/local/paths.txt" 2>/dev/null; then
    _assert_pass
  else
    _assert_fail "trusted NAS root was lost from local/paths.txt"
  fi
  teardown_sandbox

  # ── Regression: setup must not truncate an existing paths.txt ──────────
  # The original v1.4.6 code ran ": > paths.txt" unconditionally before
  # checking membership, discarding every trusted root on every setup run
  # — including re-running setup to change the import folder later.
  make_sandbox no-truncate || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas1" "$FIXTURES/nas2" "$FIXTURES/import"
  set_paths "$FIXTURES/nas1" "$FIXTURES/nas2"
  local _before
  _before="$(wc -l < "$SANDBOX/local/paths.txt" | tr -d ' ')"

  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  local _after
  _after="$(wc -l < "$SANDBOX/local/paths.txt" | tr -d ' ')"
  assert_eq "$_after" "$_before" "paths.txt line count unchanged by setup"
  if grep -qxF "$FIXTURES/nas1" "$SANDBOX/local/paths.txt" 2>/dev/null && \
     grep -qxF "$FIXTURES/nas2" "$SANDBOX/local/paths.txt" 2>/dev/null; then
    _assert_pass
  else
    _assert_fail "one or both trusted roots were lost — truncation regression"
  fi
  teardown_sandbox

  # ── Manifest pinning: sidecar records the NAS manifest used at scan time ─
  make_sandbox pin-sidecar || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import/g.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  assert_file_exists "$SANDBOX/hashes/import-scan-latest.meta" "pinning sidecar written"
  if [ -r "$SANDBOX/hashes/import-scan-latest.meta" ]; then
    if grep -qxF 'marker=HASHER_IMPORT_SCAN_V1' "$SANDBOX/hashes/import-scan-latest.meta"; then
      _assert_pass
    else _assert_fail "sidecar missing its provenance marker"; fi
  fi
  teardown_sandbox

  # ── Manifest pinning: a later NAS hash does not silently change the result ─
  # The exact sequence from the review: scan against manifest A, then a
  # fresh NAS hash creates manifest B, then discard. Discard must still
  # compare against A (what the user's summary was based on), not B.
  make_sandbox pin-stable || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'shared\n' > "$FIXTURES/nas/a.txt"
  printf 'shared\n' > "$FIXTURES/import/copy.txt"
  _hash_nas "$FIXTURES/nas"                      # manifest A
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan                  # pinned to A

  local _pinned_before
  _pinned_before="$(ls -1t "$SANDBOX"/hashes/hasher-*.csv | head -n1)"

  # A second, unrelated full NAS hash — manifest B.
  mkdir -p "$FIXTURES/nas2"
  printf 'unrelated\n' > "$FIXTURES/nas2/b.txt"
  sleep 1
  _hash_nas "$FIXTURES/nas2"                     # manifest B, now the newest

  run_tool import-check.sh summary
  assert_out_contains "A newer NAS inventory is available" "staleness notice shown"
  assert_out_contains "Already on your NAS:      1" "still matches against pinned manifest A"
  teardown_sandbox

  # ── unique-files/ is excluded from future scans ─────────────────────────
  make_sandbox exclude-unique || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup

  mkdir -p "$FIXTURES/import/unique-files"
  printf 'already-sorted\n' > "$FIXTURES/import/unique-files/old.txt"
  printf 'new-arrival\n' > "$FIXTURES/import/fresh.txt"

  run_tool import-check.sh scan
  local _icsv
  _icsv="$(ls -1t "$SANDBOX"/hashes/import-scan-*.csv 2>/dev/null | grep -v latest | head -n1)"
  if [ -r "$_icsv" ]; then
    if grep -q 'unique-files' "$_icsv"; then
      _assert_fail "unique-files/ contents were rehashed by a later scan"
    else _assert_pass; fi
  fi
  teardown_sandbox

  # ── Discard wording says quarantine, not permanent removal ─────────────
  make_sandbox wording || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'shared\n' > "$FIXTURES/nas/a.txt"
  printf 'shared\n' > "$FIXTURES/import/copy.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh discard --force

  assert_out_contains "moved to quarantine (not deleted)" "quarantine language used"
  teardown_sandbox

  # ── Lock: a stale lock refuses a second operation ───────────────────────
  make_sandbox lock-contention || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup

  mkdir -p "$SANDBOX/var/import-check.lock"
  run_tool import-check.sh scan
  assert_rc 2 "scan refuses while the lock directory exists"
  assert_out_contains "Another import-check operation" "contention message shown"
  rmdir "$SANDBOX/var/import-check.lock" 2>/dev/null || true
  teardown_sandbox

  # ── Lock: released automatically after a normal run ──────────────────────
  make_sandbox lock-release || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'y\n' > "$FIXTURES/import/g.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  assert_file_missing "$SANDBOX/var/import-check.lock" "lock released after scan completes"
  teardown_sandbox

  # ── Lock: released even on an early exit path (empty import → rc=4) ────
  make_sandbox lock-release-early || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  assert_rc 4 "empty import folder"
  assert_file_missing "$SANDBOX/var/import-check.lock" "lock released even on early exit"
  teardown_sandbox

  # ── Pipe character in a filename: match skipped, plan stays parseable ──
  # The KEEP|path|hash / DEL|path|hash format has no escaping. A legal
  # filename containing "|" would otherwise corrupt field parsing rather
  # than fail loudly. Import Check processes uncontrolled external media,
  # so this is more likely to be hit here than elsewhere in the tool.
  make_sandbox pipe-char || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'shared\n' > "$FIXTURES/nas/normal.txt"
  printf 'shared\n' > "$FIXTURES/import/weird|name.txt"
  printf 'unrelated\n' > "$FIXTURES/import/normal2.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  run_tool import-check.sh discard --force
  assert_out_contains "excluded from this plan" "pipe-character exclusion warned"
  # The pipe-named file must survive untouched — not quarantined on a
  # corrupted understanding of the plan.
  assert_file_exists "$FIXTURES/import/weird|name.txt" "pipe-named file left alone"
  # A genuinely unrelated file must be unaffected by the other file's name.
  assert_file_exists "$FIXTURES/import/normal2.txt" "unrelated file untouched"
  teardown_sandbox
}
