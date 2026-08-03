#!/bin/bash
# 20 — Snapshot integrity
#
# A manifest row must describe one consistent state of a file. If the file
# changes between the pre-hash stat and the hash completing, the row would
# otherwise carry the old size and mtime beside the new content's hash —
# describing a state that never existed. Downstream tools trust those
# fields as a unit, so an inconsistent row is worse than a missing one.
#
# The second case here is the subtle one: content replaced by a same-length
# payload with the original mtime restored. Only ctime moves. A stability
# check comparing size and mtime alone accepts the row and stores a hash
# that does not match the file on disk.

case_description="Snapshot integrity: files modified during hashing are excluded"

run_case() {
  # ── Obvious drift: size and mtime both change ─────────────────────────
  make_sandbox mutate || return 1
  fixture_files "$FIXTURES/data" 3
  set_paths "$FIXTURES/data"

  local _shim; _shim="$(shim_mutate_during_hash)"
  run_hasher_with_shim "$_shim" --pathfile local/paths.txt --jobs 1 --no-discover

  # rc=4: no hard failures, but nothing survived the stability check.
  assert_rc 4 "all-unstable run"
  assert_out_contains "unstable=3" "unstable count"
  assert_out_contains "PARTIAL SNAPSHOT" "partial-snapshot banner"

  # Unstable rows are excluded, so the manifest has no data rows. The file
  # is renamed out of the hasher-*.csv namespace so the normal
  # "newest manifest" lookup cannot pick up an incomplete snapshot.
  assert_glob_count "$SANDBOX/hashes/partial-*.csv" "1" "partial manifest created"
  assert_glob_count "$SANDBOX/hashes/hasher-*.csv" "0" "no complete manifest"
  assert_glob_count "$SANDBOX/logs/unstable-files-*.log" "1" "unstable-files log"

  # The log must be readable — the internal record-separator sentinel is
  # stripped before the file is moved into logs/.
  local _ulog
  _ulog="$(ls -1t "$SANDBOX"/logs/unstable-files-*.log 2>/dev/null | head -n1)"
  if [ -r "$_ulog" ]; then
    if grep -q $'\036' "$_ulog"; then
      _assert_fail "unstable log still contains the \\036 sentinel"
    else _assert_pass; fi
  fi
  teardown_sandbox

  # ── Subtle drift: same size, mtime restored, only ctime moves ─────────
  make_sandbox preserve || return 1
  fixture_files "$FIXTURES/data" 1
  set_paths "$FIXTURES/data"

  local _shim2; _shim2="$(shim_mutate_preserve_mtime)"
  run_hasher_with_shim "$_shim2" --pathfile local/paths.txt --jobs 1 --no-discover

  assert_rc 4 "mutate-and-restore-mtime run"
  assert_out_contains "unstable=1" "unstable count"

  # Confirm the fingerprint caught it on ctime specifically: size, mtime,
  # dev and ino should all match across the pre/post pair while ctime
  # differs. If this assertion starts failing, the stability check has
  # regressed to comparing size and mtime only.
  local _ulog2
  _ulog2="$(ls -1t "$SANDBOX"/logs/unstable-files-*.log 2>/dev/null | head -n1)"
  if [ -r "$_ulog2" ]; then
    local _line _pre _post
    _line="$(grep -v '^#' "$_ulog2" | head -n1)"
    _pre="$(printf '%s' "$_line" | awk -F'\t' '{print $2}')"
    _post="$(printf '%s' "$_line" | awk -F'\t' '{print $3}')"
    note "pre =$_pre"
    note "post=$_post"
    # Fields: size|mtime|ctime|dev|ino
    assert_eq "$(printf '%s' "$_pre"  | cut -d'|' -f1)" \
              "$(printf '%s' "$_post" | cut -d'|' -f1)" "size unchanged"
    assert_eq "$(printf '%s' "$_pre"  | cut -d'|' -f2)" \
              "$(printf '%s' "$_post" | cut -d'|' -f2)" "mtime unchanged"
    assert_eq "$(printf '%s' "$_pre"  | cut -d'|' -f5)" \
              "$(printf '%s' "$_post" | cut -d'|' -f5)" "inode unchanged"
    if [ "$(printf '%s' "$_pre" | cut -d'|' -f3)" != "$(printf '%s' "$_post" | cut -d'|' -f3)" ]; then
      _assert_pass
    else
      _assert_fail "ctime did not change — fingerprint cannot have caught this"
    fi
  fi
  teardown_sandbox
}
