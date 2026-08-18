#!/bin/bash
# 101 — Import Check permanent cleanup safety
#
# cleanup-verified is intentionally the one Import Check path that can remove
# data permanently. These tests exercise its stronger guarantees: explicit
# confirmation, apply-time re-verification, atomic staging against pathname
# replacement, signal-safe restoration, and macOS hashing/stat portability.

case_description="Import cleanup: atomic delete safety, signals, portability, reclaimed-space stats"

_hash_nas_for_cleanup() {
  local _dir="$1"
  set_paths "$_dir"
  RUN_OUT="$SANDBOX/.run-out.$$"; RUN_RC=0
  ( cd "$SANDBOX" && IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh \
      --pathfile local/paths.txt --jobs 1 --no-discover </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
}

_prepare_cleanup_match() {
  mkdir -p "$FIXTURES/nas" "$FIXTURES/import"
  printf 'shared-payload\n' > "$FIXTURES/nas/keeper.txt"
  printf 'shared-payload\n' > "$FIXTURES/import/copy.txt"

  _hash_nas_for_cleanup "$FIXTURES/nas"
  [ "$RUN_RC" -eq 0 ] || return 1
  run_tool_with_input "$FIXTURES/import" import-check.sh setup
  [ "$RUN_RC" -eq 0 ] || return 1
  run_tool import-check.sh scan
  [ "$RUN_RC" -eq 0 ] || return 1
}

_run_tool_with_shim_input() {
  local _shim="$1" _input="$2" _script="$3"; shift 3
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && \
    printf '%s\n' "$_input" | \
    PATH="$_shim:$PATH" timeout "${TEST_TIMEOUT:-60}" bash "bin/$_script" "$@" \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

run_case() {
  # ── Wrong confirmation: nothing is removed ────────────────────────────
  make_sandbox ic-cleanup-confirm || return 1
  _prepare_cleanup_match || { _assert_fail "could not prepare confirmation fixture"; teardown_sandbox; return 1; }

  run_tool_with_input "NO" import-check.sh cleanup-verified
  assert_rc 0 "cleanup cancellation"
  assert_out_contains "Operation cancelled" "explicit cancellation shown"
  assert_file_exists "$FIXTURES/import/copy.txt" "import copy survives wrong confirmation"
  assert_file_exists "$FIXTURES/nas/keeper.txt" "NAS keeper survives wrong confirmation"
  teardown_sandbox

  # ── Valid match: staged object is deleted and reclaimed space reported ─
  make_sandbox ic-cleanup-delete || return 1
  _prepare_cleanup_match || { _assert_fail "could not prepare delete fixture"; teardown_sandbox; return 1; }

  run_tool_with_input "DELETE" import-check.sh cleanup-verified
  assert_rc 0 "verified cleanup"
  assert_file_missing "$FIXTURES/import/copy.txt" "verified import copy permanently removed"
  assert_file_exists "$FIXTURES/nas/keeper.txt" "NAS keeper survives permanent cleanup"
  assert_out_contains "Space reclaimed:" "reclaimed-space line reported"
  assert_out_contains "15 B" "reclaimed-space byte count reported"
  assert_glob_count "$FIXTURES/import/.hasher-delete.*" 0 "no staging residue after success"
  teardown_sandbox

  # ── Hash failure: staged candidate is restored, never deleted ──────────
  make_sandbox ic-cleanup-hashfail || return 1
  _prepare_cleanup_match || { _assert_fail "could not prepare hash-failure fixture"; teardown_sandbox; return 1; }
  local _failshim="$SANDBOX/shim-cleanup-hashfail"
  mkdir -p "$_failshim"
  printf '#!/bin/bash\nexit 1\n' > "$_failshim/sha256sum"
  printf '#!/bin/bash\nexit 1\n' > "$_failshim/shasum"
  chmod +x "$_failshim/sha256sum" "$_failshim/shasum"

  _run_tool_with_shim_input "$_failshim" "DELETE" import-check.sh cleanup-verified
  assert_rc 1 "cleanup surfaces verification failure"
  assert_file_exists "$FIXTURES/import/copy.txt" "unreadable import candidate restored"
  assert_file_exists "$FIXTURES/nas/keeper.txt" "NAS keeper survives hash failure"
  assert_out_contains "Preserved data:" "preserved-data line reported"
  assert_glob_count "$FIXTURES/import/.hasher-delete.*" 0 "no staging residue after verification failure"
  teardown_sandbox

  # ── TOCTOU regression: replacement at original pathname survives ──────
  # The shim runs only during cleanup. When hashing the staged candidate it
  # recreates the original import pathname with NEW data. Pre-v1.4.31 code
  # then rm'd the original pathname and lost that replacement. Safe code can
  # only rm the already-staged object it actually verified.
  make_sandbox ic-cleanup-replace || return 1
  _prepare_cleanup_match || { _assert_fail "could not prepare replacement-race fixture"; teardown_sandbox; return 1; }
  local _raceshim="$SANDBOX/shim-cleanup-race"
  mkdir -p "$_raceshim"
  cat > "$_raceshim/sha256sum" <<SHIM
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    */.hasher-delete.*)
      printf 'replacement-after-staging\n' > "$FIXTURES/import/copy.txt"
      ;;
  esac
done
exec /usr/bin/sha256sum "\$@"
SHIM
  chmod +x "$_raceshim/sha256sum"

  _run_tool_with_shim_input "$_raceshim" "DELETE" import-check.sh cleanup-verified
  assert_rc 0 "cleanup completes when original path is recreated"
  assert_file_exists "$FIXTURES/import/copy.txt" "replacement created after staging survives"
  local _replacement
  _replacement="$(cat "$FIXTURES/import/copy.txt" 2>/dev/null || true)"
  assert_eq "$_replacement" "replacement-after-staging" "replacement content was not deleted/overwritten"
  assert_file_exists "$FIXTURES/nas/keeper.txt" "NAS keeper survives pathname replacement race"
  assert_glob_count "$FIXTURES/import/.hasher-delete.*" 0 "verified old candidate removed without staging residue"
  teardown_sandbox

  # ── TERM: exit 143, restore staged file, release lock ─────────────────
  make_sandbox ic-cleanup-term || return 1
  _prepare_cleanup_match || { _assert_fail "could not prepare TERM fixture"; teardown_sandbox; return 1; }
  local _termshim="$SANDBOX/shim-cleanup-term"
  local _marker="$SANDBOX/var/cleanup-hash-blocked.marker"
  mkdir -p "$_termshim"
  cat > "$_termshim/sha256sum" <<SHIM
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    */.hasher-delete.*)
      : > "$_marker"
      sleep 2
      ;;
  esac
done
exec /usr/bin/sha256sum "\$@"
SHIM
  chmod +x "$_termshim/sha256sum"
  printf 'DELETE\n' > "$SANDBOX/.cleanup-input"
  local _term_out="$SANDBOX/.cleanup-term-out"
  (
    cd "$SANDBOX" || exit 99
    PATH="$_termshim:$PATH" exec bash bin/import-check.sh cleanup-verified \
      < .cleanup-input > "$_term_out" 2>&1
  ) &
  local _pid=$!
  local _i=0
  while [ ! -e "$_marker" ] && [ "$_i" -lt 50 ]; do
    sleep 0.1
    _i=$(( _i + 1 ))
  done
  if [ ! -e "$_marker" ]; then
    _assert_fail "TERM fixture never reached staged hash"
    kill -KILL "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
  else
    kill -TERM "$_pid" 2>/dev/null || true
    local _term_rc=0
    wait "$_pid" || _term_rc=$?
    assert_eq "$_term_rc" "143" "TERM exits with signal-derived status"
    assert_file_exists "$FIXTURES/import/copy.txt" "TERM restores staged import candidate"
    assert_file_exists "$FIXTURES/nas/keeper.txt" "TERM never touches NAS keeper"
    assert_file_missing "$SANDBOX/var/import-check.lock" "TERM releases import-check lock"
    assert_glob_count "$FIXTURES/import/.hasher-delete.*" 0 "TERM leaves no staged candidate behind"
  fi
  teardown_sandbox

  # ── Shared portability helpers: shasum-only + BSD stat fallback ───────
  make_sandbox ic-cleanup-portable || return 1
  printf 'portable-payload\n' > "$FIXTURES/portable.txt"
  local _portable_shim="$SANDBOX/shim-portable"
  mkdir -p "$_portable_shim"
  cat > "$_portable_shim/shasum" <<'SHIM'
#!/bin/bash
[ "${1:-}" = "-a" ] && shift 2
[ "${1:-}" = "--" ] && shift
exec /usr/bin/sha256sum "$@"
SHIM
  cat > "$_portable_shim/stat" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "-c" ]; then
  exit 1
fi
if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%z" ]; then
  shift 2
  [ "${1:-}" = "--" ] && shift
  exec /usr/bin/stat -c %s "$1"
fi
exit 1
SHIM
  chmod +x "$_portable_shim/shasum" "$_portable_shim/stat"
  local _portable_out _portable_rc=0 _want_hash _want_size
  _portable_out="$(PATH="$_portable_shim" /bin/bash -c \
    '. "$1"; h=$(hasher_sha256_file "$2") || exit 10; s=$(hasher_file_size_bytes "$2") || exit 11; printf "%s|%s" "$h" "$s"' \
    _ "$SANDBOX/lib/host-detect.sh" "$FIXTURES/portable.txt" 2>/dev/null)" || _portable_rc=$?
  _want_hash="$(/usr/bin/sha256sum "$FIXTURES/portable.txt" | awk '{print $1}')"
  _want_size="$(/usr/bin/stat -c %s "$FIXTURES/portable.txt")"
  assert_eq "$_portable_rc" "0" "shasum/BSD-stat fallback returns success"
  assert_eq "$_portable_out" "$_want_hash|$_want_size" "shared portability helpers return correct hash and size"
  teardown_sandbox
}
