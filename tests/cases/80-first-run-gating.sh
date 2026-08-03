#!/bin/bash
# 80 — First-run gating
#
# A fresh install has no scan paths until someone configures them. Three
# behaviours failed before v1.4.2, and they compound:
#
#   1. The welcome screen claimed "Your configuration is complete" and
#      offered to start hashing, regardless of whether paths.txt held
#      anything.
#   2. Accepting that offer launched a run with zero roots. It discovered
#      nothing and wrote a header-only CSV, with no warning at any point.
#   3. That empty CSV then counted as "a manifest", so the welcome screen
#      disappeared permanently and the user landed in the full workflow
#      menu — being advised to run duplicate analysis over zero rows, with
#      no route back.
#
# The third is the one that makes the others unrecoverable, so all three
# are asserted here.

case_description="First-run gating: unconfigured installs cannot start an empty run"

# The launcher stops at the guided-setup wizard on a genuinely fresh tree
# (sentinel: local/.setup-complete). These cases are about the first-run
# SCREEN that follows it, so the sentinel is planted to skip the wizard.
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

run_case() {
  # ── No scan paths: ask for configuration, don't offer to hash ─────────
  make_sandbox firstrun-unconfigured || return 1
  _skip_guided_setup
  : > "$SANDBOX/local/paths.txt"

  _launcher_screen q

  assert_out_contains "No scan paths are configured yet" "unconfigured notice"
  assert_out_contains "Settings & preferences" "points at settings"
  # The offer to hash must be absent — it cannot succeed.
  assert_out_not_contains "Initiate first Hasher run" "hash offer withheld"
  assert_out_not_contains "configuration is complete" "no false completeness claim"
  teardown_sandbox

  # ── Typing 1 regardless must be refused ───────────────────────────────
  # The option isn't listed, but nothing stops the user pressing it.
  make_sandbox firstrun-force-one || return 1
  _skip_guided_setup
  : > "$SANDBOX/local/paths.txt"

  _launcher_screen 1 "" q

  assert_out_contains "No scan paths configured" "refusal message"
  assert_out_not_contains "Hasher launched" "no run launched"
  # Nothing may have been written to hashes/.
  local _n
  _n=$(ls -1 "$SANDBOX"/hashes/*.csv 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$_n" "0" "manifests created"
  teardown_sandbox

  # ── Header-only CSV is not a manifest ─────────────────────────────────
  # Guards the trap door: if this regresses, an install that produced one
  # empty run can never show the welcome screen again.
  make_sandbox firstrun-empty-csv || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"
  printf 'sample\n' > "$FIXTURES/data/one.txt"
  set_paths "$FIXTURES/data"
  printf 'path,size_bytes,mtime_epoch,algo,hash\n' \
    > "$SANDBOX/hashes/hasher-2026-01-01-000000-1.csv"

  _launcher_screen q

  assert_out_contains "ready for its first run" "welcome screen retained"
  assert_out_not_contains "Stage 1 — Hash" "workflow menu withheld"
  teardown_sandbox

  # ── One data row makes it a real manifest ─────────────────────────────
  # The counterpart: the check must not be so strict it rejects genuine
  # single-file manifests.
  make_sandbox firstrun-real-csv || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"
  printf 'sample\n' > "$FIXTURES/data/one.txt"
  set_paths "$FIXTURES/data"
  {
    printf 'path,size_bytes,mtime_epoch,algo,hash\n'
    printf '"%s/one.txt",7,1700000000,sha256,%s\n' "$FIXTURES/data" \
      "$(printf 'sample\n' | sha256sum | awk '{print $1}')"
  } > "$SANDBOX/hashes/hasher-2026-01-01-000000-2.csv"

  _launcher_screen q

  assert_out_contains "Stage 1 — Hash" "workflow menu shown"
  assert_out_not_contains "ready for its first run" "welcome screen released"
  teardown_sandbox

  # ── Configured install offers the run ─────────────────────────────────
  make_sandbox firstrun-configured || return 1
  _skip_guided_setup
  mkdir -p "$FIXTURES/data"
  fixture_files "$FIXTURES/data" 2
  set_paths "$FIXTURES/data"

  _launcher_screen q

  assert_out_contains "Initiate first Hasher run" "hash offer present"
  assert_out_contains "Scan paths configured: 1" "configured-path count"
  teardown_sandbox
}
