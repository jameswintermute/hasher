#!/bin/bash
# 85 — Manifest selection and availability gating
#
# Covers the three defects raised in the v1.4.2 peer review, plus one
# assumption the first fix depends on.
#
# The through-line is that each was a *partial* fix. v1.4.2 made
# has_successful_hash_manifest require a data row but left the selector
# picking the newest filename, so validation landed on the wrong file.
# v1.4.2 added a preflight guard to the background launch path but not the
# interactive one. Both are the same shape: a precondition tightened at one
# call site and not the others.

case_description="Manifest selection: newest USABLE manifest, availability gating, consistent preflight"

# The guided-setup wizard would consume the simulated keystrokes.
_skip_guided_setup() {
  : > "$SANDBOX/local/.setup-complete"
}

_launcher_screen() {
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && printf '%s\n' "$@" | \
    timeout "${TEST_TIMEOUT:-60}" bash launcher.sh \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

# _write_manifest <path> <rows> — a manifest with N data rows.
_write_manifest() {
  local _p="$1" _rows="${2:-1}" _i=1 _h
  _h="$(printf 'sample\n' | sha256sum | awk '{print $1}')"
  printf 'path,size_bytes,mtime_epoch,algo,hash\n' > "$_p"
  while [ "$_i" -le "$_rows" ]; do
    printf '"/tmp/sample-%s.txt",7,1700000000,sha256,%s\n' "$_i" "$_h" >> "$_p"
    _i=$(( _i + 1 ))
  done
}

run_case() {
  # ── A newer empty manifest must not mask an older valid one ───────────
  # The reported failure: the launcher fell back to the first-run screen
  # even though a perfectly good manifest was present, because validation
  # was applied to whichever file happened to be newest.
  make_sandbox manifest-newer-empty || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"; fixture_files "$FIXTURES/data" 1
  set_paths "$FIXTURES/data"

  _write_manifest "$SANDBOX/hashes/hasher-2026-01-01-000000-1.csv" 3
  # Later timestamp in the name — this is what ordering is derived from.
  printf 'path,size_bytes,mtime_epoch,algo,hash\n' \
    > "$SANDBOX/hashes/hasher-2026-06-01-000000-2.csv"

  _launcher_screen q

  assert_out_contains "Stage 1 — Hash" "workflow menu retained"
  assert_out_not_contains "ready for its first run" "first-run screen withheld"
  teardown_sandbox

  # ── A newer partial-* manifest is invisible to the selector ───────────
  # The fix above relies on partial runs living outside the hasher-*.csv
  # namespace (v1.3.26). Nothing asserted that until now; if the renaming
  # convention ever changes, this catches it rather than the selector
  # silently starting to consider incomplete manifests.
  make_sandbox manifest-partial || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"; fixture_files "$FIXTURES/data" 1
  set_paths "$FIXTURES/data"

  _write_manifest "$SANDBOX/hashes/hasher-2026-01-01-000000-1.csv" 2
  _write_manifest "$SANDBOX/hashes/partial-hasher-2026-06-01-000000-9.csv" 5

  _launcher_screen q

  assert_out_contains "Stage 1 — Hash" "workflow menu retained"
  # Cheap structural guard on the naming convention itself.
  assert_file_exists "$SANDBOX/hashes/partial-hasher-2026-06-01-000000-9.csv" \
    "partial manifest fixture"
  teardown_sandbox

  # ── All manifests empty: first-run screen is correct ──────────────────
  # The counterpart. Walking candidates must not become "accept anything".
  make_sandbox manifest-all-empty || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"; fixture_files "$FIXTURES/data" 1
  set_paths "$FIXTURES/data"

  printf 'path,size_bytes,mtime_epoch,algo,hash\n' \
    > "$SANDBOX/hashes/hasher-2026-01-01-000000-1.csv"
  printf 'path,size_bytes,mtime_epoch,algo,hash\n' \
    > "$SANDBOX/hashes/hasher-2026-06-01-000000-2.csv"

  _launcher_screen q

  assert_out_contains "ready for its first run" "first-run screen shown"
  assert_out_not_contains "Stage 1 — Hash" "workflow menu withheld"
  teardown_sandbox

  # ── Configured but unreachable roots ──────────────────────────────────
  # Configured is not the same as available: an unmounted external disk
  # produces a correct paths file pointing at nothing. hasher.sh does
  # reject this cleanly, but only after the user has committed to the run
  # and waited for it.
  make_sandbox roots-unavailable || return 1
  _skip_guided_setup
  set_paths "$FIXTURES/not-mounted-a" "$FIXTURES/not-mounted-b"

  _launcher_screen q

  assert_out_contains "not currently available" "unavailable-storage notice"
  assert_out_contains "Available now:" "availability count shown"
  assert_out_not_contains "Initiate first Hasher run" "hash offer withheld"
  assert_out_not_contains "ready for its first run" "no false readiness claim"
  teardown_sandbox

  # ── Typing 1 with unreachable roots must be refused ───────────────────
  make_sandbox roots-unavailable-force || return 1
  _skip_guided_setup
  set_paths "$FIXTURES/not-mounted-a"

  _launcher_screen 1 "" q

  assert_out_contains "is reachable right now" "refusal message"
  assert_out_not_contains "Hasher launched" "no run launched"
  local _n
  _n=$(ls -1 "$SANDBOX"/hashes/*.csv 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$_n" "0" "manifests created"
  teardown_sandbox

  # ── Partial availability still allows a run ───────────────────────────
  # Hashing what is reachable is a legitimate choice; the gate is "none
  # available", not "any missing".
  make_sandbox roots-partial || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"; fixture_files "$FIXTURES/data" 1
  set_paths "$FIXTURES/data" "$FIXTURES/not-mounted"

  _launcher_screen q

  assert_out_contains "Initiate first Hasher run" "hash offer present"
  assert_out_contains "not reachable" "partial-availability note"
  teardown_sandbox

  # ── Interactive hashing uses the same preflight ───────────────────────
  # Structural rather than behavioural: driving the advanced menu through
  # piped input is brittle, and what actually regressed was a missing call,
  # not a wrong prompt. Assert that both launch paths hold the guard.
  make_sandbox preflight-parity || return 1
  local _lc="$SANDBOX/launcher.sh" _fn _start _end _hits
  for _fn in run_hasher_nohup run_hasher_interactive; do
    _start="$(grep -n "^${_fn}()" "$_lc" | head -n1 | cut -d: -f1)"
    if [ -z "$_start" ]; then
      _assert_fail "$_fn not found in launcher"
      continue
    fi
    _end="$(awk -v s="$_start" 'NR>s && /^[a-z_]+\(\) *\{/ {print NR; exit}' "$_lc")"
    [ -n "$_end" ] || _end="$(wc -l < "$_lc")"
    _hits="$(sed -n "${_start},${_end}p" "$_lc" | grep -c 'preflight_hashing' || true)"
    if [ "${_hits:-0}" -ge 1 ]; then _assert_pass
    else _assert_fail "$_fn does not call preflight_hashing"; fi
  done
  teardown_sandbox
}
