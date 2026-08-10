#!/bin/bash
# 92 — Import check: internal deduplication (dedup-internal)
#
# Two files inside the import folder that duplicate EACH OTHER, not the
# NAS, were deliberately left unautomated through v1.4.7 — "which of my
# own two copies do I keep" has no safe default the way "does the NAS
# already have this" does. v1.4.9 adds an explicit, opt-in action for it,
# reusing find-duplicates.sh + auto-dedup.sh + delete-duplicates.sh exactly
# as they already exist, with the same plan-review-then-confirm workflow
# used everywhere else in this tool.
#
# The two things worth protecting here: (1) it must never look at anything
# outside the import folder — structurally guaranteed by import-scan-
# latest.csv never containing a NAS path in the first place, not by a
# runtime check — and (2) it must refuse to run against data a prior
# discard/dedup-internal action has made stale.

case_description="Import check: dedup-internal keeps shortest path, refuses stale data, never touches the NAS"

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
  # ── Basic case: keeps shortest path, leaves NAS-matching group alone ───
  make_sandbox dedup-basic || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import/sub"
  printf 'nas-match\n' > "$FIXTURES/nas/keeper.jpg"
  printf 'nas-match\n' > "$FIXTURES/import/copy-of-nas.jpg"
  printf 'internal-dup\n' > "$FIXTURES/import/a.txt"
  printf 'internal-dup\n' > "$FIXTURES/import/sub/longer-path-b.txt"
  printf 'truly-unique\n' > "$FIXTURES/import/only-one.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  run_tool import-check.sh discard --force
  assert_rc 0 "discard removes the NAS-matching copy"
  assert_file_missing "$FIXTURES/import/copy-of-nas.jpg" "NAS-matching copy quarantined"

  # dedup-internal must refuse until a fresh scan exists.
  run_tool import-check.sh dedup-internal --force
  assert_rc 2 "dedup-internal refuses stale data right after discard"
  assert_out_contains "Re-scan first" "staleness message shown"
  assert_file_exists "$FIXTURES/import/a.txt" "nothing touched by the refused run"
  assert_file_exists "$FIXTURES/import/sub/longer-path-b.txt" "nothing touched by the refused run"

  run_tool import-check.sh scan
  run_tool import-check.sh dedup-internal --force
  assert_rc 0 "dedup-internal succeeds after a fresh scan"

  assert_file_exists "$FIXTURES/import/a.txt" "shorter-path copy kept"
  assert_file_missing "$FIXTURES/import/sub/longer-path-b.txt" "longer-path copy quarantined"
  assert_file_exists "$FIXTURES/import/only-one.txt" "unrelated unique file untouched"

  # Exactly two files should have ever been quarantined across both
  # actions: the NAS match and the longer-path internal duplicate.
  local _qn
  _qn="$(find "$SANDBOX"/quarantine-*/ -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$_qn" "2" "exactly two files quarantined in total"
  teardown_sandbox

  # ── No internal duplicates: clean rc=4, nothing touched ─────────────────
  make_sandbox dedup-none || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  printf 'a\n' > "$FIXTURES/import/one.txt"
  printf 'b\n' > "$FIXTURES/import/two.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan
  run_tool import-check.sh dedup-internal --force

  assert_rc 4 "no internal duplicates reports rc=4, not an error"
  assert_file_exists "$FIXTURES/import/one.txt" "no files touched"
  assert_file_exists "$FIXTURES/import/two.txt" "no files touched"
  teardown_sandbox

  # ── No scan at all: refused with guidance, not a crash ──────────────────
  make_sandbox dedup-no-scan || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'x\n' > "$FIXTURES/nas/f.txt"
  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup

  run_tool import-check.sh dedup-internal --force
  assert_rc 3 "dedup-internal with no scan yet"
  assert_out_contains "No import scan found" "clear guidance"
  teardown_sandbox

  # ── Structural isolation: an internal-dup plan can never reference the NAS ─
  # import-scan-latest.csv only ever contains import-side paths, so this is
  # true by construction rather than by a runtime check — verified here by
  # confirming the generated plan file contains no NAS-side path at all.
  make_sandbox dedup-isolation || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'nas-only-content\n' > "$FIXTURES/nas/solo.txt"
  printf 'import-dup-content\n' > "$FIXTURES/import/x.txt"
  printf 'import-dup-content\n' > "$FIXTURES/import/y.txt"

  _hash_nas "$FIXTURES/nas"
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  run_tool import-check.sh scan

  # Force-confirm mode still writes the plan before applying; capture it.
  run_tool import-check.sh dedup-internal --force
  assert_rc 0 "dedup-internal applies the internal-only duplicate group"

  local _plan
  _plan="$(ls -1t "$SANDBOX"/logs/import-internal-dedup-plan-*.txt 2>/dev/null | head -n1)"
  if [ -r "$_plan" ]; then
    if grep -qF "$FIXTURES/nas/" "$_plan"; then
      _assert_fail "generated plan references a NAS path"
    else _assert_pass; fi
  else
    _assert_fail "no plan file found to inspect"
  fi
  assert_file_exists "$FIXTURES/nas/solo.txt" "NAS file was never a candidate"
  teardown_sandbox
}
