#!/bin/bash
# Hasher test harness — shared helpers
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3
#
# Sourced by tests/run-tests.sh and by each case in tests/cases/.
#
# Design notes:
#  - Every case runs in its OWN sandbox: a copy of the install tree under
#    $TEST_TMP/sandbox-NN. Cases therefore cannot contaminate each other,
#    and a case that leaves a lock or a stray process behind cannot break
#    the next one.
#  - Fixtures live under the sandbox too, so `rm -rf` at teardown is
#    sufficient cleanup. Nothing is created outside $TEST_TMP.
#  - Every hasher invocation goes through run_hasher(), which sets
#    IS_SESSION_LEADER=1 to suppress the setsid re-exec. Without that the
#    child outlives `timeout` and strays accumulate — this bit the author
#    repeatedly during manual testing, which is part of why this suite
#    exists.
#  - Assertions are values-in, message-out. A failing assertion records the
#    reason and returns 1; the case decides whether to continue or bail.

# ── Colours (disabled when not a TTY or when NO_COLOR is set) ────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  T_RED=$'\033[0;31m'; T_GRN=$'\033[0;32m'; T_YEL=$'\033[1;33m'
  T_BLU=$'\033[0;34m'; T_BOLD=$'\033[1m';   T_RST=$'\033[0m'
else
  T_RED=""; T_GRN=""; T_YEL=""; T_BLU=""; T_BOLD=""; T_RST=""
fi

# ── Per-case state ──────────────────────────────────────────────────────────
CASE_NAME=""
CASE_FAILURES=0
CASE_ASSERTIONS=0
CASE_MESSAGES=""
SANDBOX=""
FIXTURES=""

# ── Sandbox lifecycle ───────────────────────────────────────────────────────

# make_sandbox — copy the install tree into an isolated directory.
# Sets $SANDBOX and $FIXTURES. Every case calls this first.
# sweep_test_strays — kill any process whose working directory is anywhere
# under $TEST_TMP. Called at the start of every case so a leak from an
# earlier one cannot influence this one's process checks.
#
# This exists because a leftover `bash bin/hasher.sh` from a previous case
# made a later case's "nothing is running" assertion fail: the launcher's
# process scan matches on the script name, not on which install it belongs
# to, so any hasher anywhere looks like a live run.
sweep_test_strays() {
  [ -n "${TEST_TMP:-}" ] || return 0
  [ -d /proc ] || return 0
  local _p _cwd _pids=""
  for _p in /proc/[0-9]*; do
    _cwd="$(readlink "$_p/cwd" 2>/dev/null || true)"
    case "$_cwd" in
      "$TEST_TMP"|"$TEST_TMP"/*) _pids="$_pids ${_p#/proc/}" ;;
    esac
  done
  if [ -n "$(printf '%s' "$_pids" | tr -d ' ')" ]; then
    kill -KILL $_pids 2>/dev/null || true
    sleep 0.2
  fi
}

make_sandbox() {
  local _tag="${1:-case}"
  sweep_test_strays
  SANDBOX="$TEST_TMP/sandbox-$_tag"
  FIXTURES="$SANDBOX/fixtures"
  rm -rf "$SANDBOX" 2>/dev/null || true
  mkdir -p "$SANDBOX" "$FIXTURES" || return 1

  # Copy only what the tools need. Skipping hashes/ and logs/ keeps each
  # sandbox small and guarantees a clean starting state.
  local _d
  for _d in bin lib default; do
    [ -d "$HASHER_ROOT/$_d" ] && cp -r "$HASHER_ROOT/$_d" "$SANDBOX/" 2>/dev/null
  done
  cp "$HASHER_ROOT/launcher.sh" "$SANDBOX/" 2>/dev/null || true
  mkdir -p "$SANDBOX/hashes" "$SANDBOX/logs" "$SANDBOX/var" "$SANDBOX/local"
  chmod +x "$SANDBOX"/bin/*.sh "$SANDBOX/launcher.sh" 2>/dev/null || true

  # Neutral defaults: no inherited paths, discovery off unless a case wants it.
  : > "$SANDBOX/local/paths.txt"
  : > "$SANDBOX/local/excludes.txt"
  return 0
}

# teardown_sandbox — kill strays belonging to this sandbox, then remove it.
# Honours --keep (TEST_KEEP=1), which leaves the tree in place for inspection
# after a failure. Strays are still killed either way.
teardown_sandbox() {
  [ -n "$SANDBOX" ] || return 0
  # Find processes belonging to this sandbox and stop them.
  #
  # Matching on argv is not sufficient: cases invoke tools as
  # `cd "$SANDBOX" && bash bin/hasher.sh`, so the command line holds a
  # RELATIVE path and never contains the sandbox path at all. A leftover
  # process would then survive teardown and be seen by a later case — which
  # is exactly how a stale hasher from one case made a later case's
  # "nothing is running" assertion fail.
  #
  # Working directory is the reliable signal. /proc/PID/cwd covers Linux and
  # Synology; the argv match is kept as a fallback for platforms without
  # /proc (macOS), where absolute invocations are still caught.
  local _pids="" _p _cwd
  if [ -d /proc ]; then
    for _p in /proc/[0-9]*; do
      _cwd="$(readlink "$_p/cwd" 2>/dev/null || true)"
      # Once a sandbox is removed the link reads "<path> (deleted)", so the
      # bare prefix match must tolerate a trailing suffix.
      case "$_cwd" in
        "$SANDBOX"|"$SANDBOX"/*|"$SANDBOX "*|"$SANDBOX"/*" "*) _pids="$_pids ${_p#/proc/}" ;;
      esac
    done
  fi
  _pids="$_pids $(ps -eo pid=,args= 2>/dev/null | grep -F "$SANDBOX" | grep -v grep | awk '{print $1}' || true)"

  if [ -n "$(printf '%s' "$_pids" | tr -d ' ')" ]; then
    kill -TERM $_pids 2>/dev/null || true
    sleep 0.3
    kill -KILL $_pids 2>/dev/null || true
    # Give the kernel a moment to reap, so the next case's process checks
    # start from a genuinely clean slate.
    sleep 0.2
  fi

  if [ "${TEST_KEEP:-0}" != "1" ]; then
    rm -rf "$SANDBOX" 2>/dev/null || true
  fi
  SANDBOX=""; FIXTURES=""
}

# ── Running hasher and tools ────────────────────────────────────────────────

# run_hasher <args...> — run bin/hasher.sh in the sandbox.
# Captures combined output in $RUN_OUT (a file) and exit code in $RUN_RC.
# IS_SESSION_LEADER=1 suppresses the setsid re-exec so `timeout` can
# actually reap the process.
RUN_OUT=""
RUN_RC=0
run_hasher() {
  RUN_OUT="$SANDBOX/.run-out.$$"
  rm -f "$SANDBOX/var/hasher.lock" 2>/dev/null || true
  rm -rf "$SANDBOX/var/hasher.lock" 2>/dev/null || true
  RUN_RC=0
  ( cd "$SANDBOX" && \
    IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh "$@" </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

# run_hasher_with_shim <shim_dir> <args...> — as run_hasher, with $shim_dir
# prepended to PATH so a fault-injection shim takes precedence.
run_hasher_with_shim() {
  local _shim="$1"; shift
  RUN_OUT="$SANDBOX/.run-out.$$"
  rm -rf "$SANDBOX/var/hasher.lock" 2>/dev/null || true
  RUN_RC=0
  ( cd "$SANDBOX" && \
    PATH="$_shim:$PATH" IS_SESSION_LEADER=1 HASHER_SESSION_LEADER=1 \
    timeout "${TEST_TIMEOUT:-60}" bash bin/hasher.sh "$@" </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

# run_tool <script> <args...> — run any bin/ script in the sandbox.
run_tool() {
  local _script="$1"; shift
  RUN_OUT="$SANDBOX/.run-out.$$"
  RUN_RC=0
  ( cd "$SANDBOX" && \
    timeout "${TEST_TIMEOUT:-60}" bash "bin/$_script" "$@" </dev/null \
  ) > "$RUN_OUT" 2>&1 || RUN_RC=$?
  return 0
}

# out_plain — the last run's output with ANSI colour stripped.
out_plain() {
  sed 's/\x1b\[[0-9;]*m//g' "$RUN_OUT" 2>/dev/null
}

# ── Fault-injection shims ───────────────────────────────────────────────────
# Each returns the shim directory path on stdout. Callers pass it to
# run_hasher_with_shim.

# shim_hash_always_fails — sha256sum/shasum exit 1 for every file.
# Exercises the failure-counting and partial-manifest paths.
shim_hash_always_fails() {
  local _d="$SANDBOX/shim-hashfail"
  mkdir -p "$_d"
  printf '#!/bin/bash\nexit 1\n' > "$_d/sha256sum"
  printf '#!/bin/bash\nexit 1\n' > "$_d/shasum"
  chmod +x "$_d/sha256sum" "$_d/shasum"
  printf '%s' "$_d"
}

# shim_mutate_during_hash — rewrites each file with longer content just
# before hashing it, so size and mtime both drift. Exercises the
# stability check's obvious case.
shim_mutate_during_hash() {
  local _d="$SANDBOX/shim-mutate"
  mkdir -p "$_d"
  cat > "$_d/sha256sum" <<'SHIM'
#!/bin/bash
for arg in "$@"; do
  [ "$arg" = "--" ] && continue
  case "$arg" in -*) continue ;; esac
  if [ -f "$arg" ]; then
    printf 'mutated-during-hash-longer-content\n' > "$arg"
  fi
done
exec /usr/bin/sha256sum "$@"
SHIM
  chmod +x "$_d/sha256sum"
  printf '%s' "$_d"
}

# shim_mutate_preserve_mtime — rewrites each file with DIFFERENT content of
# the SAME length, then restores the original mtime. Only ctime changes.
# This is the case that a size+mtime-only stability check misses, and the
# reason _stat_fingerprint includes ctime, dev and ino.
#
# The sleep is deliberate: ctime has whole-second resolution, so without a
# forced tick the write can land inside the same second as the pre-hash stat
# and the drift becomes genuinely undetectable.
shim_mutate_preserve_mtime() {
  local _d="$SANDBOX/shim-preserve"
  mkdir -p "$_d"
  cat > "$_d/sha256sum" <<'SHIM'
#!/bin/bash
for arg in "$@"; do
  [ "$arg" = "--" ] && continue
  case "$arg" in -*) continue ;; esac
  if [ -f "$arg" ]; then
    _orig_mtime="$(stat -c '%Y' "$arg" 2>/dev/null || stat -f '%m' "$arg" 2>/dev/null)"
    _len="$(wc -c < "$arg" | tr -d ' ')"
    sleep 1
    # Same byte count, different bytes.
    head -c "$_len" /dev/zero | tr '\0' 'Z' > "$arg"
    touch -d "@$_orig_mtime" "$arg" 2>/dev/null || \
      touch -t "$(date -r "$_orig_mtime" '+%Y%m%d%H%M.%S' 2>/dev/null)" "$arg" 2>/dev/null || true
  fi
done
exec /usr/bin/sha256sum "$@"
SHIM
  chmod +x "$_d/sha256sum"
  printf '%s' "$_d"
}

# shim_rm_fails — rm exits 1 for files under the fixtures dir.
# Exercises destructive-tool exit-status fidelity.
shim_rm_fails() {
  local _d="$SANDBOX/shim-rmfail"
  mkdir -p "$_d"
  cat > "$_d/rm" <<SHIM
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    $FIXTURES/*) echo "simulated rm failure: \$a" >&2; exit 1 ;;
  esac
done
exec /bin/rm "\$@"
SHIM
  chmod +x "$_d/rm"
  printf '%s' "$_d"
}

# shim_pgrep_broken — pgrep exists but returns nothing and exits clean.
# Exercises the behavioural probe that decides whether to trust pgrep.
shim_pgrep_broken() {
  local _d="$SANDBOX/shim-pgrep"
  mkdir -p "$_d"
  printf '#!/bin/bash\nexit 0\n' > "$_d/pgrep"
  chmod +x "$_d/pgrep"
  printf '%s' "$_d"
}

# ── Fixture builders ────────────────────────────────────────────────────────

# fixture_files <dir> <n> [content_prefix] — n files with distinct content.
fixture_files() {
  local _dir="$1" _n="$2" _prefix="${3:-content}"
  mkdir -p "$_dir"
  local _i=1
  while [ "$_i" -le "$_n" ]; do
    printf '%s-%s\n' "$_prefix" "$_i" > "$_dir/f$_i.txt"
    _i=$(( _i + 1 ))
  done
}

# fixture_duplicate_pair <dir> — two files with identical content.
fixture_duplicate_pair() {
  local _dir="$1"
  mkdir -p "$_dir"
  printf 'identical-content\n' > "$_dir/copy-a.txt"
  printf 'identical-content\n' > "$_dir/copy-b.txt"
}

# fixture_hardlinks <dir> — one inode with 3 names, plus one genuine copy.
fixture_hardlinks() {
  local _dir="$1"
  mkdir -p "$_dir"
  printf 'shared-inode-content\n' > "$_dir/original.txt"
  ln "$_dir/original.txt" "$_dir/link-1.txt"
  ln "$_dir/original.txt" "$_dir/link-2.txt"
  cp "$_dir/original.txt" "$_dir/genuine-copy.txt"
}

# fixture_symlink <dir> — a real file plus a symlink pointing at it.
fixture_symlink() {
  local _dir="$1"
  mkdir -p "$_dir"
  printf 'symlink-target-content\n' > "$_dir/target.txt"
  ln -s "$_dir/target.txt" "$_dir/link.txt"
}

# fixture_twin_folders_one_symlink <base> — two folders with identical
# regular files, one of which also holds a unique symlink. Folder dedup
# must refuse this pair: the signature only sees regular files, so moving
# one folder would silently discard the symlink.
fixture_twin_folders_one_symlink() {
  local _base="$1"
  mkdir -p "$_base/twin-a" "$_base/twin-b"
  printf 'twin-content\n' > "$_base/twin-a/shared.txt"
  printf 'twin-content\n' > "$_base/twin-b/shared.txt"
  ln -s /nonexistent-target "$_base/twin-b/unique-link"
}

# fixture_overlapping_roots <base> — a parent and a child directory, both
# of which a careless paths.txt might list.
fixture_overlapping_roots() {
  local _base="$1"
  mkdir -p "$_base/parent/child"
  printf 'in-parent\n' > "$_base/parent/top.txt"
  printf 'in-child\n'  > "$_base/parent/child/nested.txt"
}

# fixture_manifest <path> <mode> — write a CSV manifest.
#   mode=valid      two rows, well formed
#   mode=malformed  two valid rows plus one truncated row
#   mode=badalgo    one row whose algo column says md5
fixture_manifest() {
  local _path="$1" _mode="${2:-valid}"
  local _h
  _h="$(printf 'manifest-content\n' | sha256sum | awk '{print $1}')"
  printf 'path,size_bytes,mtime_epoch,algo,hash\n' > "$_path"
  case "$_mode" in
    valid)
      printf '"/tmp/mf-a.txt",17,1700000000,sha256,%s\n' "$_h" >> "$_path"
      printf '"/tmp/mf-b.txt",17,1700000000,sha256,%s\n' "$_h" >> "$_path"
      ;;
    malformed)
      printf '"/tmp/mf-a.txt",17,1700000000,sha256,%s\n' "$_h" >> "$_path"
      printf 'truncated-row-with-too-few-columns\n' >> "$_path"
      printf '"/tmp/mf-b.txt",17,1700000000,sha256,%s\n' "$_h" >> "$_path"
      ;;
    badalgo)
      printf '"/tmp/mf-a.txt",17,1700000000,md5,%s\n' "$_h" >> "$_path"
      printf '"/tmp/mf-b.txt",17,1700000000,md5,%s\n' "$_h" >> "$_path"
      ;;
  esac
}

# set_paths <path...> — write the sandbox paths.txt.
set_paths() {
  : > "$SANDBOX/local/paths.txt"
  local _p
  for _p in "$@"; do printf '%s\n' "$_p" >> "$SANDBOX/local/paths.txt"; done
}

# latest_csv — newest complete manifest in the sandbox (excludes partial-*).
latest_csv() {
  ls -1t "$SANDBOX"/hashes/hasher-*.csv 2>/dev/null | head -n1 || true
}

# csv_rows <csv> — data row count (excludes the header).
csv_rows() {
  local _c="$1"
  [ -r "$_c" ] || { printf '0'; return; }
  local _n
  _n=$(( $(wc -l < "$_c" | tr -d ' ') - 1 ))
  [ "$_n" -lt 0 ] && _n=0
  printf '%s' "$_n"
}

# ── Assertions ──────────────────────────────────────────────────────────────
# Each records pass/fail and returns 0/1 so a case can branch on the result.

_assert_pass() { CASE_ASSERTIONS=$(( CASE_ASSERTIONS + 1 )); return 0; }
_assert_fail() {
  CASE_ASSERTIONS=$(( CASE_ASSERTIONS + 1 ))
  CASE_FAILURES=$(( CASE_FAILURES + 1 ))
  CASE_MESSAGES="${CASE_MESSAGES}      ${T_RED}✗${T_RST} $1
"
  return 1
}

assert_rc() {
  local _want="$1" _what="${2:-exit code}"
  if [ "$RUN_RC" = "$_want" ]; then _assert_pass
  else _assert_fail "$_what: expected $_want, got $RUN_RC"; fi
}

assert_eq() {
  local _got="$1" _want="$2" _what="${3:-value}"
  if [ "$_got" = "$_want" ]; then _assert_pass
  else _assert_fail "$_what: expected '$_want', got '$_got'"; fi
}

assert_out_contains() {
  local _needle="$1" _what="${2:-output}"
  if out_plain | grep -qF -- "$_needle"; then _assert_pass
  else _assert_fail "$_what: expected to contain '$_needle'"; fi
}

assert_out_not_contains() {
  local _needle="$1" _what="${2:-output}"
  if out_plain | grep -qF -- "$_needle"; then
    _assert_fail "$_what: expected NOT to contain '$_needle'"
  else _assert_pass; fi
}

assert_file_exists() {
  local _f="$1" _what="${2:-file}"
  if [ -e "$_f" ]; then _assert_pass
  else _assert_fail "$_what: expected to exist: $_f"; fi
}

assert_file_missing() {
  local _f="$1" _what="${2:-file}"
  if [ -e "$_f" ]; then _assert_fail "$_what: expected NOT to exist: $_f"
  else _assert_pass; fi
}

assert_glob_count() {
  local _pattern="$1" _want="$2" _what="${3:-glob}"
  local _n
  _n=$(ls -1d $_pattern 2>/dev/null | wc -l | tr -d ' ')
  if [ "$_n" = "$_want" ]; then _assert_pass
  else _assert_fail "$_what: expected $_want match(es) for '$_pattern', got $_n"; fi
}

# note — informational line in verbose mode; never affects pass/fail.
note() {
  [ "${TEST_VERBOSE:-0}" = "1" ] || return 0
  printf '      %s· %s%s\n' "$T_BLU" "$1" "$T_RST"
}
