#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ─── Process-group isolation (v1.3.16, revised v1.3.17 for review finding #1) ─
# The parallel path fans work out via `xargs -0 -P N` and `bash -c` workers,
# which then invoke the hash command (sha256sum/shasum). None of those
# descendants have "bin/hasher.sh" in their argv, so the launcher's ps-based
# process finder cannot see them. TERM to the parent leaves xargs, workers
# and hash processes orphaned (reparented to init). Fix: put hasher.sh in
# its own SESSION (which is also a new process group). The TERM/INT traps
# and the launcher can then signal the whole group with `kill -TERM -PGID`,
# and every descendant goes down together.
#
# v1.3.17 revisions after external review:
#   1. Do NOT redirect stdin from /dev/null unconditionally. The reviewer
#      showed this breaks the documented piped-paths interface
#      (`echo /path | hasher.sh` produced 0/0 empty CSVs). Only redirect
#      when stdin is already a TTY — a piped stdin is real input we must
#      preserve. The v1.3.16 hang I saw came from stdin inheriting a
#      closed pipe from a test harness, not from a real usage pattern.
#   2. HASHER_SESSION_LEADER must be UNSET before spawning a --nohup child,
#      or the child inherits it and skips its own re-exec — leaving the
#      child in the parent shell's session, not its own. Handled at the
#      --nohup spawn site further down, not here.
#   3. If setsid is unavailable, we DO NOT attempt group signalling on this
#      process. The TERM trap and launcher check whether we own our PGID
#      (getsid $$ == $$) before using -PGID kills. Otherwise we would
#      signal our caller's shell.
if [[ -z "${HASHER_SESSION_LEADER:-}" ]]; then
  # v1.3.17: use PGID (not SID) for portability — session IDs can be 0 or
  # unreliable in some container/namespace configs, but PGID is universal.
  _pg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo '')"
  if [[ -n "$_pg" && "$_pg" != "$$" ]]; then
    if command -v setsid >/dev/null 2>&1; then
      export HASHER_SESSION_LEADER=1
      # `setsid` starts a new session; the new pgid == new pid. Use exec so
      # this shell is REPLACED, not sitting above the real process.
      # v1.3.17: preserve stdin unless it's a TTY. Piped input is legitimate
      # (documented at --pathfile help: "Required unless paths are piped").
      # Only when the caller has left stdin as a TTY (interactive) is it
      # safe (and helpful) to redirect from /dev/null so a background run
      # doesn't block on read.
      if [[ -t 0 ]]; then
        exec setsid "$0" "$@" </dev/null
      else
        exec setsid "$0" "$@"
      fi
    fi
    # No setsid available: continue without session isolation. Group-signalling
    # is unsafe in this case — the TERM handler below checks IS_SESSION_LEADER.
  fi
  export HASHER_SESSION_LEADER=1
fi

# Am I the leader of my own process group? This is what actually matters for
# `kill -PGID` — signalling the group only takes out our own descendants when
# we own the group. Use PGID equality (portable across Linux/DSM/macOS/BusyBox)
# rather than SID equality (returns 0 in some container/namespace configs).
_our_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo '')"
if [[ -n "$_our_pgid" && "$_our_pgid" = "$$" ]]; then
  IS_SESSION_LEADER=1
else
  IS_SESSION_LEADER=0
fi
export IS_SESSION_LEADER

# ───────────────────────── Root dir ────────────────────────
# FIX: all dirs were relative ("hashes", "logs", "zero-length") which broke
# direct CLI calls from outside the repo root. Now all paths are anchored
# to ROOT_DIR so hasher.sh works correctly regardless of working directory.
ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# v1.3.19 (peer-review finding #1): auto-detect awk NUL support and use bash
# fallbacks on BusyBox. See lib/awk-detect.sh for the two helpers and why.
if [ -r "$ROOT_DIR/lib/awk-detect.sh" ]; then
  . "$ROOT_DIR/lib/awk-detect.sh"
  hasher_detect_awk_nul_safety
fi

# v1.3.20 patch (Mary's Mac Tahoe report): source host-detect.sh so
# build_file_list can pull host_find_prune_args. Previously only the
# launcher sourced this; when hasher.sh runs as a nohup child (which is
# ALWAYS on Mary's Mac, because that's what option 1 does), host-detect
# wasn't loaded — so `command -v host_find_prune_args` returned false
# and the macOS system-dir prune never activated. Now it always loads.
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  . "$ROOT_DIR/lib/host-detect.sh"
  detect_host
fi

# v1.3.20 (peer-review recheck finding #2): verify we have a way to enumerate
# our own process group members BEFORE main() runs. Without either pgrep or
# `ps -eo pid=,pgid=`, _stop_group cannot see workers to kill; a TERM would
# release the lock while xargs and workers keep running. Prefer pgrep; fall
# back to ps; abort if neither works. This runs at every hasher.sh start —
# tiny probe, no perf impact — so `k) Stop hashing` never silently degrades.
if ! command -v pgrep >/dev/null 2>&1; then
  # pgrep absent — check the ps fallback is usable
  _probe="$(ps -eo pid=,pgid= 2>/dev/null | head -1)"
  if [ -z "$_probe" ]; then
    printf '[ERROR] Neither pgrep nor `ps -eo pid=,pgid=` is available on this host.\n' >&2
    printf '[ERROR] Hasher cannot safely stop parallel workers without one of them.\n' >&2
    printf '[ERROR] Install procps (pgrep) or a POSIX-ish ps, then re-run.\n' >&2
    exit 3
  fi
fi

# ───────────────────────── Constants ───────────────────────
HASHES_DIR="$ROOT_DIR/hashes"
LOGS_DIR="$ROOT_DIR/logs"
VAR_DIR="$ROOT_DIR/var"
# FIX: ZERO_DIR moved from repo root into var/ to consolidate working files
ZERO_DIR="$VAR_DIR/zero-length"
# v1.3.3: hasher.sh owns its own pidfile (same path the launcher checks),
# written at start of main() and removed by the cleanup trap. This replaces
# the launcher's broken "( wait $bgpid; clear_pidfile ) &" subshell, which
# cleared the pidfile almost immediately because a subshell cannot wait on a
# sibling process.
HASHER_PIDFILE="$VAR_DIR/hasher.pid"

# DATE_TAG is kept for human-facing daily reports
DATE_TAG="$(date +'%Y-%m-%d')"
# v1.3.16 (peer-review finding #3): CSV_TAG uses SECONDS + a short run ID so
# concurrent or same-minute starts get distinct output files. Previously the
# minute-precision tag caused a second run in the same minute to APPEND to the
# first CSV (write_csv_header returned early when the file existed), producing
# a single merged manifest — reviewer reproduced this. SMB-safe: no colon.
CSV_TAG="$(date +'%F-%H%M%S')-$$"
OUTPUT="$HASHES_DIR/hasher-$CSV_TAG.csv"

ALGO="sha256"        # sha256|sha1|sha512|md5|blake2
PATHFILE=""
RUN_IN_BACKGROUND=false
IS_CHILD=false       # set when re-exec'ed under nohup
LOG_LEVEL="info"     # info|warn|error
# v1.3.22: sort the output CSV by path after hashing completes. Default on
# for deterministic output and cross-run diffing. The sort is fail-safe:
# original CSV is NEVER touched until the sorted candidate has been fully
# validated (row count matches, header intact). See sort_output_csv().
SORT_OUTPUT="true"
ZERO_LENGTH_ONLY=false

# Optional config (CLI can override)
CONFIG_FILE=""

# Progress interval (seconds) for background.log
PROGRESS_INTERVAL=15

# Parallel hashing workers (v1.2.0). 1 = serial (historical behaviour).
# Overridable via --jobs N, HASH_JOBS env, or [performance] jobs in hasher.conf.
# Precedence: --jobs flag > hasher.conf > HASH_JOBS env > default (1).
HASH_JOBS="${HASH_JOBS:-1}"

# Default excludes (kept minimal; comment out if undesired)
DEFAULT_EXCLUDES=( "#recycle" "@eaDir" ".DS_Store" "lost+found" )
EXTRA_EXCLUDES=()

# ───────────────────────── Colors ──────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───────────────────────── Platform Shims ──────────────────
# Detect BSD stat (macOS) vs GNU stat (Linux/BusyBox/Synology)
# and sha256sum vs shasum -a 256, so hasher runs on both platforms
# without requiring GNU coreutils to be installed via Brew.
if stat -c "%s" /dev/null >/dev/null 2>&1; then
  # GNU stat (Linux, BusyBox, Synology DSM)
  _stat_size()  { stat -c "%s" -- "$1"; }
  _stat_mtime() { stat -c "%Y" -- "$1"; }
else
  # BSD stat (macOS)
  _stat_size()  { stat -f "%z" -- "$1"; }
  _stat_mtime() { stat -f "%m" -- "$1"; }
fi

# Detect sha256sum vs shasum (macOS ships shasum, not sha256sum)
_resolve_hash_cmd() {
  local algo="$1"
  case "$algo" in
    sha256)
      if command -v sha256sum >/dev/null 2>&1; then
        echo "sha256sum"
      elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 256"
      else
        echo ""
      fi
      ;;
    sha1)
      if command -v sha1sum >/dev/null 2>&1; then
        echo "sha1sum"
      elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 1"
      else
        echo ""
      fi
      ;;
    sha512)
      if command -v sha512sum >/dev/null 2>&1; then
        echo "sha512sum"
      elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 512"
      else
        echo ""
      fi
      ;;
    md5)
      if command -v md5sum >/dev/null 2>&1; then
        echo "md5sum"
      elif command -v md5 >/dev/null 2>&1; then
        echo "md5 -r"   # macOS md5 with -r gives same "hash  path" format
      else
        echo ""
      fi
      ;;
    blake2)
      if command -v b2sum >/dev/null 2>&1; then
        echo "b2sum"
      else
        echo ""
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

# ───────────────────────── Pre-scan for --config ───────────
if (( "$#" > 0 )); then
  i=1
  while (( i <= $# )); do
    eval _arg="\${$i}"
    if [[ "$_arg" == "--config" ]]; then
      j=$((i+1)); eval CONFIG_FILE="\${$j}"
      break
    fi
    i=$((i+1))
  done
fi
# Auto-load local/hasher.conf if present and no --config provided
if [[ -z "$CONFIG_FILE" && -f "$ROOT_DIR/local/hasher.conf" ]]; then
  CONFIG_FILE="$ROOT_DIR/local/hasher.conf"
elif [[ -z "$CONFIG_FILE" && -f "$ROOT_DIR/default/hasher.conf" ]]; then
  CONFIG_FILE="$ROOT_DIR/default/hasher.conf"
fi

# ───────────────────────── Human-friendly time ─────────────
human_dur() {
  local s="${1:-0}"
  case "$s" in
    ''|*[!0-9]*) s=0 ;;
  esac
  local h=$((s/3600))
  local m=$(((s%3600)/60))
  if (( h > 0 )); then
    printf "%dh %02dm" "$h" "$m"
  elif (( m > 0 )); then
    printf "%dm" "$m"
  else
    printf "%ds" "$s"
  fi
}

# ───────────────────────── Run ID ──────────────────────────
if command -v uuidgen >/dev/null 2>&1; then
  RUN_ID="$(uuidgen)"
elif [[ -r /proc/sys/kernel/random/uuid ]]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$"
fi

# Derived paths
MAIN_LOG="$LOGS_DIR/hasher.log"
RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
# FIX: FILES_LIST moved from logs/ to var/ — it's a working/temp file, not a log
FILES_LIST="$VAR_DIR/files-$RUN_ID.lst"
BACKGROUND_LOG="$LOGS_DIR/background.log"

# ───────────────────────── Setup dirs ──────────────────────
mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$VAR_DIR" "$ZERO_DIR"

# ───────────────────────── Logging ─────────────────────────
_log() {
  local lvl="$1"; shift
  local msg="$*"
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [RUN $RUN_ID] [$lvl] $msg"
  case "$lvl" in
    INFO)  echo -e "${GREEN}$line${NC}";;
    WARN)  echo -e "${YELLOW}$line${NC}";;
    ERROR) echo -e "${RED}$line${NC}";;
    *)     echo "$line";;
  esac
  printf '%s\n' "$line" >> "$MAIN_LOG"
  printf '%s\n' "$line" >> "$RUN_LOG"
}

bglog() {
  local lvl="$1"; shift
  local msg="$*"
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RUN %s] [%s] %s\n' "$ts" "$RUN_ID" "$lvl" "$msg" >> "$BACKGROUND_LOG"
}

info()  { _log "INFO"  "$*"; }
warn()  { _log "WARN"  "$*"; }
error() { _log "ERROR" "$*"; }

# ───────────────────────── Config loader ───────────────────
# INI-aware. Supported:
#   [setup]    algo, pathfile, output, hashes_dir, logs_dir
#   [logging]  level, background-interval, xtrace
#   [exclusions]
#              inherit-defaults=true|false
#              exclude=PATTERN  (or bare line "PATTERN" with no '=' )
# Other sections/keys are ignored without warnings.
load_config() {
  local f="$1"
  [[ -f "$f" ]] || { warn "Config not found: $f (ignoring)"; return; }

  local section=""

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" || "${line:0:1}" == ";" ]] && continue

    if [[ "$line" =~ ^\[[^][]+\]$ ]]; then
      section="${line:1:${#line}-2}"
      section="$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]')"
      continue
    fi

    local key val
    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"; val="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"; key="${key#"${key%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"; val="${val#"${val%%[![:space:]]*}"}"
      [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]] && val="${val:1:-1}"
      [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]] && val="${val:1:-1}"
      key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    else
      key="__bare__"
      val="$line"
    fi

    case "$section" in
      ""|"setup")
        case "$key" in
          algo)          ALGO="$val" ;;
          pathfile)      PATHFILE="$val" ;;
          output)        OUTPUT="$val" ;;
          hashes_dir)    HASHES_DIR="$val" ;;
          logs_dir)      LOGS_DIR="$val" ;;
          level)         LOG_LEVEL="$val" ;;
          interval|background-interval) PROGRESS_INTERVAL="$val" ;;
          # v1.3.22: sort CSV by path after hashing. Accepts true/false/1/0.
          sort_output|sort-output)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) SORT_OUTPUT="false" ;;
              1|true|yes|on)  SORT_OUTPUT="true"  ;;
              *)              : ;;  # ignore garbage, keep default
            esac
            ;;
          exclude)       EXTRA_EXCLUDES+=("$val") ;;
          __bare__)      : ;;
          *)             : ;;
        esac
        ;;
      "logging")
        case "$key" in
          level)         LOG_LEVEL="$val" ;;
          background-interval|interval) PROGRESS_INTERVAL="$val" ;;
          xtrace)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              1|true|yes|on) set -x ;;
            esac
            ;;
          *)             : ;;
        esac
        ;;
      "exclusions")
        case "$key" in
          inherit-defaults)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) DEFAULT_EXCLUDES=() ;;
              *)              : ;;
            esac
            ;;
          exclude)        EXTRA_EXCLUDES+=("$val") ;;
          __bare__)       EXTRA_EXCLUDES+=("$val") ;;
          *)              : ;;
        esac
        ;;
      "performance")
        case "$key" in
          # v1.2.0: parallel hashing worker count
          jobs|hash-jobs|hash_jobs) HASH_JOBS="$val" ;;
          *)                        : ;;
        esac
        ;;
      *) : ;;
    esac
  done < "$f"

  # reconcile paths after possible dir changes
  mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$VAR_DIR" "$ZERO_DIR"
  MAIN_LOG="$LOGS_DIR/hasher.log"
  RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
  FILES_LIST="$VAR_DIR/files-$RUN_ID.lst"
  BACKGROUND_LOG="$LOGS_DIR/background.log"

  # re-derive default OUTPUT if still using default pattern or blank
  if [[ -z "$OUTPUT" \
     || "$OUTPUT" == "$ROOT_DIR/hashes/hasher-$DATE_TAG.csv" \
     || "$OUTPUT" == "$ROOT_DIR/hashes/hasher-$CSV_TAG.csv" ]]; then
    OUTPUT="$HASHES_DIR/hasher-$CSV_TAG.csv"
  fi
}

# Apply config early (before arg parsing), if set
[[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"

# v1.3.17 (peer-review finding #5b): auto-load local/excludes.txt if present,
# so bin/hasher.sh from cron/CLI catalogues the SAME set as menu runs. The
# launcher used to translate that file into a series of --exclude flags but
# hasher.sh itself never read it — direct invocations produced a different
# manifest. This inheritance is silent (no warning if the file is absent).
if [[ -f "$ROOT_DIR/local/excludes.txt" ]]; then
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # skip blank lines and #-comments
    _stripped="${_line#"${_line%%[![:space:]]*}"}"
    [[ -z "$_stripped" ]] && continue
    case "$_stripped" in \#*) continue ;; esac
    EXTRA_EXCLUDES+=("$_stripped")
  done < "$ROOT_DIR/local/excludes.txt"
fi

# ───────────────────────── Arg Parsing ─────────────────────
usage() {
  cat <<EOF
Usage: $0 [--pathfile FILE] [--algo sha256] [--output CSV]
          [--nohup] [--level info|warn|error] [--interval SECONDS]
          [--exclude PATTERN ...] [--zero-length-only] [--config FILE] [--help]

Options:
  --pathfile FILE    File containing one path (dir or file) per line. Required unless paths are piped.
  --algo ALG         Hash algorithm (default: sha256; the only supported value in this release).
  --output CSV       Output CSV path (default: $OUTPUT).
  --nohup            Re-exec under nohup (background) with logs to $BACKGROUND_LOG.
  --level LEVEL      Log level threshold (info|warn|error). Default: info.
  --interval N       Progress update interval seconds (default: $PROGRESS_INTERVAL).
  --exclude P        Extra exclude pattern(s). Repeatable. Case-insensitive glob:
                     * matches any run of chars, ? matches one; a pattern with '/'
                     matches the full path, else the basename; a pattern with no
                     glob metacharacters matches as a literal substring against
                     the full path (so "#recycle", "@eaDir" still work).
  --zero-length-only Scan and output zero-length file list only, then exit (no hashing).
  --config FILE      Load settings from FILE (default: local/hasher.conf if present).
  --help             Show this help.

Behavior:
  * Writes CSV with header to: \$OUTPUT (unless --zero-length-only)
  * Logs: $MAIN_LOG (global), $RUN_LOG (per run), progress to $BACKGROUND_LOG
  * Working files: $VAR_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pathfile) PATHFILE="${2:-}"; shift ;;
    --algo)     ALGO="${2:-}"; shift ;;
    --output)   OUTPUT="${2:-}"; shift ;;
    --append)   APPEND_MANIFEST=1 ;;   # v1.3.16: explicit opt-in to extend an existing CSV
    --nohup)    RUN_IN_BACKGROUND=true ;;
    --level)    LOG_LEVEL="${2:-}"; shift ;;
    --interval) PROGRESS_INTERVAL="${2:-}"; shift ;;
    # v1.3.22: opt out of CSV sorting for this one run.
    --no-sort)  SORT_OUTPUT="false" ;;
    --sort)     SORT_OUTPUT="true"  ;;
    --jobs)     HASH_JOBS="${2:-1}"; shift ;;
    --exclude)  EXTRA_EXCLUDES+=("${2:-}"); shift ;;
    --zero-length-only) ZERO_LENGTH_ONLY=true ;;
    --config)   CONFIG_FILE="${2:-}"; shift ;;
    --child)    IS_CHILD=true ;;
    -h|--help)  usage; exit 0 ;;
    *) error "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# ───────────────────────── Nohup Re-exec ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  export IS_CHILD=true
  # v1.3.17 (review finding #1b): unset the session-leader guard so the
  # spawned child re-runs the setsid decision at its own top-of-file and
  # becomes ITS OWN session leader. Previously the child inherited
  # HASHER_SESSION_LEADER=1 and skipped the re-exec, so its group-signal
  # would target the parent shell's PGID instead of an isolated group.
  unset HASHER_SESSION_LEADER
  args=( "$0" --child )
  [[ -n "$CONFIG_FILE" ]] && args+=( --config "$CONFIG_FILE" )
  [[ -n "$PATHFILE"   ]] && args+=( --pathfile "$PATHFILE" )
  args+=( --algo "$ALGO" --output "$OUTPUT" --level "$LOG_LEVEL" --interval "$PROGRESS_INTERVAL" --jobs "$HASH_JOBS" )
  # FIX (v1.1.10): "${arr[@]}" on an empty array errors under set -u in
  # bash 3.2 (Apple's stock /bin/bash) and 4.0–4.3. The :- guard is the
  # portable form for safe-on-empty array iteration. Same fix as line ~425.
  for ex in "${EXTRA_EXCLUDES[@]:-}"; do
    [[ -n "$ex" ]] && args+=( --exclude "$ex" )
  done
  $ZERO_LENGTH_ONLY && args+=( --zero-length-only )

  nohup "${args[@]}" >>"$BACKGROUND_LOG" 2>&1 < /dev/null &
  bgpid=$!
  echo "Hasher started with nohup (PID $bgpid). Output: ${ZERO_LENGTH_ONLY:+(zero-length-only mode) }$OUTPUT"
  exit 0
fi

# ───────────────────────── Hash Tool Map ───────────────────
# v1.3.16 (peer-review finding #2): The plan format used by find-duplicates.sh,
# review-duplicates.sh, auto-dedup.sh and delete-duplicates.sh only recognises
# a 64-hex SHA-256 hash. An MD5 plan (32 hex), SHA-1 (40), SHA-512/BLAKE2 (128)
# would have their hash silently absorbed into the file path during apply, so
# nothing gets re-verified or acted on. Rather than plumb the algorithm through
# every downstream tool (a larger cross-cutting change), be honest about what
# the tool actually supports: restrict hashing to SHA-256 and reject other
# algorithms up front so no misleading CSVs or unworkable plans are produced.
# The `--algo` option is retained for backwards-compatible invocations that
# pass `--algo sha256` explicitly, and to give a clear error for anything else.
case "$ALGO" in
  sha256) : ;;
  sha1|sha512|md5|blake2)
    error "algo '$ALGO' is not supported for dedup workflows in this release."
    error "Downstream tools (find-duplicates, review-duplicates, delete-duplicates)"
    error "only understand SHA-256. Re-run with --algo sha256 (the default)."
    exit 2
    ;;
  *)
    error "Unknown algo '$ALGO'. Supported: sha256."
    exit 2
    ;;
esac

# Use platform-aware resolver (supports both GNU and BSD/macOS toolchains)
hash_cmd_str="$(_resolve_hash_cmd "$ALGO")"
if [[ -z "$hash_cmd_str" ]]; then
  case "$ALGO" in
    blake2) error "blake2 requested but 'b2sum' not found in PATH"; exit 1 ;;
    *)      error "No hash tool found for algo '$ALGO' (tried sha256sum, shasum, md5sum, md5)"; exit 1 ;;
  esac
fi
# Split into array so multi-word commands (e.g. "shasum -a 256") work correctly
read -ra hash_cmd <<< "$hash_cmd_str"
# Verify the resolved command is actually callable
command -v "${hash_cmd[0]}" >/dev/null 2>&1 || { error "Hash tool '${hash_cmd[0]}' not found in PATH"; exit 1; }

# ───────────────────────── Build File List ─────────────────
build_file_list() {
  : > "$FILES_LIST"
  local had_input=false

  # v1.3.21 (Mary's Mac report): during discovery, `find` can walk for
  # many minutes on a large external drive with no visible activity — the
  # background log stays frozen at "[INFO] Working dir: ..." and users
  # tailing the log cannot tell a slow-but-alive walk from a hang.
  # Fix: start a lightweight heartbeat that writes to $BACKGROUND_LOG
  # every $PROGRESS_INTERVAL seconds (default 15s), reporting how many
  # candidates have been discovered so far. The heartbeat is stopped as
  # soon as build_file_list finishes; if it fails to start (unlikely) the
  # walk still completes correctly, just quietly.
  #
  # We deliberately DON'T use bglog here because that function timestamps
  # the RUN_ID prefix consistently with other entries; the heartbeat uses
  # the same format so tailers see one uniform stream.
  local walk_hb_pid=0
  local walk_start_ts
  walk_start_ts=$(date +%s)
  if [[ -n "${BACKGROUND_LOG:-}" ]] && [[ "${PROGRESS_INTERVAL:-15}" -gt 0 ]]; then
    (
      # Subshell inherits set -Eeuo pipefail — use `|| true` on anything
      # that could legitimately return non-zero (empty tmp file, missing
      # FILES_LIST during first tick, etc.) so the heartbeat never dies
      # from a routine miss.
      local hb_interval="${PROGRESS_INTERVAL:-15}"
      while :; do
        sleep "$hb_interval" || break
        local hb_now hb_elapsed hb_seen=0
        hb_now=$(date +%s)
        hb_elapsed=$(( hb_now - walk_start_ts ))
        # Count NUL-delimited entries collected so far in the working list.
        # $FILES_LIST.tmp is where find output accumulates before exclusion
        # filtering. Empty/missing => 0 (first tick, or filter has moved on).
        if [[ -s "$FILES_LIST".tmp ]]; then
          hb_seen=$(tr -cd '\0' < "$FILES_LIST".tmp 2>/dev/null | wc -c 2>/dev/null | tr -d ' ' || echo 0)
        elif [[ -s "$FILES_LIST" ]]; then
          # Post-filter path already produced; still worth reporting.
          hb_seen=$(tr -cd '\0' < "$FILES_LIST" 2>/dev/null | wc -c 2>/dev/null | tr -d ' ' || echo 0)
        fi
        printf '[%s] [RUN %s] [PROGRESS] Walking paths: %s file(s) discovered so far | elapsed=%02d:%02d:%02d\n' \
          "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "${hb_seen:-0}" \
          $((hb_elapsed/3600)) $((hb_elapsed%3600/60)) $((hb_elapsed%60)) \
          >> "$BACKGROUND_LOG" 2>/dev/null || true
      done
    ) &
    walk_hb_pid=$!
  fi
  # Ensure the heartbeat is killed on ANY exit from this function —
  # normal completion, error, or trap. The inline stop at the end of the
  # function is the normal path; this trap is belt-and-braces so a bail-out
  # from `error \"...\"; exit N` inside build_file_list doesn't leave the
  # emitter running as an orphan writing to a log file the parent has
  # closed. RETURN pseudo-signal fires when the function returns or exits.
  _stop_walk_hb() {
    if [[ "${walk_hb_pid:-0}" -gt 0 ]] && kill -0 "$walk_hb_pid" 2>/dev/null; then
      kill "$walk_hb_pid" 2>/dev/null || true
      wait "$walk_hb_pid" 2>/dev/null || true
    fi
    walk_hb_pid=0
  }
  trap '_stop_walk_hb' RETURN

  # v1.3.20 (Mary's Mac Tahoe report): compute host-specific find-prune
  # args ONCE and apply them to every find below. On macOS this prunes
  # .Spotlight-V100, .DocumentRevisions-V100, etc. so BSD find no longer
  # exits 1 when it can't descend into permission-restricted system dirs.
  # On Synology this prunes @eaDir which massively speeds up media-volume
  # walks. On generic Linux the array is empty and find behaves normally.
  #
  # v1.3.20 patch: Bash 3.2 (macOS stock) treats empty arrays as UNSET
  # under `set -u`, so we (a) collect into a temp file rather than a
  # process substitution (which the 3.2 array-assignment quirk breaks
  # differently), and (b) always expand as "${arr[@]:-}" at use sites.
  # The 3.2 `arr=()` declaration alone can leave the array unset; the
  # portable idiom is to seed a placeholder and then rebuild.
  local prune_args
  prune_args=()
  if command -v host_find_prune_args >/dev/null 2>&1; then
    local _prune_tmp="$VAR_DIR/prune-args.$$"
    host_find_prune_args > "$_prune_tmp" 2>/dev/null || true
    if [[ -s "$_prune_tmp" ]]; then
      while IFS= read -r _a || [[ -n "$_a" ]]; do
        [[ -n "$_a" ]] && prune_args[${#prune_args[@]}]="$_a"
      done < "$_prune_tmp"
    fi
    rm -f -- "$_prune_tmp" 2>/dev/null || true
  fi

  # FIX (v1.1.10): track how many pathfile entries actually resolved to
  # something on disk. Previously, if every path in paths.txt was missing
  # (e.g. the external disk wasn't mounted), each one warned, the script
  # continued, found 0 files post-exclude, and reported "Hashed 0/0" as
  # if it had succeeded. That looked like a hang or a silent failure.
  # We now exit non-zero with a clear message when no paths were valid.
  local pathfile_seen=0     # non-blank, non-comment lines in paths.txt
  local pathfile_valid=0    # of those, how many were a readable dir or file

  if [[ -n "$PATHFILE" ]]; then
    if [[ ! -r "$PATHFILE" ]]; then
      error "Cannot read --pathfile '$PATHFILE'"; exit 1
    fi
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      # v1.3.20: strip trailing CR before anything else. A paths.txt saved
      # from a Windows editor, or copy-pasted from a web page, can carry
      # CRLF line endings; `read` strips the LF but leaves the CR glued to
      # the last field. `[[ -d "/Volumes/Photo-Disk/\r" ]]` fails silently,
      # producing the "All N paths missing" error even though the path is
      # perfectly valid. Do this BEFORE whitespace trimming so we don't
      # care whether the CR sits mid-run or at the end.
      raw="${raw%$'\r'}"
      local path="${raw#"${raw%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
      [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
      # v1.3.20: strip matched surrounding quotes. The example line in the
      # default paths.txt shows a single-quoted style (`'/volume1/Media'`),
      # so users copying that pattern end up with quoted entries; the
      # previous parser treated the quotes as part of the pathname and
      # every entry failed the [[ -d ]] check. Strip a single matched pair
      # of leading/trailing quotes (single OR double); mismatched quotes
      # are left alone so a legitimately-quoted-only-on-one-side pathname
      # is still surfaced as "does not exist" rather than silently altered.
      case "$path" in
        \'*\')  path="${path#\'}"; path="${path%\'}" ;;
        \"*\")  path="${path#\"}"; path="${path%\"}" ;;
      esac
      pathfile_seen=$((pathfile_seen + 1))
      if [[ -d "$path" ]]; then
        # v1.1.11 catch reworked in v1.3.20 (Mary's Mac Tahoe report):
        # `find` returns exit 1 whenever ANY subtree is unreadable, even if
        # the rest of the walk produced thousands of files. On macOS this
        # is the norm, not an error: every external volume has system dirs
        # like .DocumentRevisions-V100 / .Spotlight-V100 / .TemporaryItems /
        # .Trashes with restrictive modes (d--x--x--x etc). The v1.1.11
        # code treated ANY non-zero as fatal and skipped the whole root —
        # so a valid external drive with a single permission-denied system
        # dir produced "All 1 path(s) missing or unreadable" and hashed
        # nothing.
        #
        # New policy: distinguish "root is unreachable" (fatal) from "some
        # subtree unreadable" (accept, warn, continue with what we got).
        #
        # A permission-denied subtree causes find to write to stderr
        # ("Permission denied"). We capture stderr to a temp file; if the
        # exit is non-zero AND stderr is empty, the ROOT itself is
        # unreachable (unmounted volume stub, I/O error at the top). If
        # stderr has content, it's just per-subtree noise — we accept the
        # partial results and let the operator know how many were skipped.
        local find_status=0
        local find_err="$FILES_LIST.finderr.$$"
        # v1.3.20 patch: bash 3.2 (macOS stock) expands "${arr[@]:-}" as a
        # SINGLE EMPTY ARGUMENT when the array is empty, which would break
        # find. Branch explicitly instead — a tiny amount of duplication
        # is safer than a subtle cross-version quirk.
        if [[ ${#prune_args[@]} -gt 0 ]]; then
          find "$path" "${prune_args[@]}" -type f -print0 2>"$find_err" || find_status=$?
        else
          find "$path" -type f -print0 2>"$find_err" || find_status=$?
        fi
        if [[ "$find_status" -eq 0 ]]; then
          pathfile_valid=$((pathfile_valid + 1))
        else
          # count Permission-denied lines (BSD find and GNU find both use
          # the same English text at the end of the line)
          local deny_count=0
          [[ -s "$find_err" ]] && deny_count=$(grep -c 'Permission denied' "$find_err" 2>/dev/null || true)
          local other_err=$(( $(wc -l < "$find_err" 2>/dev/null || echo 0) - deny_count ))
          if (( deny_count > 0 && other_err <= 0 )); then
            # Only permission-denied noise — treat root as valid, partial walk.
            warn "'$path': $deny_count subtree(s) skipped (permission denied on system dirs). Continuing with the rest."
            pathfile_valid=$((pathfile_valid + 1))
          else
            # Root itself is unreachable, or some other error class.
            warn "find failed on '$path' (exit $find_status)."
            [[ -s "$find_err" ]] && warn "  first find error: $(head -n1 "$find_err")"
            warn "  possibly an unmounted volume stub. Skipping this root."
          fi
        fi
        rm -f -- "$find_err" 2>/dev/null || true
      elif [[ -f "$path" ]]; then
        printf '%s\0' "$path"
        pathfile_valid=$((pathfile_valid + 1))
      else
        warn "Path does not exist: $path"
      fi
    done < "$PATHFILE" >> "$FILES_LIST".tmp
    had_input=true
  fi

  # If stdin is a pipe, accept paths (NUL- or newline-delimited).
  #
  # v1.3.18 (peer-review finding #5):
  #   a) Only set had_input=true if stdin actually delivered at least one
  #      record. Previously any non-TTY stdin — including `hasher.sh </dev/null`
  #      or a pipe that turned out to be empty — flipped had_input to true,
  #      producing a successful "Hashed 0/0 files" run with a header-only CSV.
  #      Empty input should be a clean error, not a fake success.
  #   b) Apply the SAME expansion to piped paths that the --pathfile branch
  #      applies. Previously a piped directory was written verbatim to the
  #      files list; the hash worker then failed to hash the directory and
  #      the run "succeeded" with a failure count. Piped directories are
  #      now recursively walked with find; piped files are added directly;
  #      piped non-existent paths warn but don't abort.
  # v1.3.20 (peer-review recheck additional observation): if --pathfile was
  # supplied, don't consume stdin. Previously `cat > tmp_in` blocked on ANY
  # non-TTY stdin, even when the operator had explicitly given a pathfile.
  # A long-lived pipe, SSH parent shell, or orchestration wrapper could
  # make hasher appear to hang indefinitely. If both are given, --pathfile
  # wins; stdin is left alone.
  if [ ! -t 0 ] && [[ -z "$PATHFILE" ]]; then
    local tmp_in="$FILES_LIST.stdin.tmp"
    cat > "$tmp_in"
    if [[ ! -s "$tmp_in" ]]; then
      rm -f -- "$tmp_in" 2>/dev/null || true
    else
      had_input=true
      # Decide NUL- vs newline-delimited by peeking for a NUL in the first record
      local _delim='\n'
      if IFS= read -r -d '' _peek < "$tmp_in" 2>/dev/null && [[ -n "$_peek" ]]; then
        _delim='\0'
      fi
      # Emit each incoming path through the same expansion policy as --pathfile
      local stdin_seen=0 stdin_valid=0
      if [[ "$_delim" = '\0' ]]; then
        while IFS= read -r -d '' path || [[ -n "$path" ]]; do
          [[ -z "$path" ]] && continue
          stdin_seen=$((stdin_seen + 1))
          if [[ -d "$path" ]]; then
            local _fs=0
            if [[ ${#prune_args[@]} -gt 0 ]]; then
              find "$path" "${prune_args[@]}" -type f -print0 2>/dev/null || _fs=$?
            else
              find "$path" -type f -print0 2>/dev/null || _fs=$?
            fi
            [[ "$_fs" -eq 0 ]] && stdin_valid=$((stdin_valid + 1)) \
              || warn "find failed on piped path '$path' (exit $_fs) — skipping"
          elif [[ -f "$path" ]]; then
            printf '%s\0' "$path"
            stdin_valid=$((stdin_valid + 1))
          else
            warn "Piped path does not exist: $path"
          fi
        done < "$tmp_in" >> "$FILES_LIST".tmp
      else
        while IFS= read -r path || [[ -n "$path" ]]; do
          # v1.3.20: strip trailing CR (see pathfile-loop comment above)
          path="${path%$'\r'}"
          [[ -z "$path" ]] && continue
          stdin_seen=$((stdin_seen + 1))
          if [[ -d "$path" ]]; then
            local _fs=0
            if [[ ${#prune_args[@]} -gt 0 ]]; then
              find "$path" "${prune_args[@]}" -type f -print0 2>/dev/null || _fs=$?
            else
              find "$path" -type f -print0 2>/dev/null || _fs=$?
            fi
            [[ "$_fs" -eq 0 ]] && stdin_valid=$((stdin_valid + 1)) \
              || warn "find failed on piped path '$path' (exit $_fs) — skipping"
          elif [[ -f "$path" ]]; then
            printf '%s\0' "$path"
            stdin_valid=$((stdin_valid + 1))
          else
            warn "Piped path does not exist: $path"
          fi
        done < "$tmp_in" >> "$FILES_LIST".tmp
      fi
      rm -f -- "$tmp_in" 2>/dev/null || true
      if [[ "$stdin_seen" -gt 0 && "$stdin_valid" -eq 0 ]]; then
        error "All $stdin_seen piped path(s) are missing or unreadable."
        exit 3
      fi
    fi
  fi

  if ! $had_input; then
    error "No input paths provided. Use --pathfile or pipe paths."; exit 2
  fi

  # FIX (v1.1.10): fail loudly when paths.txt was provided but every path
  # listed in it is missing or unreadable. Stdin-piped invocations bypass
  # this check (we can't tell a legitimately-empty stream from an
  # all-missing one, and stdin is the advanced path).
  if [[ "$pathfile_seen" -gt 0 && "$pathfile_valid" -eq 0 ]]; then
    error "All $pathfile_seen path(s) listed in '$PATHFILE' are missing or unreadable."
    error "Common causes: external drive not mounted, typo in volume name, NAS share not connected."
    error "Check 'ls /Volumes' (macOS), 'ls /mnt' or 'ls /media' (Linux), or 'ls /volume1' (Synology)."
    exit 3
  fi

  local pre_count=0
  [[ -s "$FILES_LIST".tmp ]] && pre_count=$(tr -cd '\0' < "$FILES_LIST".tmp | wc -c | tr -d ' ')

  # v1.3.17 (peer-review finding #3): filenames containing tab, newline, or
  # carriage return break the downstream line- and TAB-oriented artefacts
  # (CSV manifest, TSV signatures, KEEP|/DEL| plans). Previously
  # find-duplicates.sh silently rewrote tabs to spaces, so the report/plan
  # referenced a DIFFERENT path than the file on disk — dedup could then
  # act on the wrong file. Policy: DETECT AND SKIP these paths at discovery
  # with a prominent report. Users see the exact skipped paths in
  # var/skipped-delimiter-paths.log for follow-up (rename, or manual hash).
  # A NUL-delimited internal manifest is the fuller fix; that's a future
  # cross-cutting change. Detection is done in awk on NUL records so tabs
  # and newlines inside a record are visible.
  local skipfile="$VAR_DIR/skipped-delimiter-paths.log"
  local skipped_delim=0
  if [[ -s "$FILES_LIST".tmp ]]; then
    # v1.3.19 (peer-review finding #1): route through the lib helper so the
    # bash fallback runs automatically on hosts (BusyBox/DSM) whose awk
    # cannot handle RS='\0' correctly. Same semantics as before.
    hasher_nul_filter_delim "$FILES_LIST".tmp "$skipfile" > "$FILES_LIST".tmp.clean \
      && mv -f -- "$FILES_LIST".tmp.clean "$FILES_LIST".tmp
    skipped_delim=$(wc -l < "$skipfile" 2>/dev/null | tr -d ' ')
    if [[ "${skipped_delim:-0}" -gt 0 ]]; then
      warn "Skipping $skipped_delim file(s) whose paths contain TAB/LF/CR — see $skipfile"
      warn "  These characters break the CSV/TSV/plan artefacts. Rename the files to include them."
      pre_count=$((pre_count - skipped_delim))
    else
      rm -f -- "$skipfile" 2>/dev/null || true
    fi
  fi

  # Apply excludes (literal substring match)
  # FIX (v1.1.10): "${EXTRA_EXCLUDES[@]}" raises 'unbound variable' under
  # set -u on bash 3.2 (Apple stock /bin/bash, Synology DSM) when the
  # array is empty, even though the array IS declared at top of file.
  # The :- guard makes empty-array expansion safe. The trailing filter
  # then drops the empty-string sentinel that the :- expansion produces.
  local raw_patterns=("${DEFAULT_EXCLUDES[@]:-}" "${EXTRA_EXCLUDES[@]:-}")
  local patterns=()
  for _p in "${raw_patterns[@]}"; do
    [[ -n "$_p" ]] && patterns+=("$_p")
  done
  if (( ${#patterns[@]} > 0 )); then
    # v1.3.18 (peer-review finding #2): implement the DOCUMENTED semantics
    # v1.3.19 (peer-review finding #1): route through the lib helper. The
    # implementation lives in lib/awk-detect.sh with matching awk and bash
    # fallback code paths, auto-selected based on the local awk's NUL
    # support. Documented semantics:
    #   * `*` matches any run of characters (including empty)
    #   * `?` matches exactly one character
    #   * matching is case-insensitive
    #   * a pattern containing `/` matches against the FULL path;
    #     otherwise it matches against the basename (last path component)
    #   * a pattern with no glob metacharacters matches as a case-
    #     insensitive literal substring against the FULL PATH — preserves
    #     the pre-v1.3.18 behaviour of "#recycle" / "@eaDir"
    #
    # v1.3.16 (finding #1): NUL delimiter preserved; no fallback that
    # restores excluded items.
    hasher_nul_filter_globs "$FILES_LIST".tmp "${patterns[@]}" > "$FILES_LIST"
  else
    mv -f -- "$FILES_LIST".tmp "$FILES_LIST"
  fi

  local post_count=0
  [[ -s "$FILES_LIST" ]] && post_count=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
  # v1.3.16 (peer-review finding #1): removed the "restore unfiltered list"
  # fallback. If exclusions legitimately remove every candidate, the honest
  # outcome is "no files remain after exclusions" — NOT to silently re-include
  # everything the user asked to skip. If pre_count > 0 and post_count == 0
  # after filtering, log it plainly; hasher.sh's main loop already handles the
  # "no files to hash" case with a clean successful exit.
  if (( pre_count > 0 && post_count == 0 && ${#patterns[@]} > 0 )); then
    info "All $pre_count candidate(s) matched exclusion patterns; nothing to hash this run."
  fi

  # v1.3.21: stop the walk heartbeat cleanly before the function returns.
  # The RETURN trap above is the belt-and-braces safety net; this is the
  # normal path.
  _stop_walk_hb

  rm -f -- "$FILES_LIST".tmp 2>/dev/null || true
}

# ───────────────────────── CSV Helpers ─────────────────────
csv_escape() { local s="$1"; s="${s//\"/\"\"}"; printf '"%s"' "$s"; }

write_csv_header() {
  local f="$OUTPUT"
  local dir; dir="$(dirname "$f")"
  mkdir -p "$dir"
  # v1.3.16 (peer-review finding #3): refuse to append to an existing manifest.
  # Previously an existing non-empty CSV was silently kept and rows were
  # appended — two runs in the same minute merged into one file. Now: if the
  # output exists and is non-empty, fail loudly. --append is provided as an
  # explicit opt-in for the (rare) case of resuming or extending a manifest.
  if [[ -e "$f" && -s "$f" && "${APPEND_MANIFEST:-0}" != "1" ]]; then
    error "Output CSV already exists and is non-empty: $f"
    error "Refusing to append silently (would merge runs). Options:"
    error "  - Wait a second and re-run (default name includes seconds + PID since v1.3.16)"
    error "  - Pass --output PATH to name a fresh file"
    error "  - Pass --append to deliberately extend the existing manifest"
    exit 2
  fi
  if [[ ! -e "$f" || ! -s "$f" ]]; then
    printf 'path,size_bytes,mtime_epoch,algo,hash\n' > "$f"
    return
  fi
  local first; first="$(head -n1 "$f" 2>/dev/null || echo)"
  if [[ "$first" != "path,size_bytes,mtime_epoch,algo,hash" ]]; then
    local tmp="$f.tmp.$$"
    { printf 'path,size_bytes,mtime_epoch,algo,hash\n'; cat "$f"; } > "$tmp" && mv -f -- "$tmp" "$f"
  fi
}

# v1.3.13 (recheck item 10): removed unused append_csv_row() — CSV rows are
# written inline in the hashing worker path; the helper was never called.

# ───────────────────────── Progress Tickers ────────────────
T_START=0
hash_progress_pid=0
zero_progress_pid=0
ZERO_PROGRESS_FILE=""

start_hash_progress() {
  T_START=$(date +%s)
  (
    local total=0
    if [[ -s "$FILES_LIST" ]]; then
      total=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
    fi
    while :; do
      sleep "$PROGRESS_INTERVAL" || break
      local now elapsed rows done eta pct
      now=$(date +%s)
      elapsed=$(( now - T_START ))
      if [[ -f "$OUTPUT" ]]; then
        rows=$(wc -l < "$OUTPUT" | tr -d ' ')
        if (( rows > 1 )); then done=$(( rows - 1 )); else done=0; fi
      else
        done=0
      fi
      if (( total > 0 )); then
        pct=$(( done * 100 / total ))
        if (( done > 0 && done < total )); then
          eta=$(( elapsed * (total - done) / done ))
        else
          eta=0
        fi
      else
        pct=0; eta=0
      fi
      printf '[%s] [RUN %s] [PROGRESS] Hashing: [%s%%] %s/%s | elapsed=%02d:%02d:%02d (%s) eta=%02d:%02d:%02d (%s)\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$done" "$total" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        "$(human_dur "$elapsed")" \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) \
        "$(human_dur "$eta")" >> "$BACKGROUND_LOG"
    done
  ) &
  hash_progress_pid=$!
}

stop_hash_progress() {
  if [[ "$hash_progress_pid" -gt 0 ]] && kill -0 "$hash_progress_pid" 2>/dev/null; then
    kill "$hash_progress_pid" 2>/dev/null || true
    wait "$hash_progress_pid" 2>/dev/null || true
  fi
}

start_zero_progress() {
  T_START=$(date +%s)
  # FIX: ZERO_PROGRESS_FILE moved from logs/ to var/ — it's a transient counter, not a log
  ZERO_PROGRESS_FILE="$VAR_DIR/zero-scan-$RUN_ID.count"
  echo 0 > "$ZERO_PROGRESS_FILE"
  (
    local total=0 count=0 now elapsed eta pct
    if [[ -s "$FILES_LIST" ]]; then
      total=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
    fi
    while :; do
      sleep "$PROGRESS_INTERVAL" || break
      [[ -f "$ZERO_PROGRESS_FILE" ]] && count="$(cat "$ZERO_PROGRESS_FILE" 2>/dev/null || echo 0)" || count=0
      now=$(date +%s)
      elapsed=$(( now - T_START ))
      if (( total > 0 )); then
        pct=$(( count * 100 / total ))
        if (( count > 0 && count < total )); then
          eta=$(( elapsed * (total - count) / count ))
        else
          eta=0
        fi
      else
        pct=0; eta=0
      fi
      printf '[%s] [RUN %s] [PROGRESS] Zero-scan: [%s%%] %s/%s | elapsed=%02d:%02d:%02d (%s) eta=%02d:%02d:%02d (%s)\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$count" "$total" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        "$(human_dur "$elapsed")" \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) \
        "$(human_dur "$eta")" >> "$BACKGROUND_LOG"
    done
  ) &
  zero_progress_pid=$!
}

stop_zero_progress() {
  if [[ "$zero_progress_pid" -gt 0 ]] && kill -0 "$zero_progress_pid" 2>/dev/null; then
    kill "$zero_progress_pid" 2>/dev/null || true
    wait "$zero_progress_pid" 2>/dev/null || true
  fi
  [[ -n "$ZERO_PROGRESS_FILE" ]] && rm -f -- "$ZERO_PROGRESS_FILE" 2>/dev/null || true
}

cleanup() {
  stop_hash_progress
  stop_zero_progress
  # Clean up any leftover working files for this run
  rm -f -- "$FILES_LIST" "$FILES_LIST.tmp" "$FILES_LIST.stdin.tmp" 2>/dev/null || true
  # v1.3.3: hasher.sh now OWNS its pidfile. Remove it on exit (any exit:
  # success, error, or signal) so the duplicate-run guard reflects reality.
  # Only remove it if it still holds OUR pid — avoids deleting a pidfile a
  # newer run may have written if PIDs were somehow reused.
  # v1.3.20 (recheck finding #2): if _stop_group detected surviving
  # descendants, refuse to release the lock or pidfile — leaving them in
  # place blocks a fresh run from starting alongside the orphans. Operator
  # cleanup is required (the [ERROR] message above tells them how).
  if [[ "${HASHER_STOP_INCOMPLETE:-0}" = "1" ]]; then
    return
  fi
  if [ -n "${HASHER_PIDFILE:-}" ] && [ -f "$HASHER_PIDFILE" ]; then
    _pf="$(cat "$HASHER_PIDFILE" 2>/dev/null || true)"
    [ "$_pf" = "$$" ] && rm -f -- "$HASHER_PIDFILE" 2>/dev/null || true
  fi
  # v1.3.16 (finding #3): release our lockdir if we still hold it.
  if [ -n "${HASHER_LOCKDIR:-}" ] && [ -d "$HASHER_LOCKDIR" ]; then
    _lp="$(cat "$HASHER_LOCKDIR/pid" 2>/dev/null || true)"
    [ "$_lp" = "$$" ] && rm -rf -- "$HASHER_LOCKDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# v1.3.16 (peer-review finding #4): TERM/INT traps now signal the entire
# process group so xargs, worker shells and hash commands all go down with
# the parent. `kill -TERM -$$` targets pgid == our pid (we became the session
# leader at startup via setsid). Wait briefly for descendants to exit before
# cleanup so we don't remove files the workers are still writing to.
_stop_group() {
  # v1.3.19 (peer-review finding #2): CRITICAL — do NOT run `kill -TERM -$$`
  # inside our own handler. That signals every member of our process group,
  # which INCLUDES us — bash terminates this handler at the kill line,
  # skipping the wait/KILL escalation and the descendant verification.
  #
  # v1.3.20 (recheck finding #2): the v1.3.19 handler enumerated group
  # members with pgrep. On hosts without pgrep, `pgrep -g $$` returned the
  # empty string, no signals were sent, `_n=0` looked like success, and
  # cleanup ran while workers were still alive. `pgrep` is now still
  # preferred, but we ALSO have a portable ps-based fallback (below) that
  # works on any POSIX ps with -o support (DSM's BusyBox ps, macOS BSD ps,
  # GNU procps). If BOTH are unavailable, hasher.sh refuses to start (see
  # startup probe further up). Enumeration cannot silently return empty.
  #
  # First, reset the trap so nothing re-enters this handler.
  trap - TERM INT

  local _survivors _i
  if [[ "${IS_SESSION_LEADER:-0}" = "1" ]]; then
    # Signal every group member except ourselves
    _survivors="$(_enum_group_pids $$)"
    for _pid in $_survivors; do kill -TERM "$_pid" 2>/dev/null || true; done
  else
    # No session isolation: walk our descendant tree
    _kill_descendants_term $$
  fi

  # Give descendants up to ~3s to exit cleanly
  _i=0
  while [[ $_i -lt 30 ]]; do
    local _n=0
    if [[ "${IS_SESSION_LEADER:-0}" = "1" ]]; then
      _n="$(_enum_group_pids $$ | wc -l | tr -d ' ')"
    else
      _n="$(_count_descendants $$)"
    fi
    [[ "${_n:-0}" -eq 0 ]] && break
    sleep 0.1; _i=$((_i+1))
  done

  # Anything still up gets KILLed — again, excluding $$
  if [[ "${IS_SESSION_LEADER:-0}" = "1" ]]; then
    _survivors="$(_enum_group_pids $$)"
    for _pid in $_survivors; do kill -KILL "$_pid" 2>/dev/null || true; done
  else
    _kill_descendants_kill $$
  fi

  # v1.3.20 (recheck additional observation): give the kernel a moment to
  # reap the KILLed processes before we check for survivors. Otherwise on
  # a busy host the verification below can catch descendants that are
  # already dying and print a scary "descendants survived" warning even
  # though the shutdown was clean.
  sleep 0.5

  # Verify — if descendants are STILL alive, warn the caller so they know
  # the lock/pidfile removal that follows may be premature.
  # v1.3.20: also refuse to release the lock in that case — safer to leave
  # the lock in place than to let a new run start alongside orphans.
  local _still
  if [[ "${IS_SESSION_LEADER:-0}" = "1" ]]; then
    _still="$(_enum_group_pids $$ | wc -l | tr -d ' ')"
  else
    _still="$(_count_descendants $$)"
  fi
  if [[ "${_still:-0}" -gt 0 ]]; then
    printf '[ERROR] %d descendant(s) survived KILL escalation.\n' "$_still" >&2
    printf '[ERROR]   Investigate: ps -eo pid,pgid,cmd | awk "\$2==%d"\n' "$$" >&2
    printf '[ERROR]   Lock/pidfile will NOT be released — clean up manually.\n' >&2
    export HASHER_STOP_INCOMPLETE=1
  fi
}

# ── v1.3.20 (peer-review recheck finding #2) — process enumeration helpers ──
# Every stop-path branch needs a reliable way to see our own group / child
# processes. Previously used only `pgrep`, but pgrep is not universally
# present (BusyBox builds ship without it; macOS has it, DSM depends on
# package). Order of preference:
#   1) pgrep  (fastest, exact semantics)
#   2) ps -eo pid=,pgid=,ppid=  (POSIX-ish, present on every target we care
#      about — DSM BusyBox, macOS BSD, GNU procps)
# If BOTH are absent (extremely rare — busybox with ps applet stripped),
# the startup probe below aborts before main() runs so no worker ever
# escapes our reach.
#
# _enum_group_pids <pgid>       → PIDs in that group, one per line, excluding
#                                 the caller's own $$ (never signal self).
# _enum_children  <ppid>        → direct children of a given PPID.
_enum_group_pids() {
  local _pgid="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -g "$_pgid" 2>/dev/null | awk -v me="$$" '$1 != me' || true
  else
    # ps fallback. `-eo pid=,pgid=` prints two space-separated columns with
    # no header. Works identically on DSM BusyBox, macOS BSD, and procps.
    ps -eo pid=,pgid= 2>/dev/null \
      | awk -v pg="$_pgid" -v me="$$" '$2 == pg && $1 != me {print $1}'
  fi
}
_enum_children() {
  local _ppid="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$_ppid" 2>/dev/null || true
  else
    ps -eo pid=,ppid= 2>/dev/null | awk -v p="$_ppid" '$2 == p {print $1}'
  fi
}

# Descendant-walking helpers used in the no-setsid fallback path.
# v1.3.20: route through _enum_children so the ps-fallback is used when
# pgrep is unavailable.
_count_descendants() {
  local p="$1" c=0
  local kids; kids="$(_enum_children "$p")"
  for k in $kids; do
    c=$((c + 1 + $(_count_descendants "$k")))
  done
  printf '%s' "$c"
}
_kill_descendants_term() {
  local p="$1"
  local kids; kids="$(_enum_children "$p")"
  for k in $kids; do
    _kill_descendants_term "$k"
    kill -TERM "$k" 2>/dev/null || true
  done
}
_kill_descendants_kill() {
  local p="$1"
  local kids; kids="$(_enum_children "$p")"
  for k in $kids; do
    _kill_descendants_kill "$k"
    kill -KILL "$k" 2>/dev/null || true
  done
}
trap '_stop_group; cleanup; echo "[INFO] hashing stopped by signal (TERM)" >&2; exit 143' TERM
trap '_stop_group; cleanup; echo "[INFO] hashing stopped by signal (INT)"  >&2; exit 130' INT

# ───────────────────────── Main Hashing ────────────────────
TOTAL=0
DONE=0
FAIL=0

main() {
  # v1.3.16 (peer-review finding #3): acquire a concurrency lock BEFORE any
  # work, using an atomic mkdir on the lockdir. Previously the pidfile was
  # just overwritten with `printf > pidfile`, which is neither atomic nor a
  # lock — direct-CLI or cron invocations bypassed the launcher's guard and
  # could overlap freely. mkdir is atomic on every filesystem we care about
  # (ext4/btrfs on DSM, APFS on macOS) and needs no `flock` binary.
  # If the lockdir already exists: check whether its recorded PID is alive.
  # If alive → refuse to start. If stale (crashed run) → adopt the lock.
  mkdir -p "$VAR_DIR" 2>/dev/null || true
  local _lockdir="$VAR_DIR/hasher.lock"
  if ! mkdir "$_lockdir" 2>/dev/null; then
    local _lockpid=""
    [[ -f "$_lockdir/pid" ]] && _lockpid="$(cat "$_lockdir/pid" 2>/dev/null || true)"
    if [[ -n "$_lockpid" ]] && kill -0 "$_lockpid" 2>/dev/null; then
      error "Another hasher run is already active (PID $_lockpid)."
      error "Use the launcher's 'k) Stop hashing' to terminate it first, or"
      error "wait for it to finish. Lock: $_lockdir"
      exit 2
    fi
    warn "Stale lock at $_lockdir (PID ${_lockpid:-unknown} not running) — adopting."
    rm -rf -- "$_lockdir" 2>/dev/null || true
    mkdir "$_lockdir" 2>/dev/null || { error "Failed to acquire lock"; exit 2; }
  fi
  printf '%s\n' "$$" > "$_lockdir/pid" 2>/dev/null || true
  HASHER_LOCKDIR="$_lockdir"   # picked up by cleanup()

  # v1.3.3: also claim the pidfile (kept for launcher's is_hasher_running).
  printf '%s\n' "$$" > "$HASHER_PIDFILE" 2>/dev/null || true
  info "Run-ID: $RUN_ID"
  [[ -n "$CONFIG_FILE" ]] && info "Config file: $CONFIG_FILE"
  info "Config: ${PATHFILE:+pathfile=$PATHFILE} | Algo: $ALGO | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"
  info "Output CSV: $OUTPUT"
  info "Working dir: $VAR_DIR"
  $ZERO_LENGTH_ONLY && info "Mode: ZERO-LENGTH-ONLY (no hashing)"

  build_file_list

  if [[ -s "$FILES_LIST" ]]; then
    TOTAL=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
  else
    TOTAL=0
  fi
  info "Discovered $TOTAL files to scan (post-exclude)."

  # ───── Fast path: zero-length-only (no hashing) ──────────
  if $ZERO_LENGTH_ONLY; then
    # v1.3.20 (peer-review recheck finding #4): use the full run tag
    # (F-HMS-PID) rather than DATE_TAG. Previously two zero-length-only
    # scans on the same day overwrote each other's report while the
    # command printed to the operator still referenced that pathname —
    # so re-running the first command could act on the SECOND scan's
    # files. Mirror the normal-path convention: run-specific report +
    # -latest symlink for stable next-step references.
    local out="$ZERO_DIR/zero-length-$CSV_TAG.txt"
    local out_latest="$ZERO_DIR/zero-length-latest.txt"
    : > "$out"
    local n=0 m=0 nr=0
    local scanned=0

    bglog INFO "Zero-length-only scan starting: total=$TOTAL, report=$out"

    start_zero_progress
    while IFS= read -r -d '' f; do
      scanned=$((scanned+1)); echo "$scanned" > "$ZERO_PROGRESS_FILE"
      if [[ ! -e "$f" ]]; then
        m=$((m+1))
      elif [[ ! -f "$f" ]]; then
        nr=$((nr+1))
      elif [[ ! -s "$f" ]]; then
        echo "$f" >> "$out"
        n=$((n+1))
      fi
    done < "$FILES_LIST"
    stop_zero_progress

    info  "Zero-length-only scan complete."
    info  "  • Zero-length files now: $n"
    info  "  • Missing paths: $m | Not regular files: $nr"
    info  "  • Report: $out"

    # v1.3.20 (finding #4): keep zero-length-latest pointer aligned with
    # the run-tagged report, mirroring the normal-path behaviour.
    if ln -sfn -- "$(basename "$out")" "$out_latest" 2>/dev/null; then :; else
      cp -f -- "$out" "$out_latest" 2>/dev/null || true
    fi

    bglog INFO "Zero-length-only scan complete: zero=$n, missing=$m, not_regular=$nr, report=$out"
    bglog INFO "NEXT: Review (dry-run): bin/delete-zero-length.sh --report \"$out\" --dry-run"
    bglog INFO "NEXT: Delete: bin/delete-zero-length.sh --report \"$out\" --force"

    echo
    echo -e "${GREEN}[RECOMMENDED NEXT STEPS]${NC}"
    echo "  1) Review what would be affected (no changes made):"
    echo "       bin/delete-zero-length.sh --report \"$out\" --dry-run"
    echo "  2) Delete, or move to quarantine instead of deleting:"
    echo "       bin/delete-zero-length.sh --report \"$out\" --force"
    echo "       bin/delete-zero-length.sh --report \"$out\" --force --quarantine"
    echo
    return
  fi

  # ───── Normal hashing path ───────────────────────────────
  write_csv_header
  start_hash_progress

  local start_ts
  start_ts=$(date +%s)

  # PARALLEL HASHING (v1.2.0)
  # ─────────────────────────
  # HASH_JOBS controls worker parallelism. 1 = serial (identical to the
  # historical behaviour). >1 fans the file list out to N workers via xargs,
  # each doing stat+hash and emitting a CSV row. Rationale: the serial loop
  # forks 3 processes per file (two stat, one hash binary); on large
  # small-file corpora (photo libraries) this fork overhead — not the hashing
  # itself — dominates wall-clock. Parallelism recovers most of it on
  # multi-core NAS units and SSD/SHR arrays. Single-spindle HDD users should
  # keep HASH_JOBS low (1-2) to avoid seek thrashing; that's why the default
  # is a conservative cap rather than full nproc.
  #
  # Atomicity: each worker writes one CSV row per file via a single printf.
  # POSIX guarantees writes up to PIPE_BUF (>=512, 4096 on Linux) to a pipe
  # are atomic, and a CSV row is well under that, so rows from concurrent
  # workers do not interleave. Failure rows are emitted to stderr-channel as
  # a sentinel the parent counts.

  local jobs="${HASH_JOBS:-1}"
  # sanitise: must be a positive integer
  case "$jobs" in (''|*[!0-9]*) jobs=1 ;; esac
  [[ "$jobs" -lt 1 ]] && jobs=1

  if [[ "$jobs" -gt 1 ]]; then
    info "Parallel hashing enabled: $jobs workers."
  fi

  # The worker: reads ONE file path as $1, stats + hashes it, prints a CSV row
  # on success, or a FAIL sentinel line (prefixed with the NUL-safe marker) on
  # failure. Exported into the environment for `bash -c` invocation by xargs.
  # We pass ALGO and the hash command through the environment.
  _hash_worker() {
    local f="$1"
    local size mtime line hash
    size=$(_stat_size "$f" 2>/dev/null || echo -1)
    mtime=$(_stat_mtime "$f" 2>/dev/null || echo -1)
    if [[ "$size" -lt 0 || "$mtime" -lt 0 ]]; then
      printf '\037FAIL\037stat\t%s\n' "$f"   # \037 = unit separator, unlikely in paths
      return 0
    fi
    if ! line=$("${hash_cmd[@]}" -- "$f" 2>/dev/null); then
      printf '\037FAIL\037hash\t%s\n' "$f"
      return 0
    fi
    hash="${line%% *}"
    # csv_escape inline (worker runs in a subshell that has the function)
    local esc="${f//\"/\"\"}"
    printf '"%s",%s,%s,%s,%s\n' "$esc" "$size" "$mtime" "$ALGO" "$hash"
  }
  export -f _hash_worker _stat_size _stat_mtime 2>/dev/null || true
  export ALGO
  # hash_cmd is an array; export its serialised form and rebuild in workers
  export HASH_CMD_STR="${hash_cmd[*]}"

  # Stream: NUL-delimited file list → xargs → workers → tee into a post-processor
  # that splits CSV rows (to $OUTPUT) from FAIL sentinels (counted).
  local fail_file="$VAR_DIR/hash-fails.$$"
  : > "$fail_file"

  if [[ "$jobs" -gt 1 ]]; then
    # Parallel path via xargs -P. We invoke a tiny bash -c per file that
    # rebuilds the hash_cmd array from HASH_CMD_STR and calls the worker.
    # -n 1 keeps the per-file granularity (simplest correct mapping); the
    # fork cost of bash -c is offset by the parallelism for large corpora.
    #
    # v1.3.18 (peer-review finding #3): run the pipeline as a background
    # job and `wait` for it. bash defers signal traps while a FOREGROUND
    # pipeline runs — so `kill $(cat var/hasher.pid)` used to block until
    # the pipeline finished. When wait is interrupted by a signal, the
    # trap fires immediately, _stop_group reaps the group (including this
    # backgrounded pipeline's job), and shutdown is prompt.
    { xargs -0 -P "$jobs" -n 1 bash -c '
        read -ra hash_cmd <<< "$HASH_CMD_STR"
        _hash_worker "$1"
      ' _ < "$FILES_LIST" \
      | while IFS= read -r row; do
          case "$row" in
            $'\037'FAIL$'\037'*)
              printf '%s\n' "$row" >> "$fail_file"
              ;;
            *)
              printf '%s\n' "$row" >> "$OUTPUT"
              ;;
          esac
        done
    } &
    HASHER_PIPELINE_PID=$!
    # `wait` on a specific PID is interruptible by signals; the TERM/INT
    # traps will run BEFORE this wait returns (their handlers exit the
    # script, so control does not resume here after a signal).
    wait "$HASHER_PIPELINE_PID" 2>/dev/null || true
    HASHER_PIPELINE_PID=""
  else
    # Serial path: preserve exact historical behaviour, no bash -c overhead.
    while IFS= read -r -d '' f; do
      local out
      out="$(_hash_worker "$f")"
      case "$out" in
        $'\037'FAIL$'\037'*)
          printf '%s\n' "$out" >> "$fail_file"
          ;;
        *)
          printf '%s\n' "$out" >> "$OUTPUT"
          ;;
      esac
    done < "$FILES_LIST"
  fi

  # Tally results
  local hashed_rows fail_rows
  hashed_rows=$(( $(wc -l < "$OUTPUT" 2>/dev/null || echo 1) - 1 ))   # minus header
  [[ "$hashed_rows" -lt 0 ]] && hashed_rows=0
  fail_rows=$(wc -l < "$fail_file" 2>/dev/null | tr -d ' ' || echo 0)
  [[ -z "$fail_rows" ]] && fail_rows=0

  # Emit per-failure warnings (kept concise; full list is in the fail file)
  if [[ "$fail_rows" -gt 0 ]]; then
    while IFS= read -r fl; do
      local kind path
      kind="${fl#$'\037'FAIL$'\037'}"; kind="${kind%%$'\t'*}"
      path="${fl#*$'\t'}"
      # portable: don't use bash-4 ${kind^}; just print the kind as-is
      warn "$kind failed: $path"
    done < "$fail_file"
  fi
  rm -f -- "$fail_file" 2>/dev/null || true

  DONE=$(( hashed_rows + fail_rows ))
  FAIL="$fail_rows"

  local end_ts elapsed sH sM sS
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  sH=$((elapsed/3600)); sM=$((elapsed%3600/60)); sS=$((elapsed%60))

  stop_hash_progress

  info "Completed. Hashed $DONE/$TOTAL files (failures=$FAIL) in $(printf '%02d:%02d:%02d' "$sH" "$sM" "$sS"). CSV: $OUTPUT"

  # v1.3.22: sort the CSV by path for deterministic output and clean
  # cross-run diffing. Fail-safe: original is never touched until the
  # sorted candidate is validated. See sort_output_csv().
  if [[ "$SORT_OUTPUT" = "true" ]]; then
    _first_run_sort_notice
    sort_output_csv "$OUTPUT" || warn "CSV sort failed; unsorted output retained (see warnings above)"
  else
    info "CSV sort skipped (SORT_OUTPUT=$SORT_OUTPUT). Rows in worker-race order."
  fi

  post_run_reports "$OUTPUT" "$CSV_TAG"
}

# ───────────────────────── Post-run Reports ────────────────
# ───────────────────────── CSV Sort (v1.3.22) ──────────────
# First-run notice: on the very first hashing run of a fresh install,
# tell the user about the new sort behaviour and how to turn it off if
# they don't want it. Marker file in var/ so we only print it once.
_first_run_sort_notice() {
  local marker="$VAR_DIR/.sort-notice-shown"
  [[ -f "$marker" ]] && return 0
  info ""
  info "─── First-run notice: CSV sorting ──────────────────────────────"
  info "Since v1.3.22, Hasher sorts the output CSV by path after hashing."
  info "This makes cross-run diffing possible and produces deterministic"
  info "output. The sort is fail-safe: the original CSV is never touched"
  info "until the sorted candidate has been fully validated (row count,"
  info "header, byte count). If validation fails, you keep the unsorted"
  info "CSV and a warning is logged — no possibility of corruption."
  info ""
  info "To disable: set 'sort_output = false' under [logging] in"
  info "  local/hasher.conf, or pass --no-sort on the command line."
  info "────────────────────────────────────────────────────────────────"
  info ""
  # Best-effort marker creation. If var/ isn't writable we just show the
  # notice again next run — harmless.
  mkdir -p "$VAR_DIR" 2>/dev/null || true
  : > "$marker" 2>/dev/null || true
}


#
#   1. NEVER touch the original CSV until the sorted candidate has been
#      fully written AND validated. A 5-hour hashing run must not be
#      corrupted by a bad sort. If anything goes wrong, we leave the
#      unsorted file exactly as the workers produced it and warn.
#
#   2. Sort to the SAME directory as the output CSV. Rename via `mv` is
#      then atomic (same filesystem = single inode rename), and the
#      temp file lands on the same volume — no cross-filesystem risk,
#      no /tmp space concerns.
#
#   3. Validate before replacing. Row count of sorted must equal row
#      count of original. Header must be intact on line 1. If either
#      check fails, discard the sorted file and keep the original.
#
#   4. Use LC_ALL=C for byte-order determinism across locales — critical
#      for cross-run diffing (the main reason to sort at all).
#
#   5. Sort by full row (opaque line comparison), not by parsed path
#      column. Full-row sort ≈ path sort in practice because path is
#      the first column, and it avoids the CSV-quoted-comma parsing
#      trap. The v1.3.22 discussion considered a keyed sort with
#      awk-preprocessed prefix; deferred as unnecessary complexity.
#
# Returns 0 on success (CSV replaced with sorted version), non-zero on
# any failure (original untouched). Non-zero exits are LOGGED but not
# fatal — hashing succeeded, sorting is a nice-to-have.
sort_output_csv() {
  local csv="$1"
  [[ -f "$csv" ]] || { warn "sort: CSV not found: $csv"; return 1; }
  [[ -s "$csv" ]] || { warn "sort: CSV empty, skipping"; return 1; }

  # 1. Snapshot the pre-sort state (lines + first-line header + size)
  local orig_lines orig_size orig_header
  orig_lines=$(wc -l < "$csv" 2>/dev/null | tr -d ' ' || echo 0)
  orig_size=$(wc -c < "$csv" 2>/dev/null | tr -d ' ' || echo 0)
  orig_header=$(head -n1 "$csv" 2>/dev/null || echo "")

  if [[ "$orig_lines" -lt 2 ]]; then
    # Header only, no data rows. Nothing to sort but not an error.
    info "sort: CSV has no data rows (${orig_lines} line(s)); nothing to sort."
    return 0
  fi

  # 2. Verify the header looks like a header. Expected first column is 'path'.
  #    If the header is missing (unusual but possible from tampering), refuse
  #    to sort — we don't want to shuffle a rogue first data row into place.
  if [[ "${orig_header:0:4}" != "path" ]]; then
    warn "sort: CSV first line does not start with 'path'; refusing to sort"
    warn "  first line was: ${orig_header:0:80}"
    return 1
  fi

  # 3. Produce sorted candidate in the SAME directory (atomic rename later).
  local sort_tmp="${csv}.sort-tmp.$$"
  local sort_err="${csv}.sort-err.$$"

  # Header first, then LC_ALL=C sort of the data rows. tail -n +2 gives us
  # rows without the header; sort them opaquely.
  {
    printf '%s\n' "$orig_header"
    tail -n +2 "$csv" | LC_ALL=C sort
  } > "$sort_tmp" 2>"$sort_err"
  local sort_rc=$?

  if [[ "$sort_rc" -ne 0 ]]; then
    warn "sort: sort command failed with exit $sort_rc; keeping unsorted CSV"
    [[ -s "$sort_err" ]] && warn "  sort stderr: $(head -n1 "$sort_err")"
    rm -f -- "$sort_tmp" "$sort_err" 2>/dev/null || true
    return 1
  fi
  rm -f -- "$sort_err" 2>/dev/null || true

  # 4. VALIDATE the candidate before touching the original.
  local new_lines new_size new_header
  new_lines=$(wc -l < "$sort_tmp" 2>/dev/null | tr -d ' ' || echo 0)
  new_size=$(wc -c < "$sort_tmp" 2>/dev/null | tr -d ' ' || echo 0)
  new_header=$(head -n1 "$sort_tmp" 2>/dev/null || echo "")

  # 4a. Row count must match exactly.
  if [[ "$new_lines" != "$orig_lines" ]]; then
    warn "sort: line count changed after sort (was $orig_lines, now $new_lines); keeping unsorted CSV"
    rm -f -- "$sort_tmp" 2>/dev/null || true
    return 1
  fi

  # 4b. Header must be intact — same string, position 1.
  if [[ "$new_header" != "$orig_header" ]]; then
    warn "sort: header changed after sort; keeping unsorted CSV"
    rm -f -- "$sort_tmp" 2>/dev/null || true
    return 1
  fi

  # 4c. Size sanity: sorted file should be within 1 byte of original
  #      (allow one trailing-newline difference from sort implementations).
  local size_diff=$(( new_size - orig_size ))
  [[ "$size_diff" -lt 0 ]] && size_diff=$(( -size_diff ))
  if [[ "$size_diff" -gt 1 ]]; then
    warn "sort: byte count differs by $size_diff (orig=$orig_size, sorted=$new_size); keeping unsorted CSV"
    rm -f -- "$sort_tmp" 2>/dev/null || true
    return 1
  fi

  # 5. All checks passed. Atomic rename onto the original — same-directory
  #    mv is a single inode rename, either fully succeeds or leaves the
  #    original untouched. No possibility of a half-written CSV.
  if ! mv -f -- "$sort_tmp" "$csv"; then
    warn "sort: atomic rename failed; keeping unsorted CSV"
    rm -f -- "$sort_tmp" 2>/dev/null || true
    return 1
  fi

  info "sort: CSV sorted by path ($((orig_lines - 1)) data rows, ${new_size} bytes)"
  return 0
}

# ───────────────────────── Post-run Reports ────────────────
post_run_reports() {
  local csv="$1"
  local run_tag="$2"  # v1.3.19 (finding #5): full run tag (F-HMS-PID),
                       # not just DATE_TAG. Same-day runs no longer overwrite.

  mkdir -p "$LOGS_DIR" "$ZERO_DIR"

  # v1.3.19 (peer-review finding #5): derived reports now include the run
  # tag so same-day runs don't overwrite each other. Two convenience
  # symlinks (*-latest.txt) always point at the newest report of each kind
  # — that's what next-step commands print, so they stay stable while
  # historical reports accumulate.
  local zero_txt="$ZERO_DIR/zero-length-$run_tag.txt"
  local dupes_txt="$LOGS_DIR/duplicate-hashes-$run_tag.txt"
  local zero_latest="$ZERO_DIR/zero-length-latest.txt"
  local dupes_latest="$LOGS_DIR/duplicate-hashes-latest.txt"

  if [[ -f "$csv" ]]; then
    awk '
      NR==1 { next }
      {
        s=$0
        n=0; pos=0
        while ( (i=index(substr(s,pos+1),",")) > 0 ) {
          pos += i; n++; c[n]=pos
        }
        if (n < 4) next
        c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
        path = substr(s,1,c1-1)
        size = substr(s,c1+1,c2-c1-1)
        if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }
        if (size+0==0) print path
        for (k=1;k<=n;k++) delete c[k]
      }
    ' "$csv" > "$zero_txt" || true
  fi

  awk '
    BEGIN{ OFS="," }
    NR==1 { next }
    {
      s=$0
      n=0; pos=0
      while ( (i=index(substr(s,pos+1),",")) > 0 ) {
        pos += i; n++; c[n]=pos
      }
      if (n < 4) next
      c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
      path = substr(s,1,c1-1)
      hash = substr(s,c4+1)

      if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }
      gsub(/^[ \t]+|[ \t]+$/,"",hash)

      if (hash!="") {
        cnt[hash]++; files[hash]=files[hash]"\n"path
      }

      for (k=1;k<=n;k++) delete c[k]
    }
    END{
      for (k in cnt) if (cnt[k]>1) {
        print "HASH " k " (" cnt[k] " files):"
        s=files[k]; sub(/^\n/,"",s)
        n=split(s,arr,"\n")
        for (i=1;i<=n;i++) print "  " arr[i]
        print ""
      }
    }
  ' "$csv" > "$dupes_txt" || true

  # v1.3.19 (finding #5): update -latest pointers atomically. Use symlinks
  # where supported; fall back to a rewritten copy for filesystems that
  # reject symlinks (rare NAS shares over SMB).
  if ln -sfn -- "$(basename "$zero_txt")" "$zero_latest" 2>/dev/null; then :; else
    cp -f -- "$zero_txt" "$zero_latest" 2>/dev/null || true
  fi
  if ln -sfn -- "$(basename "$dupes_txt")" "$dupes_latest" 2>/dev/null; then :; else
    cp -f -- "$dupes_txt" "$dupes_latest" 2>/dev/null || true
  fi

  local zero_count=0 dupe_groups=0 dupe_files=0
  [[ -s "$zero_txt" ]] && zero_count=$(wc -l < "$zero_txt" | tr -d ' ')
  if [[ -s "$dupes_txt" ]]; then
    dupe_groups=$(grep -c '^HASH ' "$dupes_txt" || true)
    dupe_files=$(grep -v '^$' "$dupes_txt" | grep -v '^HASH ' | sed 's/^[[:space:]]\+//' | sed '/^$/d' | wc -l | tr -d ' ' || true)
  fi

  echo
  info "Run complete. Summary:"
  info "  • CSV written to: $csv"
  info "  • Zero-length files: $zero_count (see: $zero_txt)"
  info "  • Duplicate groups: $dupe_groups (files involved: $dupe_files) (see: $dupes_txt)"
  echo
  echo -e "${GREEN}[RECOMMENDED NEXT STEPS]${NC}"
  echo "  1) Find duplicate folders (highest value, lowest risk):"
  echo "       bin/find-duplicate-folders.sh --input \"$csv\""
  echo "  2) Find and review duplicate files:"
  echo "       bin/find-duplicates.sh --input \"$csv\""
  echo "       bin/review-duplicates.sh --from-report \"$dupes_txt\""
  echo "  3) Remove zero-length files (review first, no changes):"
  echo "       bin/delete-zero-length.sh --report \"$zero_txt\" --dry-run"
  echo "       bin/delete-zero-length.sh --report \"$zero_txt\" --force"
  echo
}

# ───────────────────────── Execute ─────────────────────────
main
