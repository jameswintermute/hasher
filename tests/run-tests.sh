#!/bin/bash
# Hasher fault-injection test suite
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3
#
# Why this exists
# ---------------
# Hasher's regressions have almost all been in one class: adversarial or
# merely unusual input, not the code path under active development. A run
# over a flat directory of ordinary files exercises none of the situations
# that actually broke — overlapping scan roots, hard links, symlinks inside
# an otherwise-identical folder, a file rewritten mid-hash, a truncated
# manifest, a lock left behind by a killed parent.
#
# Each case here reproduces a real defect found in review. Deliberately, the
# assertions describe the *behaviour* rather than the implementation, so a
# rewrite that preserves the guarantee still passes.
#
# Usage
# -----
#   tests/run-tests.sh                # run everything
#   tests/run-tests.sh 20 40          # run cases whose number matches
#   tests/run-tests.sh --list         # list cases without running them
#   tests/run-tests.sh --verbose      # include per-case notes
#   tests/run-tests.sh --keep         # leave sandboxes behind for inspection
#
# Exit codes
#   0  all cases passed
#   1  one or more cases failed
#   2  usage error, or the suite could not start
#
# Safety
#   Every case runs in a private sandbox under a temp directory. Nothing is
#   written to the install tree, and no path outside the sandbox is touched.
#   Fault injection is done with PATH shims, never by modifying system tools.

set -u

TESTS_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
HASHER_ROOT="$(cd -- "$TESTS_DIR/.." && pwd -P)"
export HASHER_ROOT

TEST_VERBOSE=0
TEST_KEEP=0
export TEST_KEEP
TEST_LIST=0
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"
export TEST_TIMEOUT
FILTERS=""

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) TEST_VERBOSE=1 ;;
    -k|--keep)    TEST_KEEP=1 ;;
    -l|--list)    TEST_LIST=1 ;;
    -t|--timeout) shift; TEST_TIMEOUT="${1:-60}"; export TEST_TIMEOUT ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)  FILTERS="$FILTERS $1" ;;
  esac
  shift
done
export TEST_VERBOSE TEST_KEEP

# shellcheck source=lib/harness.sh
. "$TESTS_DIR/lib/harness.sh" || { echo "Cannot load harness" >&2; exit 2; }

# ── Preconditions ───────────────────────────────────────────────────────────
for _req in bin/hasher.sh bin/find-duplicates.sh bin/find-duplicate-folders.sh; do
  if [ ! -r "$HASHER_ROOT/$_req" ]; then
    printf '%sCannot find %s under %s%s\n' "$T_RED" "$_req" "$HASHER_ROOT" "$T_RST" >&2
    printf 'Run this script from within a Hasher installation.\n' >&2
    exit 2
  fi
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  printf '%sNeither sha256sum nor shasum is available.%s\n' "$T_RED" "$T_RST" >&2
  exit 2
fi

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hasher-tests.XXXXXX")" || exit 2
export TEST_TMP

cleanup_suite() {
  # Belt and braces: kill anything still running out of the temp tree before
  # removing it, so a hung case cannot leave workers behind.
  local _pids
  _pids="$(ps -eo pid=,args= 2>/dev/null | grep -F "$TEST_TMP" | grep -v grep | awk '{print $1}' || true)"
  [ -n "$_pids" ] && { kill -KILL $_pids 2>/dev/null || true; }
  if [ "$TEST_KEEP" = "1" ]; then
    printf '\nSandboxes retained: %s\n' "$TEST_TMP"
  else
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}
trap cleanup_suite EXIT INT TERM

# ── Case discovery ──────────────────────────────────────────────────────────
CASES=""
for _f in "$TESTS_DIR"/cases/*.sh; do
  [ -r "$_f" ] || continue
  if [ -n "$(printf '%s' "$FILTERS" | tr -d ' ')" ]; then
    _match=0
    for _flt in $FILTERS; do
      case "$(basename "$_f")" in *"$_flt"*) _match=1 ;; esac
    done
    [ "$_match" = "1" ] || continue
  fi
  CASES="$CASES $_f"
done

if [ -z "$(printf '%s' "$CASES" | tr -d ' ')" ]; then
  printf '%sNo cases matched.%s\n' "$T_YEL" "$T_RST" >&2
  exit 2
fi

if [ "$TEST_LIST" = "1" ]; then
  printf '%sAvailable cases%s\n\n' "$T_BOLD" "$T_RST"
  for _f in $CASES; do
    case_description=""
    # shellcheck disable=SC1090
    . "$_f" 2>/dev/null
    printf '  %-28s %s\n' "$(basename "$_f" .sh)" "${case_description:-(no description)}"
  done
  exit 0
fi

# ── Run ─────────────────────────────────────────────────────────────────────
printf '%sHasher fault-injection suite%s\n' "$T_BOLD" "$T_RST"
printf '  install:  %s\n' "$HASHER_ROOT"
printf '  sandbox:  %s\n' "$TEST_TMP"
printf '  timeout:  %ss per invocation\n' "$TEST_TIMEOUT"
printf '\n'

SUITE_PASS=0
SUITE_FAIL=0
SUITE_ASSERTS=0
FAILED_NAMES=""
_start_ts=$(date +%s)

for _f in $CASES; do
  CASE_NAME="$(basename "$_f" .sh)"
  CASE_FAILURES=0
  CASE_ASSERTIONS=0
  CASE_MESSAGES=""
  case_description=""

  # shellcheck disable=SC1090
  . "$_f" || {
    printf '  %s✗%s %-26s could not be loaded\n' "$T_RED" "$T_RST" "$CASE_NAME"
    SUITE_FAIL=$(( SUITE_FAIL + 1 ))
    FAILED_NAMES="$FAILED_NAMES $CASE_NAME"
    continue
  }

  printf '  %s…%s %-26s %s\n' "$T_BLU" "$T_RST" "$CASE_NAME" "${case_description:-}"

  _case_start=$(date +%s)
  if ! run_case; then
    # A case returning non-zero without recording an assertion failure
    # means it aborted early (usually a sandbox that could not be built).
    [ "$CASE_FAILURES" -eq 0 ] && _assert_fail "case aborted before completing"
  fi
  _case_end=$(date +%s)
  # Sandboxes are normally torn down inside the case; this catches an early
  # return that skipped the teardown.
  [ "$TEST_KEEP" = "1" ] || teardown_sandbox

  SUITE_ASSERTS=$(( SUITE_ASSERTS + CASE_ASSERTIONS ))
  if [ "$CASE_FAILURES" -eq 0 ]; then
    SUITE_PASS=$(( SUITE_PASS + 1 ))
    printf '  %s✓%s %-26s %s assertion(s), %ss\n' \
      "$T_GRN" "$T_RST" "$CASE_NAME" "$CASE_ASSERTIONS" "$(( _case_end - _case_start ))"
  else
    SUITE_FAIL=$(( SUITE_FAIL + 1 ))
    FAILED_NAMES="$FAILED_NAMES $CASE_NAME"
    printf '  %s✗%s %-26s %s of %s assertion(s) failed\n' \
      "$T_RED" "$T_RST" "$CASE_NAME" "$CASE_FAILURES" "$CASE_ASSERTIONS"
    printf '%s' "$CASE_MESSAGES"
  fi
done

_end_ts=$(date +%s)

printf '\n────────────────────────────────────────────\n'
printf '%sSummary:%s %s%s passed%s, %s%s failed%s  (%s assertions, %ss)\n' \
  "$T_BOLD" "$T_RST" \
  "$T_GRN" "$SUITE_PASS" "$T_RST" \
  "$([ "$SUITE_FAIL" -gt 0 ] && printf '%s' "$T_RED" || printf '%s' "$T_GRN")" \
  "$SUITE_FAIL" "$T_RST" \
  "$SUITE_ASSERTS" "$(( _end_ts - _start_ts ))"

if [ "$SUITE_FAIL" -gt 0 ]; then
  printf 'Failed:%s\n' "$FAILED_NAMES"
  printf '%sResult: FAIL%s\n' "$T_RED" "$T_RST"
  exit 1
fi
printf '%sResult: PASS%s\n' "$T_GRN" "$T_RST"
exit 0
