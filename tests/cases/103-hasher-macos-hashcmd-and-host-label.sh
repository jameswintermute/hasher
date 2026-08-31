#!/bin/bash
# 103 — hasher.sh: hash-tool resolution survives the global IFS override;
# host_pretty_label() reports actual OS version, not a bare platform name
#
# Reported live, from a real macOS Sonoma machine (M1 iMac): hashing
# failed immediately with "Hash tool 'shasum -a 256' not found in PATH",
# even though `shasum -a 256` worked perfectly when run directly in the
# same terminal. Root cause: hasher.sh sets a global IFS=$'\n\t' (no
# space) at the top of the file, for safe newline/NUL-aware path
# handling elsewhere. _resolve_hash_cmd() correctly returns the string
# "shasum -a 256" on a system with no sha256sum, but the bare
# `read -ra hash_cmd <<< "$hash_cmd_str"` that was meant to split it into
# an array relies on IFS containing a space — under the global override,
# it doesn't, so the WHOLE STRING became one array element. The very
# next line's `command -v "${hash_cmd[0]}"` then looked up a binary
# literally named "shasum -a 256", which of course doesn't exist,
# reporting the tool as missing when it was never the actual problem.
#
# This exact class of bug — global IFS silently breaking a `read` that
# needed default whitespace splitting — had already been found and fixed
# twice elsewhere in this same file (the /proc/PID/stat parsing, v1.4.1);
# this call site was simply missed at the time. Fixed the same way:
# IFS=' ' set locally on the `read` itself.
#
# A second issue, unrelated in cause but reported in the same session:
# the launcher's "Host:" line showed a bare platform name ("macOS") with
# no version detail at all, on every platform. Now reports the actual
# version from each platform's own source of truth (sw_vers on macOS,
# /etc.defaults/VERSION on Synology DSM, /etc/os-release's PRETTY_NAME on
# generic Linux), falling back to the original bare name if the
# platform-specific lookup fails for any reason.

case_description="hasher.sh survives the global IFS override when resolving shasum; host_pretty_label reports real OS version per platform"

# Runs bin/hasher.sh with `command -v sha256sum` forced to fail, as if
# on a system that only has shasum (i.e. real macOS). The override is a
# bash function exported into the environment, so it's visible to the
# real hasher.sh process this actually invokes — not a separate,
# simplified reproduction of the logic under test.
_run_hasher_no_sha256sum() {
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && \
    command() {
      if [ "$1" = "-v" ] && [ "$2" = "sha256sum" ]; then return 1; fi
      builtin command "$@"
    }
    export -f command
    IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh "$@" </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

run_case() {
  # ── The exact reported scenario: sha256sum absent, shasum present ──────
  make_sandbox hashcmd-shasum-fallback-works || return 1
  mkdir -p "$FIXTURES/data"
  printf 'hello\n' > "$FIXTURES/data/a.txt"
  set_paths "$FIXTURES/data"

  _run_hasher_no_sha256sum --pathfile local/paths.txt --jobs 1 --no-discover
  assert_rc 0 "hashing succeeds via the shasum fallback, not the bug's exit 1"
  assert_out_not_contains "not found in PATH" "no false 'tool missing' error"

  local _csv
  _csv="$(ls -1t "$SANDBOX"/hashes/hasher-*.csv 2>/dev/null | head -n1)"
  assert_file_exists "$_csv" "CSV was actually written"
  if [ -r "$_csv" ] && grep -q '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03' "$_csv"; then
    _assert_pass
  else
    _assert_fail "correct sha256 of 'hello' not found in the CSV — fallback hash tool produced wrong or no output"
  fi
  teardown_sandbox

  # ── Confirm the array actually has 3 elements, not 1 ────────────────────
  # The bug's specific symptom: the whole string "shasum -a 256" collapsed
  # into a single element. Verified directly against the resolver and
  # split logic, isolated from the rest of hasher.sh, so this asserts the
  # actual mechanism rather than only its downstream, harder-to-attribute
  # consequence (a missing-tool error).
  make_sandbox hashcmd-split-produces-three-elements || return 1
  local _out
  _out="$(cd "$SANDBOX" && bash -c '
    IFS=$'"'"'\n\t'"'"'
    eval "$(sed -n "/^_resolve_hash_cmd()/,/^}/p" bin/hasher.sh)"
    command() { if [ "$1" = "-v" ] && [ "$2" = "sha256sum" ]; then return 1; fi; builtin command "$@"; }
    hash_cmd_str="$(_resolve_hash_cmd sha256)"
    IFS='"'"' '"'"' read -ra hash_cmd <<< "$hash_cmd_str"
    printf "count=%d elem0=%s\n" "${#hash_cmd[@]}" "${hash_cmd[0]}"
  ' 2>&1)"
  case "$_out" in
    "count=3 elem0=shasum") _assert_pass ;;
    *) _assert_fail "expected 'count=3 elem0=shasum', got: $_out" ;;
  esac
  teardown_sandbox

  # ── host_pretty_label: macOS branch reports the real version ────────────
  make_sandbox host-label-macos-version || return 1
  mkdir -p "$SANDBOX/.shim"
  printf '#!/bin/bash\n[ "$1" = "-productVersion" ] && echo "14.1.1"\n' > "$SANDBOX/.shim/sw_vers"
  chmod +x "$SANDBOX/.shim/sw_vers"
  local _label
  _label="$(cd "$SANDBOX" && PATH=".shim:$PATH" bash -c '
    . lib/host-detect.sh
    HASHER_HOST="macos"
    host_pretty_label
  ')"
  assert_eq "$_label" "macOS 14.1.1" "macOS branch includes the real version"
  teardown_sandbox

  # ── host_pretty_label: macOS falls back cleanly with no sw_vers ─────────
  make_sandbox host-label-macos-fallback || return 1
  _label="$(cd "$SANDBOX" && PATH="/usr/bin:/bin" bash -c '
    . lib/host-detect.sh
    HASHER_HOST="macos"
    host_pretty_label
  ')"
  assert_eq "$_label" "macOS" "macOS branch falls back to the bare name when sw_vers is unavailable"
  teardown_sandbox

  # ── host_pretty_label: Synology DSM branch builds the version string ────
  make_sandbox host-label-dsm-version || return 1
  mkdir -p "$SANDBOX/.fakeetc"
  {
    printf 'majorversion="7"\n'
    printf 'minorversion="2"\n'
    printf 'smallfixnumber="1"\n'
    printf 'buildnumber="69057"\n'
  } > "$SANDBOX/.fakeetc/VERSION"
  _label="$(cd "$SANDBOX" && sed "s|/etc.defaults/VERSION|$SANDBOX/.fakeetc/VERSION|" lib/host-detect.sh > .host-detect-test.sh && bash -c '
    . ./.host-detect-test.sh
    HASHER_HOST="synology"
    host_pretty_label
  ')"
  assert_eq "$_label" "Synology DSM 7.2.1-69057" "DSM branch builds major.minor.smallfix-build correctly"
  teardown_sandbox

  # ── host_pretty_label: Linux branch uses PRETTY_NAME as-is ──────────────
  make_sandbox host-label-linux-pretty-name || return 1
  printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\n' > "$SANDBOX/.fake-os-release"
  _label="$(cd "$SANDBOX" && sed "s|/etc/os-release|$SANDBOX/.fake-os-release|" lib/host-detect.sh > .host-detect-test2.sh && bash -c '
    . ./.host-detect-test2.sh
    HASHER_HOST="linux"
    host_pretty_label
  ')"
  assert_eq "$_label" "Ubuntu 24.04.1 LTS" "Linux branch reports PRETTY_NAME directly, already self-describing"
  teardown_sandbox
}
