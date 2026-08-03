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
# v1.3.23 (peer-review recheck finding #1a): behavioural probe of pgrep.
# Previously we relied on `command -v pgrep` — but pgrep can EXIST while
# being non-functional (broken build, missing kernel /proc access, doesn't
# support -g/-P). In that case _stop_group silently returned empty
# survivor lists and the shutdown was ineffective. Now we actually TEST
# whether `pgrep -g $$` returns our own PID and `pgrep -P $$` runs
# without error. If either fails, HASHER_USE_PGREP is set to 0 and every
# subsequent enumeration uses the ps fallback.
HASHER_USE_PGREP=0
if command -v pgrep >/dev/null 2>&1; then
  # v1.3.23 (recheck finding #1a): behavioural probe.
  # Query our OWN process group (PGID), not our PID. pgrep -g takes a
  # process-group ID; our shell's PGID may or may not match its PID
  # depending on whether we're a session leader.
  _probe_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  _probe_g="$(pgrep -g "${_probe_pgid:-$$}" 2>/dev/null || true)"
  # -P self-test: guard `set -e` — pgrep exits 1 when no children match,
  # which is not a failure. Use `|| _probe_p_rc=$?` to capture without
  # tripping the trap.
  _probe_p_rc=0
  pgrep -P $$ >/dev/null 2>&1 || _probe_p_rc=$?
  # Consider pgrep working if -g returns at least one entry (should
  # include ourselves) and -P exits cleanly (0=matches, 1=no matches).
  if [[ -n "$_probe_g" ]] && [[ "$_probe_p_rc" -eq 0 || "$_probe_p_rc" -eq 1 ]]; then
    HASHER_USE_PGREP=1
  fi
fi
if [[ "$HASHER_USE_PGREP" -eq 0 ]]; then
  # pgrep absent OR non-functional — check the ps fallback is usable
  _probe="$(ps -eo pid=,pgid= 2>/dev/null | head -1)"
  if [ -z "$_probe" ]; then
    printf '[ERROR] Neither functional pgrep nor `ps -eo pid=,pgid=` is available.\n' >&2
    printf '[ERROR] Hasher cannot safely stop parallel workers without one of them.\n' >&2
    printf '[ERROR] Install procps (pgrep) or a POSIX-ish ps, then re-run.\n' >&2
    exit 3
  fi
fi
export HASHER_USE_PGREP

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

ALGO="sha256"        # SHA-256 only since v1.3.16
PATHFILE=""
RUN_IN_BACKGROUND=false
IS_CHILD=false       # set when re-exec'ed under nohup
LOG_LEVEL="info"     # info|warn|error
# v1.3.22: sort the output CSV by path after hashing completes. Default on
# for deterministic output and cross-run diffing. The sort is fail-safe:
# original CSV is NEVER touched until the sorted candidate has been fully
# validated (row count matches, header intact). See sort_output_csv().
SORT_OUTPUT="true"
# v1.3.30: post-hash analysis stages are independently configurable.
# The v1.3.29 auto_discover key remains supported as a compatibility alias
# controlling both finder stages together.
AUTO_FIND_DUPLICATE_FOLDERS="true"
AUTO_FIND_DUPLICATE_FILES="true"
AUTO_BUILD_REVIEW_INDEX="true"
ANALYSIS_MODE="automatic"
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
  # v1.3.25 (peer-review recheck #4): identity fingerprint for the
  # stability check. Reviewer demonstrated that a file whose content
  # was replaced and then restored with the same size + whole-second
  # mtime slipped through the check. Adding ctime, inode, and device
  # closes the loop: an atomic rename changes the inode; any write
  # (even one restoring identical size/mtime) bumps ctime.
  # Format: size|mtime|ctime|dev|ino
  # %Z = ctime (integer seconds), %d = device, %i = inode on GNU stat
  _stat_fingerprint() { stat -c "%s|%Y|%Z|%d|%i" -- "$1"; }
else
  # BSD stat (macOS)
  _stat_size()  { stat -f "%z" -- "$1"; }
  _stat_mtime() { stat -f "%m" -- "$1"; }
  # BSD stat: %z=size, %m=mtime, %c=ctime, %d=device, %i=inode
  _stat_fingerprint() { stat -f "%z|%m|%c|%d|%i" -- "$1"; }
fi

# Detect sha256sum vs shasum (macOS ships shasum, not sha256sum)
# v1.3.23 (peer-review recheck observation E): only sha256 is supported
# since v1.3.16. The sha1/sha512/md5/blake2 branches removed here were
# unreachable (the ALGO check in main() rejects everything else before
# calling this) and just added maintenance surface.
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
    *)
      # Reached only if a caller bypasses the top-level ALGO gate.
      # Return empty so the check-deps error path fires.
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
          # v1.3.29 compatibility: control both discovery finders together.
          auto_discover|auto-discover)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) AUTO_FIND_DUPLICATE_FOLDERS="false"; AUTO_FIND_DUPLICATE_FILES="false" ;;
              1|true|yes|on)  AUTO_FIND_DUPLICATE_FOLDERS="true";  AUTO_FIND_DUPLICATE_FILES="true"  ;;
              *)              : ;;
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
          # v1.3.30: honour the v1.3.29 shipped placement under [logging]
          # as well as the documented [setup]/[post_hash] locations.
          sort_output|sort-output)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) SORT_OUTPUT="false" ;;
              1|true|yes|on)  SORT_OUTPUT="true"  ;;
            esac
            ;;
          auto_discover|auto-discover)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) AUTO_FIND_DUPLICATE_FOLDERS="false"; AUTO_FIND_DUPLICATE_FILES="false" ;;
              1|true|yes|on)  AUTO_FIND_DUPLICATE_FOLDERS="true";  AUTO_FIND_DUPLICATE_FILES="true"  ;;
            esac
            ;;
          xtrace)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              1|true|yes|on) set -x ;;
            esac
            ;;
          *)             : ;;
        esac
        ;;
      "post_hash"|"post-hash")
        case "$key" in
          analysis_mode|analysis-mode)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in automatic|manual) ANALYSIS_MODE="$v" ;; esac
            ;;
          auto_find_duplicate_folders|auto-find-duplicate-folders)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) AUTO_FIND_DUPLICATE_FOLDERS="false" ;;
              1|true|yes|on)  AUTO_FIND_DUPLICATE_FOLDERS="true"  ;;
            esac
            ;;
          auto_find_duplicate_files|auto-find-duplicate-files)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) AUTO_FIND_DUPLICATE_FILES="false" ;;
              1|true|yes|on)  AUTO_FIND_DUPLICATE_FILES="true"  ;;
            esac
            ;;
          auto_build_review_index|auto-build-review-index)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) AUTO_BUILD_REVIEW_INDEX="false" ;;
              1|true|yes|on)  AUTO_BUILD_REVIEW_INDEX="true"  ;;
            esac
            ;;
          auto_discover|auto-discover)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) AUTO_FIND_DUPLICATE_FOLDERS="false"; AUTO_FIND_DUPLICATE_FILES="false" ;;
              1|true|yes|on)  AUTO_FIND_DUPLICATE_FOLDERS="true";  AUTO_FIND_DUPLICATE_FILES="true"  ;;
            esac
            ;;
          *) : ;;
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
          [--exclude PATTERN ...] [--zero-length-only] [--config FILE]
          [--discover|--no-discover] [--no-folder-discovery]
          [--no-file-discovery] [--no-review-index] [--help]

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
  --discover         Enable post-hash folder and file discovery.
  --no-discover      Disable both post-hash duplicate finder stages.
  --no-folder-discovery  Skip duplicate-folder discovery for this run.
  --no-file-discovery    Skip duplicate-file discovery for this run.
  --no-review-index      Do not build the prepared interactive-review index.
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
    # v1.3.30: independently control post-hash analysis stages.
    --no-discover)  AUTO_FIND_DUPLICATE_FOLDERS="false"; AUTO_FIND_DUPLICATE_FILES="false" ;;
    --discover)     AUTO_FIND_DUPLICATE_FOLDERS="true";  AUTO_FIND_DUPLICATE_FILES="true"  ;;
    --no-folder-discovery) AUTO_FIND_DUPLICATE_FOLDERS="false" ;;
    --folder-discovery)    AUTO_FIND_DUPLICATE_FOLDERS="true"  ;;
    --no-file-discovery)   AUTO_FIND_DUPLICATE_FILES="false"   ;;
    --file-discovery)      AUTO_FIND_DUPLICATE_FILES="true"    ;;
    --no-review-index)     AUTO_BUILD_REVIEW_INDEX="false" ;;
    --review-index)        AUTO_BUILD_REVIEW_INDEX="true"  ;;
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
  [[ "$AUTO_FIND_DUPLICATE_FOLDERS" = "true" ]] || args+=( --no-folder-discovery )
  [[ "$AUTO_FIND_DUPLICATE_FILES" = "true" ]]   || args+=( --no-file-discovery )
  [[ "$AUTO_BUILD_REVIEW_INDEX" = "true" ]]     || args+=( --no-review-index )
  # FIX (v1.1.10): "${arr[@]}" on an empty array errors under set -u in
  # bash 3.2 (Apple's stock /bin/bash) and 4.0–4.3. The :- guard is the
  # portable form for safe-on-empty array iteration. Same fix as line ~425.
  for ex in "${EXTRA_EXCLUDES[@]:-}"; do
    [[ -n "$ex" ]] && args+=( --exclude "$ex" )
  done
  $ZERO_LENGTH_ONLY && args+=( --zero-length-only )

  nohup "${args[@]}" >>"$BACKGROUND_LOG" 2>&1 < /dev/null &
  bgpid=$!
  # v1.3.23 (peer-review recheck observation D): the previous form used
  # ${ZERO_LENGTH_ONLY:+(zero-length-only mode) }, which fires whenever
  # the variable is non-empty — including the literal string "false".
  # Every normal run displayed "(zero-length-only mode)". Use an
  # explicit boolean test instead.
  local _mode_txt=""
  $ZERO_LENGTH_ONLY && _mode_txt=" (zero-length-only mode)"
  echo "Hasher started with nohup (PID $bgpid). Output:${_mode_txt} $OUTPUT"
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
  local pathfile_syminv=0   # v1.3.25: explicitly-listed symlinks refused

  if [[ -n "$PATHFILE" ]]; then
    if [[ ! -r "$PATHFILE" ]]; then
      error "Cannot read --pathfile '$PATHFILE'"; exit 1
    fi
    # v1.4.1: the discovery list is written through a DEDICATED file
    # descriptor rather than by redirecting the loop's stdout.
    #
    # Previously the loop ended `done < "$PATHFILE" >> "$FILES_LIST".tmp`,
    # so *everything* the loop printed landed in the NUL-delimited list —
    # including warn/info output, which writes to stdout. A single
    # "Symlink refused" or "Path does not exist" warning injected its text
    # (ANSI codes and all) into the list, and because warn emits \n rather
    # than \0 the warning and the NEXT discovered path shared one NUL
    # record. The delimiter guard then dropped that whole record, silently
    # losing a real file from the manifest.
    #
    # Routing paths to FD 9 makes the data path explicit: only deliberate
    # `>&9` writes reach the list, and diagnostics can never contaminate it.
    # A fixed descriptor number is used rather than `{var}>` for bash 3.2
    # (stock macOS) compatibility.
    exec 9>> "$FILES_LIST".tmp || { error "Cannot open discovery list for writing"; exit 1; }
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
      if [[ -L "$path" ]]; then
        # Refuse the final component before canonicalisation. Resolving and
        # hashing the target would make the manifest path describe a different
        # filesystem object from the one the user supplied.
        warn "Symlink refused (list the target's real path instead): $path"
        pathfile_syminv=$((pathfile_syminv + 1))
      elif [[ -d "$path" ]]; then
        local path_real
        path_real="$(canonical_existing_path "$path" 2>/dev/null || true)"
        if [[ -z "$path_real" || ! -d "$path_real" ]]; then
          warn "Could not canonicalise directory path: $path"
          continue
        fi
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
          find "$path_real" "${prune_args[@]}" -type f -print0 >&9 2>"$find_err" || find_status=$?
        else
          find "$path_real" -type f -print0 >&9 2>"$find_err" || find_status=$?
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
        local path_real
        path_real="$(canonical_existing_path "$path" 2>/dev/null || true)"
        if [[ -n "$path_real" && -f "$path_real" ]]; then
          printf '%s\0' "$path_real" >&9
          pathfile_valid=$((pathfile_valid + 1))
        else
          warn "Could not canonicalise file path: $path"
        fi
      else
        warn "Path does not exist: $path"
      fi
    done < "$PATHFILE"
    exec 9>&-
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
        # v1.4.1: see the FD 9 note in the --pathfile branch above.
        exec 9>> "$FILES_LIST".tmp || { error "Cannot open discovery list for writing"; exit 1; }
        while IFS= read -r -d '' path || [[ -n "$path" ]]; do
          [[ -z "$path" ]] && continue
          stdin_seen=$((stdin_seen + 1))
          if [[ -L "$path" ]]; then
            warn "Symlink refused via stdin (list the target's real path instead): $path"
          elif [[ -d "$path" ]]; then
            local path_real
            path_real="$(canonical_existing_path "$path" 2>/dev/null || true)"
            if [[ -z "$path_real" || ! -d "$path_real" ]]; then
              warn "Could not canonicalise piped directory: $path"
              continue
            fi
            local _fs=0
            if [[ ${#prune_args[@]} -gt 0 ]]; then
              find "$path_real" "${prune_args[@]}" -type f -print0 >&9 2>/dev/null || _fs=$?
            else
              find "$path_real" -type f -print0 >&9 2>/dev/null || _fs=$?
            fi
            [[ "$_fs" -eq 0 ]] && stdin_valid=$((stdin_valid + 1)) \
              || warn "find failed on piped path '$path' (exit $_fs) — skipping"
          elif [[ -f "$path" ]]; then
            local path_real
            path_real="$(canonical_existing_path "$path" 2>/dev/null || true)"
            if [[ -n "$path_real" && -f "$path_real" ]]; then
              printf '%s\0' "$path_real" >&9
              stdin_valid=$((stdin_valid + 1))
            else
              warn "Could not canonicalise piped file: $path"
            fi
          else
            warn "Piped path does not exist: $path"
          fi
        done < "$tmp_in"
        exec 9>&-
      else
        # v1.4.1: see the FD 9 note in the --pathfile branch above.
        exec 9>> "$FILES_LIST".tmp || { error "Cannot open discovery list for writing"; exit 1; }
        while IFS= read -r path || [[ -n "$path" ]]; do
          # v1.3.20: strip trailing CR (see pathfile-loop comment above)
          path="${path%$'\r'}"
          [[ -z "$path" ]] && continue
          stdin_seen=$((stdin_seen + 1))
          if [[ -L "$path" ]]; then
            warn "Symlink refused via stdin (list the target's real path instead): $path"
          elif [[ -d "$path" ]]; then
            local path_real
            path_real="$(canonical_existing_path "$path" 2>/dev/null || true)"
            if [[ -z "$path_real" || ! -d "$path_real" ]]; then
              warn "Could not canonicalise piped directory: $path"
              continue
            fi
            local _fs=0
            if [[ ${#prune_args[@]} -gt 0 ]]; then
              find "$path_real" "${prune_args[@]}" -type f -print0 >&9 2>/dev/null || _fs=$?
            else
              find "$path_real" -type f -print0 >&9 2>/dev/null || _fs=$?
            fi
            [[ "$_fs" -eq 0 ]] && stdin_valid=$((stdin_valid + 1)) \
              || warn "find failed on piped path '$path' (exit $_fs) — skipping"
          elif [[ -f "$path" ]]; then
            local path_real
            path_real="$(canonical_existing_path "$path" 2>/dev/null || true)"
            if [[ -n "$path_real" && -f "$path_real" ]]; then
              printf '%s\0' "$path_real" >&9
              stdin_valid=$((stdin_valid + 1))
            else
              warn "Could not canonicalise piped file: $path"
            fi
          else
            warn "Piped path does not exist: $path"
          fi
        done < "$tmp_in"
        exec 9>&-
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
  #
  # v1.3.25 (peer-review recheck #2): distinguish "all refused symlinks"
  # from "all missing / unreadable" — the message and remediation differ.
  if [[ "$pathfile_seen" -gt 0 && "$pathfile_valid" -eq 0 ]]; then
    if [[ "$pathfile_syminv" -gt 0 && "$pathfile_syminv" -eq "$pathfile_seen" ]]; then
      error "All $pathfile_seen path(s) in '$PATHFILE' are symlinks — refused."
      error "Symlinks are refused because hashing them would record the symlink's"
      error "  own metadata alongside the target's content, producing an inconsistent"
      error "  CSV row. List each target's REAL path instead (readlink -f, or resolve"
      error "  with your file manager)."
    else
      error "All $pathfile_seen path(s) listed in '$PATHFILE' are missing or unreadable."
      error "Common causes: external drive not mounted, typo in volume name, NAS share not connected."
      error "Check 'ls /Volumes' (macOS), 'ls /mnt' or 'ls /media' (Linux), or 'ls /volume1' (Synology)."
    fi
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

  # v1.3.27: collapse duplicate discovery entries before hashing. Overlapping
  # roots (for example /volume1/Family and /volume1/Family/Photos) can cause
  # `find` to emit the same canonical file path more than once. Besides wasting
  # I/O, duplicate rows can make otherwise-identical folder signatures differ.
  # Paths containing TAB/LF/CR have already been removed above, so it is safe
  # and portable to use a newline sort here and restore NUL delimiters after it.
  if [[ -s "$FILES_LIST".tmp ]]; then
    local _dedupe_before _dedupe_after _dedupe_removed
    local _dedupe_tmp="$FILES_LIST.tmp.unique"
    _dedupe_before=$(tr -cd '\0' < "$FILES_LIST".tmp | wc -c | tr -d ' ')
    {
      tr '\0' '\n' < "$FILES_LIST".tmp \
        | LC_ALL=C sort -u \
        | while IFS= read -r _unique_path; do
            [[ -n "$_unique_path" ]] && printf '%s\0' "$_unique_path"
          done
    } > "$_dedupe_tmp"
    _dedupe_after=$(tr -cd '\0' < "$_dedupe_tmp" | wc -c | tr -d ' ')
    mv -f -- "$_dedupe_tmp" "$FILES_LIST".tmp
    _dedupe_removed=$((_dedupe_before - _dedupe_after))
    if [[ "$_dedupe_removed" -gt 0 ]]; then
      warn "Removed $_dedupe_removed duplicate discovery path(s) caused by overlapping or repeated scan roots."
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
    # Capture and terminate the ticker's current sleep before killing the
    # ticker shell; otherwise the sleep can be reparented to init and remain
    # in our process group after an otherwise clean stop.
    local _kids _k
    _kids="$(_enum_children "$hash_progress_pid" 2>/dev/null || true)"
    for _k in $_kids; do kill -TERM "$_k" 2>/dev/null || true; done
    kill -TERM "$hash_progress_pid" 2>/dev/null || true
    wait "$hash_progress_pid" 2>/dev/null || true
    for _k in $_kids; do kill -KILL "$_k" 2>/dev/null || true; done
  fi
  hash_progress_pid=0
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
    local _kids _k
    _kids="$(_enum_children "$zero_progress_pid" 2>/dev/null || true)"
    for _k in $_kids; do kill -TERM "$_k" 2>/dev/null || true; done
    kill -TERM "$zero_progress_pid" 2>/dev/null || true
    wait "$zero_progress_pid" 2>/dev/null || true
    for _k in $_kids; do kill -KILL "$_k" 2>/dev/null || true; done
  fi
  zero_progress_pid=0
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
  # v1.3.25 (peer-review recheck #3): honour the run status set by the
  # main hashing block. If the shell is already exiting non-zero from a
  # trap (e.g. TERM handler), leave that intact; otherwise exit with the
  # status we chose.
  if [[ -n "${HASHER_RUN_STATUS:-}" ]] && [[ "${HASHER_RUN_STATUS}" != "0" ]]; then
    exit "$HASHER_RUN_STATUS"
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

  # Stop progress tickers before group enumeration. Their inner `sleep`
  # processes must be collected while the ticker shells are still their
  # parents; killing only the shell can leave an orphaned sleep behind.
  stop_hash_progress
  stop_zero_progress

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
      _n="$(_count_group_pids $$)"
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

  # v1.3.27: reap the tracked top-level pipeline after escalation. This is
  # our direct child, so `wait` removes its zombie entry and allows the final
  # process-group check to distinguish genuinely live workers from exited
  # processes awaiting collection. Grandchildren are filtered by process state
  # in _enum_group_pids/_enum_children below.
  if [[ -n "${HASHER_PIPELINE_PID:-}" ]]; then
    wait "$HASHER_PIPELINE_PID" 2>/dev/null || true
    HASHER_PIPELINE_PID=""
  fi

  # v1.3.23 (peer-review recheck finding #1b): bounded wait for the kernel
  # to reap KILLed descendants. Previously a fixed 0.5s sleep, which was
  # too short on a busy NAS — pgrep still saw dying/zombie processes as
  # "survivors" and refused to release the lock. Now: poll every 0.1s
  # for up to 3s, exit early as soon as the count drops to 0.
  #
  # A zombie process (pid still visible but exited) is functionally dead
  # and unable to interfere with a new run; we could try `wait $pid` to
  # reap tracked children, but many workers are grandchildren (xargs ->
  # bash -c -> sha256sum) and bash cannot wait for those. Polling with a
  # bounded wait is the portable answer.
  local _settle_i=0
  local _still=0
  # Allow up to five seconds after KILL. On a busy NAS the process table can
  # briefly show exiting shells as live before their parent/reaper collects them.
  while [[ $_settle_i -lt 50 ]]; do
    if [[ "${IS_SESSION_LEADER:-0}" = "1" ]]; then
      _still="$(_count_group_pids $$)"
    else
      _still="$(_count_descendants $$)"
    fi
    [[ "${_still:-0}" -eq 0 ]] && break
    sleep 0.1; _settle_i=$((_settle_i + 1))
  done

  # Re-evaluate once more after the final sleep. The previous loop retained
  # the count taken before its last 0.1s delay, which could leave a false lock
  # even though the final workers exited during that delay.
  if [[ "${IS_SESSION_LEADER:-0}" = "1" ]]; then
    _still="$(_count_group_pids $$)"
  else
    _still="$(_count_descendants $$)"
  fi

  # After the bounded wait, if descendants are STILL alive, warn the
  # caller and refuse to release the lock — safer to leave the lock in
  # place than to let a new run start alongside orphans.
  if [[ "${_still:-0}" -gt 0 ]]; then
    printf '[ERROR] %d descendant(s) survived KILL escalation (bounded 5s wait).\n' "$_still" >&2
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
_pid_is_live_nonzombie() {
  local _pid="$1" _state=""
  kill -0 "$_pid" 2>/dev/null || return 1
  # `ps -o stat=` is available on GNU/BSD procps and modern BusyBox. If a
  # minimal ps cannot provide state, conservatively treat the process as live.
  _state="$(ps -o stat= -p "$_pid" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  case "$_state" in
    Z*|*Z*) return 1 ;;
    *) return 0 ;;
  esac
}
_enum_group_pids() {
  local _pgid="$1" _extra_exclude="${2:-}" _self_pid _candidates="" _p
  local _stat _rest _state _ppid _pgrp
  _self_pid="$(sh -c 'printf %s "$PPID"')"

  # Linux and Synology DSM expose process metadata through /proc. Reading it
  # with Bash builtins avoids creating pgrep/ps/awk/wc helper processes inside
  # the very process group we are trying to count and terminate.
  if [[ -d /proc/$$ ]]; then
    for _stat in /proc/[0-9]*/stat; do
      [[ -r "$_stat" ]] || continue
      _p="${_stat#/proc/}"; _p="${_p%/stat}"
      [[ "$_p" = "$$" || "$_p" = "$_self_pid" || ( -n "$_extra_exclude" && "$_p" = "$_extra_exclude" ) ]] && continue
      IFS= read -r _rest < "$_stat" 2>/dev/null || continue
      _rest="${_rest##*) }"
      # v1.4.1: /proc/PID/stat is SPACE-separated, but this script sets a
      # global IFS=$'\n\t' (no space) at the top. Without restoring space
      # here, `read` puts the entire remainder into _state and leaves
      # _pgrp empty — so the pgid comparison below never matches and this
      # whole /proc fast path silently returns nothing.
      #
      # The consequence was severe and invisible: every orphan check
      # reported "PGID clean", so stale locks were adopted while workers
      # were still running, and shutdown survivor counts were always zero.
      # It failed OPEN, which is why normal runs never surfaced it.
      # Setting IFS on the `read` itself keeps the change local.
      IFS=' ' read -r _state _ppid _pgrp _ <<< "$_rest"
      [[ "$_pgrp" = "$_pgid" ]] || continue
      [[ "$_state" = "Z" ]] && continue
      printf '%s\n' "$_p"
    done
    return 0
  fi

  # BSD/macOS fallback. Exclude the enumeration subshell and its caller so
  # helper processes cannot be mistaken for surviving hash workers.
  if [[ "${HASHER_USE_PGREP:-0}" -eq 1 ]]; then
    _candidates="$(pgrep -g "$_pgid" 2>/dev/null || true)"
  else
    _candidates="$(ps -eo pid=,pgid= 2>/dev/null \
      | awk -v pg="$_pgid" '$2 == pg {print $1}')"
  fi
  for _p in $_candidates; do
    [[ "$_p" = "$$" || "$_p" = "$_self_pid" || ( -n "$_extra_exclude" && "$_p" = "$_extra_exclude" ) ]] && continue
    _pid_is_live_nonzombie "$_p" && printf '%s\n' "$_p"
  done
  return 0
}
_count_group_pids() {
  local _pgid="$1" _self_pid _list="" _p _count=0
  _self_pid="$(sh -c 'printf %s "$PPID"')"
  _list="$(_enum_group_pids "$_pgid" "$_self_pid")"
  while IFS= read -r _p; do
    [[ -n "$_p" ]] && _count=$((_count + 1))
  done <<< "$_list"
  printf '%s' "$_count"
}
_enum_children() {
  local _parent="$1" _self_pid _candidates="" _p
  local _stat _rest _state _ppid _pgrp
  _self_pid="$(sh -c 'printf %s "$PPID"')"
  if [[ -d /proc/$$ ]]; then
    for _stat in /proc/[0-9]*/stat; do
      [[ -r "$_stat" ]] || continue
      _p="${_stat#/proc/}"; _p="${_p%/stat}"
      [[ "$_p" = "$_self_pid" ]] && continue
      IFS= read -r _rest < "$_stat" 2>/dev/null || continue
      _rest="${_rest##*) }"
      # v1.4.1: /proc/PID/stat is SPACE-separated, but this script sets a
      # global IFS=$'\n\t' (no space) at the top. Without restoring space
      # here, `read` puts the entire remainder into _state and leaves
      # _pgrp empty — so the pgid comparison below never matches and this
      # whole /proc fast path silently returns nothing.
      #
      # The consequence was severe and invisible: every orphan check
      # reported "PGID clean", so stale locks were adopted while workers
      # were still running, and shutdown survivor counts were always zero.
      # It failed OPEN, which is why normal runs never surfaced it.
      # Setting IFS on the `read` itself keeps the change local.
      IFS=' ' read -r _state _ppid _pgrp _ <<< "$_rest"
      [[ "$_ppid" = "$_parent" ]] || continue
      [[ "$_state" = "Z" ]] && continue
      printf '%s\n' "$_p"
    done
    return 0
  fi
  if [[ "${HASHER_USE_PGREP:-0}" -eq 1 ]]; then
    _candidates="$(pgrep -P "$_parent" 2>/dev/null || true)"
  else
    _candidates="$(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$_parent" '$2 == p {print $1}')"
  fi
  for _p in $_candidates; do
    [[ "$_p" = "$_self_pid" ]] && continue
    _pid_is_live_nonzombie "$_p" && printf '%s\n' "$_p"
  done
  return 0
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
UNSTABLE=0   # v1.3.24: files that changed during hashing (excluded from CSV)
HASHER_RUN_STATUS=0  # v1.3.25: 0=all hashed, 1=hash/stat failures, 4=unstable-only

main() {
  # v1.3.16 (peer-review finding #3): acquire a concurrency lock BEFORE any
  # work, using an atomic mkdir on the lockdir. Previously the pidfile was
  # just overwritten with `printf > pidfile`, which is neither atomic nor a
  # lock — direct-CLI or cron invocations bypassed the launcher's guard and
  # could overlap freely. mkdir is atomic on every filesystem we care about
  # (ext4/btrfs on DSM, APFS on macOS) and needs no `flock` binary.
  # v1.3.23 (peer-review recheck finding #2): CRITICAL — the previous
  # stale-lock adoption checked only whether the recorded PID was alive.
  # If the operator SIGKILL'd the hasher parent, the workers survived
  # under the old PGID but the parent PID was dead. A subsequent run saw
  # a "stale" lock, removed it, and started fresh — with the OLD workers
  # still reading the disk. Concurrent runs on the same corpus.
  #
  # Fix: store richer ownership info in the lock (PID, PGID, start time,
  # boot ID) and BEFORE adopting a lock whose PID is dead, verify that
  # the recorded PGID has NO surviving processes. If workers are still
  # alive under the old PGID, refuse to start — the operator must
  # explicitly clean up. Boot ID lets us short-circuit adoption cleanly
  # after a reboot (all old PIDs and PGIDs are guaranteed dead).
  mkdir -p "$VAR_DIR" 2>/dev/null || true
  local _lockdir="$VAR_DIR/hasher.lock"
  # Boot ID — /proc/sys/kernel/random/boot_id on Linux, `sysctl -n
  # kern.boottime` on BSD/macOS (both distinct across boots). Falls back
  # to `uptime` if neither is available.
  local _boot_id=""
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    _boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
  elif command -v sysctl >/dev/null 2>&1; then
    _boot_id="$(sysctl -n kern.boottime 2>/dev/null | tr -d ' ' || echo unknown)"
  else
    _boot_id="unknown"
  fi
  # Our own PGID (best effort — ps -o pgid= works on every target).
  local _my_pgid
  _my_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo $$)"
  local _my_start
  _my_start="$(date +%s)"

  if ! mkdir "$_lockdir" 2>/dev/null; then
    # Lock exists — parse ownership
    local _lockpid="" _lockpgid="" _lockboot="" _locktime=""
    [[ -f "$_lockdir/pid"      ]] && _lockpid="$(cat "$_lockdir/pid" 2>/dev/null || true)"
    [[ -f "$_lockdir/pgid"     ]] && _lockpgid="$(cat "$_lockdir/pgid" 2>/dev/null || true)"
    [[ -f "$_lockdir/boot_id"  ]] && _lockboot="$(cat "$_lockdir/boot_id" 2>/dev/null || true)"
    [[ -f "$_lockdir/start_ts" ]] && _locktime="$(cat "$_lockdir/start_ts" 2>/dev/null || true)"

    # Case 1: recorded PID is alive → active run, refuse.
    if [[ -n "$_lockpid" ]] && kill -0 "$_lockpid" 2>/dev/null; then
      error "Another hasher run is already active (PID $_lockpid, PGID ${_lockpgid:-?}, started ${_locktime:-?})."
      error "Use the launcher's 'k) Stop hashing' to terminate it first, or wait for it to finish."
      error "Lock: $_lockdir"
      exit 2
    fi

    # Case 2: different boot → all old PIDs/PGIDs are guaranteed dead.
    # Adopt cleanly.
    if [[ -n "$_lockboot" && -n "$_boot_id" && "$_lockboot" != "unknown" && "$_boot_id" != "unknown" && "$_lockboot" != "$_boot_id" ]]; then
      warn "Stale lock from previous boot — adopting (${_lockdir})."
      rm -rf -- "$_lockdir" 2>/dev/null || true
      mkdir "$_lockdir" 2>/dev/null || { error "Failed to acquire lock"; exit 2; }
    else
      # Case 3: same boot, dead parent PID. Check whether the recorded
      # PGID has ANY live processes. If yes, workers may still be
      # hashing — refuse.
      #
      # v1.3.24 (peer-review recheck finding #2): CRITICAL bug in v1.3.23
      # policy. Previously we only checked orphans when `_lockpgid !=
      # _my_pgid`. In the no-session-isolation code path (setsid absent,
      # or explicitly bypassed) two consecutive hasher invocations from
      # the same terminal share the same PGID. In that case, the
      # `_lockpgid == _my_pgid` branch skipped the orphan check entirely
      # and adopted the lock — even if the previous run's workers were
      # still alive in that shared PGID. Concurrent hashing on the same
      # corpus.
      #
      # Fix: fail closed when PGIDs match AND the recorded parent is
      # dead. We cannot distinguish our shell's own descendants (there
      # are none yet — we haven't started xargs) from orphaned workers
      # of the previous run inside a shared PGID by process-group
      # membership alone. The safest and simplest response is to refuse
      # to auto-adopt this ambiguous state; the operator must
      # explicitly clean up.
      local _orphans=""
      if [[ -n "$_lockpgid" ]]; then
        _orphans="$(_enum_group_pids "$_lockpgid" 2>/dev/null || true)"
        # Filter out our own PID (belt-and-braces — _enum_group_pids
        # already excludes $$, but a broken pgrep on some platforms
        # returned it, so filter defensively).
        _orphans="$(printf '%s\n' "$_orphans" | grep -v "^$$\$" | grep -v '^$' || true)"
      fi
      if [[ -n "$_orphans" ]]; then
        # There ARE processes under the recorded PGID besides us. Whether
        # they're leftover workers from a previous run or (in the shared-
        # PGID case) our shell's siblings, we can't tell — either way
        # we don't dare adopt.
        error "Stale lock at $_lockdir — parent PID $_lockpid is dead,"
        error "  but PGID $_lockpgid still has live processes:"
        error "  $(printf '%s\n' "$_orphans" | tr '\n' ' ')"
        error "  These may be orphaned workers from the crashed run,"
        error "  or (if you launched from a shell that shares the"
        error "  same process group) sibling processes we cannot"
        error "  safely distinguish from workers."
        error "  Options:"
        error "    (a) If those PIDs are stale hasher workers, kill them:"
        error "        kill -TERM $_orphans"
        error "        (wait ~5s, then if still alive: kill -KILL $_orphans)"
        error "        Then remove the lock: rm -rf $_lockdir"
        error "    (b) If you launched from a shell that shares your PGID,"
        error "        invoke via the launcher (setsid isolates the group)"
        error "        or use setsid explicitly."
        exit 2
      fi
      # No orphans OR they're indistinguishable from siblings AND our
      # PGID differs — refuse only if we can't confirm the PGID is
      # empty of non-self processes. Reaching here means _orphans is
      # empty, so we know no PIDs remain under the recorded PGID.
      warn "Stale lock at $_lockdir (PID ${_lockpid:-unknown} not running, PGID clean) — adopting."
      rm -rf -- "$_lockdir" 2>/dev/null || true
      mkdir "$_lockdir" 2>/dev/null || { error "Failed to acquire lock"; exit 2; }
    fi
  fi
  # Write full ownership record atomically.
  printf '%s\n' "$$"        > "$_lockdir/pid"      2>/dev/null || true
  printf '%s\n' "$_my_pgid" > "$_lockdir/pgid"     2>/dev/null || true
  printf '%s\n' "$_boot_id" > "$_lockdir/boot_id"  2>/dev/null || true
  printf '%s\n' "$_my_start" > "$_lockdir/start_ts" 2>/dev/null || true
  HASHER_LOCKDIR="$_lockdir"

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

  # v1.3.24 (peer-review recheck finding #4): short-circuit when no files
  # were discovered. Without this, an empty FILES_LIST would still spin
  # up xargs — and on macOS/BSD, xargs without -r invokes the command
  # once with an empty argument list. That fabricates a `[FAIL]stat`
  # row for the empty path, producing the misleading
  # `Completed. Hashed 1/0 files (failures=1)` line reported in the
  # v1.3.24 recheck. `xargs -r` is GNU-only, so we cannot rely on it.
  # Answer: handle TOTAL==0 explicitly and cleanly here — produce a
  # header-only CSV and report accurate 0/0/0 counts.
  if [[ "$TOTAL" -le 0 ]]; then
    info "No files to hash (0 discovered). CSV contains header only: $OUTPUT"
    if [[ "$SORT_OUTPUT" = "true" ]]; then
      _first_run_sort_notice
      sort_output_csv "$OUTPUT" || warn "CSV sort failed; header-only output retained"
    fi
    post_run_reports "$OUTPUT" "$CSV_TAG"
    return
  fi

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
  # v1.3.23 (peer-review recheck observation A): apply an upper bound.
  # Previously any positive integer was accepted, so a config typo like
  # `jobs = 10000` would spawn 10000 shells and hash processes on a NAS
  # — likely OOM or fork-bomb the box. Cap at min(cores*2, 64). A
  # deliberate operator can override via HASHER_MAX_JOBS.
  local _cores _hardmax
  if command -v nproc >/dev/null 2>&1; then
    _cores=$(nproc 2>/dev/null || echo 4)
  elif command -v sysctl >/dev/null 2>&1; then
    _cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  else
    _cores=4
  fi
  [[ -z "$_cores" || "$_cores" -lt 1 ]] && _cores=4
  _hardmax="${HASHER_MAX_JOBS:-}"
  if [[ -z "$_hardmax" ]]; then
    _hardmax=$(( _cores * 2 ))
    [[ "$_hardmax" -gt 64 ]] && _hardmax=64
  fi
  if [[ "$jobs" -gt "$_hardmax" ]]; then
    warn "Requested --jobs=$jobs exceeds safety cap ($_hardmax on this host); clamping."
    warn "  To override, set HASHER_MAX_JOBS=N in the environment before invoking."
    jobs="$_hardmax"
  fi

  if [[ "$jobs" -gt 1 ]]; then
    info "Parallel hashing enabled: $jobs workers."
  fi

  # The worker: reads ONE file path as $1, stats + hashes it, prints a CSV row
  # on success, or a FAIL sentinel line (prefixed with the NUL-safe marker) on
  # failure. Exported into the environment for `bash -c` invocation by xargs.
  # We pass ALGO and the hash command through the environment.
  _hash_worker() {
    local f="$1"
    local size mtime line hash fp1 fp2
    size=$(_stat_size "$f" 2>/dev/null || echo -1)
    mtime=$(_stat_mtime "$f" 2>/dev/null || echo -1)
    if [[ "$size" -lt 0 || "$mtime" -lt 0 ]]; then
      printf '\037FAIL\037stat\t%s\n' "$f"   # \037 = unit separator, unlikely in paths
      return 0
    fi
    # v1.3.25 (peer-review recheck #4): capture full identity fingerprint
    # before hashing (device, inode, size, mtime, ctime). Compare after
    # hashing. Reviewer demonstrated that comparing only size and
    # second-resolution mtime allowed a mutate+restore cycle to slip
    # through with the wrong hash. Any of the five fields changing
    # is treated as instability. Atomic replacement changes inode;
    # any write bumps ctime even if size and mtime are restored.
    fp1=$(_stat_fingerprint "$f" 2>/dev/null || echo "STAT_FAIL")
    if ! line=$("${hash_cmd[@]}" -- "$f" 2>/dev/null); then
      printf '\037FAIL\037hash\t%s\n' "$f"
      return 0
    fi
    hash="${line%% *}"
    # v1.3.24 (peer-review recheck finding #3), extended v1.3.25 #4:
    # re-fingerprint after hashing. If ANY of size/mtime/ctime/dev/ino
    # drifted, emit ONLY the CHANGED marker (no CSV row) and let the
    # main-loop dispatcher route it to `logs/unstable-files-<run>.log`.
    fp2=$(_stat_fingerprint "$f" 2>/dev/null || echo "STAT_FAIL")
    if [[ "$fp1" != "$fp2" ]]; then
      # \036 = record separator (rare in paths); handler in the main loop
      # writes this to an "unstable files" log. NO CSV row is emitted —
      # the file is excluded from the authoritative manifest.
      # Log the pre/post fingerprints so operators can diagnose which
      # attribute drifted (size|mtime|ctime|dev|ino format).
      printf '\036CHANGED\036%s\t%s\t%s\n' "$f" "$fp1" "$fp2"
      return 0
    fi
    # Stable snapshot: pre/post fingerprints agree. Write the CSV row.
    # csv_escape inline (worker runs in a subshell that has the function)
    local esc="${f//\"/\"\"}"
    printf '"%s",%s,%s,%s,%s\n' "$esc" "$size" "$mtime" "$ALGO" "$hash"
  }
  export -f _hash_worker _stat_size _stat_mtime _stat_fingerprint 2>/dev/null || true
  export ALGO
  # hash_cmd is an array; export its serialised form and rebuild in workers
  export HASH_CMD_STR="${hash_cmd[*]}"

  # Stream: NUL-delimited file list → xargs → workers → tee into a post-processor
  # that splits CSV rows (to $OUTPUT) from FAIL sentinels (counted).
  local fail_file="$VAR_DIR/hash-fails.$$"
  # v1.3.23 (finding #3): sink for files whose size/mtime changed DURING
  # hashing. Rows here are informational — the CSV still gets the row
  # (with pre-hash stats), but the operator sees which files were
  # unstable. Written to logs/ at the end alongside other artefacts.
  local changed_file="$VAR_DIR/hash-changed.$$"
  : > "$fail_file"
  : > "$changed_file"

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
            $'\036'CHANGED$'\036'*)
              printf '%s\n' "$row" >> "$changed_file"
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
    # v1.3.23 (finding #3): worker may emit two lines (CHANGED marker
    # followed by the CSV row) — process each independently.
    while IFS= read -r -d '' f; do
      local out
      out="$(_hash_worker "$f")"
      while IFS= read -r line; do
        case "$line" in
          $'\037'FAIL$'\037'*)
            printf '%s\n' "$line" >> "$fail_file"
            ;;
          $'\036'CHANGED$'\036'*)
            printf '%s\n' "$line" >> "$changed_file"
            ;;
          "")
            : ;;
          *)
            printf '%s\n' "$line" >> "$OUTPUT"
            ;;
        esac
      done <<< "$out"
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

  # v1.3.23 (finding #3): summarize files that changed during hashing.
  # Move the CHANGED log to logs/ with a run-tagged name so operators
  # can review after the run. The CSV rows for these files are already
  # written (with pre-hash stats) — this is informational only.
  # v1.3.24 (finding #3 + lower-priority cleanup): the log is renamed
  # from hash-changed-* to unstable-files-* because these rows are now
  # EXCLUDED from the manifest, not just annotated. Strip the internal
  # \036CHANGED\036 sentinel before moving to logs/ so operators can
  # cat/less the file without shell garbling.
  local changed_rows=0
  changed_rows=$(wc -l < "$changed_file" 2>/dev/null | tr -d ' ' || echo 0)
  [[ -z "$changed_rows" ]] && changed_rows=0
  if [[ "$changed_rows" -gt 0 ]]; then
    local unstable_log="$LOGS_DIR/unstable-files-$CSV_TAG.log"
    # Strip the leading \036CHANGED\036 sentinel from each line. Output
    # format after stripping: `<path>\t<size_pre>-><size_post>\t<mtime_pre>-><mtime_post>`
    {
      printf '# Unstable files — excluded from the CSV manifest.\n'
      printf '# Format: path<TAB>fingerprint_pre<TAB>fingerprint_post\n'
      printf '# Fingerprint fields: size|mtime|ctime|dev|ino\n'
      printf '# Generated: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')"
      printf '# Run tag: %s\n' "$CSV_TAG"
      # \036 is octal 036 → sed \x1e
      sed 's/^\x1eCHANGED\x1e//' "$changed_file" 2>/dev/null || cat "$changed_file"
    } > "$unstable_log" 2>/dev/null || true
    rm -f -- "$changed_file" 2>/dev/null || true
    warn "$changed_rows file(s) changed during hashing — EXCLUDED from CSV manifest."
    warn "  Review: $unstable_log"
    warn "  These files are missing from the CSV to preserve snapshot consistency."
    warn "  Re-run hasher on those paths when writes have settled."
  else
    rm -f -- "$changed_file" 2>/dev/null || true
  fi

  # v1.3.24 (finding #3): unstable files are counted toward DONE so
  # DONE + not-yet-processed == TOTAL. FAIL still means stat/hash
  # errors only. `unstable` is reported separately in the summary.
  DONE=$(( hashed_rows + fail_rows + changed_rows ))
  FAIL="$fail_rows"
  UNSTABLE="$changed_rows"

  local end_ts elapsed sH sM sS
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  sH=$((elapsed/3600)); sM=$((elapsed%3600/60)); sS=$((elapsed%60))

  stop_hash_progress

  # v1.3.24 (finding #3): mention unstable file count when non-zero so
  # DONE=$hashed_rows+$fail_rows+$changed_rows adds up transparently
  # v1.3.25 (peer-review recheck #3): report SEPARATE counts so
  # automation can distinguish outcomes. Previous format
  # `Hashed N/T files (failures=F, unstable=U)` was easily read as
  # "success" even when F or U == T. Exit codes now reflect reality:
  #   0 = all discovered files hashed successfully to the CSV
  #   1 = one or more stat/hash failures occurred
  #   4 = no hard failures, but one or more files unstable (excluded)
  # Reserved: 2 for invalid input/config, 3 for missing tools (kept from
  # earlier releases).
  local _successful=$(( DONE - FAIL - UNSTABLE ))
  [[ "$_successful" -lt 0 ]] && _successful=0
  info "Completed. Processed $DONE/$TOTAL files: hashed=$_successful, failed=$FAIL, unstable=$UNSTABLE. Elapsed: $(printf '%02d:%02d:%02d' "$sH" "$sM" "$sS"). CSV: $OUTPUT"

  # v1.3.22: sort the CSV by path for deterministic output and clean
  # cross-run diffing. Fail-safe: original is never touched until the
  # sorted candidate is validated. See sort_output_csv().
  if [[ "$SORT_OUTPUT" = "true" ]]; then
    _first_run_sort_notice
    sort_output_csv "$OUTPUT" || warn "CSV sort failed; unsorted output retained (see warnings above)"
  else
    info "CSV sort skipped (SORT_OUTPUT=$SORT_OUTPUT). Rows in worker-race order."
  fi

  # v1.3.25 (peer-review recheck #3): warn LOUDLY before publishing
  # next-step reports if the run is incomplete. Reviewer's concern:
  # automation and users can see the "Duplicate report ready: ..."
  # line and assume the snapshot is complete.
  if [[ "$FAIL" -gt 0 || "$UNSTABLE" -gt 0 ]]; then
    warn "========================================"
    warn "PARTIAL SNAPSHOT: CSV does NOT reflect the full input set."
    [[ "$FAIL"     -gt 0 ]] && warn "  - $FAIL file(s) failed to hash (see fail_file above)."
    [[ "$UNSTABLE" -gt 0 ]] && warn "  - $UNSTABLE file(s) excluded because they changed during hashing."
    warn "Downstream reports below are generated from this PARTIAL manifest."
    warn "Re-run hasher when writes have settled if a complete snapshot is required."
    warn "========================================"
  fi

  # Set the exit disposition BEFORE publishing reports. Failures trump
  # unstable (a run with both is a failed run).
  if [[ "$FAIL" -gt 0 ]]; then
    HASHER_RUN_STATUS=1
    warn "Run completed with $FAIL hash/stat failure(s) — CSV is INCOMPLETE. Exit status: 1"
  elif [[ "$UNSTABLE" -gt 0 ]]; then
    HASHER_RUN_STATUS=4
    warn "Run completed but $UNSTABLE file(s) excluded as unstable — CSV is a PARTIAL snapshot. Exit status: 4"
  else
    HASHER_RUN_STATUS=0
  fi

  # v1.3.26: incomplete snapshots must not look like normal `hasher-*.csv`
  # files, because the launcher and direct duplicate tools intentionally pick
  # that pattern as the latest actionable manifest. Retain the diagnostic CSV
  # under a `partial-` prefix and leave a marker beside custom output paths.
  local publish_latest=true
  if [[ "$HASHER_RUN_STATUS" -ne 0 ]]; then
    publish_latest=false
    local _out_dir _out_base _partial_out _n
    _out_dir="$(dirname -- "$OUTPUT")"
    _out_base="$(basename -- "$OUTPUT")"
    if [[ "$_out_base" == hasher-*.csv ]]; then
      _partial_out="$_out_dir/partial-$_out_base"
      if [[ -e "$_partial_out" ]]; then
        _n=1
        while [[ -e "${_partial_out}.dup${_n}" ]]; do _n=$((_n+1)); done
        _partial_out="${_partial_out}.dup${_n}"
      fi
      if mv -f -- "$OUTPUT" "$_partial_out"; then
        OUTPUT="$_partial_out"
      else
        warn "Could not rename partial manifest; marking it with ${OUTPUT}.partial"
        : > "${OUTPUT}.partial" 2>/dev/null || true
      fi
    else
      : > "${OUTPUT}.partial" 2>/dev/null || true
    fi
    warn "Partial manifest retained for diagnosis only: $OUTPUT"
    warn "It was NOT promoted as the latest actionable snapshot."
  else
    rm -f -- "${OUTPUT}.partial" 2>/dev/null || true
  fi

  post_run_reports "$OUTPUT" "$CSV_TAG" "$publish_latest"

  # v1.3.29: automatic post-hash duplicate discovery. Runs folder discovery
  # first (recommended ordering — dedup folders before files), then file
  # discovery. Both use the CSV that was just produced. Results land in
  # logs/ with the same timestamp convention, ready for immediate review
  # when the user returns.
  #
  # Safety: NEVER run discovery on a partial manifest. A CSV with failures
  # or unstable exclusions would produce misleading duplicate groups.
  # Also skip if the CSV has no data rows (header-only / empty-input run).
  if [[ "$AUTO_FIND_DUPLICATE_FOLDERS" = "true" || "$AUTO_FIND_DUPLICATE_FILES" = "true" ]]; then
    if [[ "$HASHER_RUN_STATUS" -ne 0 ]]; then
      bglog INFO "Post-hash discovery: SKIPPED — manifest is partial (status=$HASHER_RUN_STATUS)."
      info "Post-hash discovery skipped: manifest is partial. Run discovery manually after a complete hash."
    elif [[ "$(wc -l < "$OUTPUT" 2>/dev/null | tr -d ' ')" -lt 2 ]]; then
      bglog INFO "Post-hash discovery: SKIPPED — CSV has no data rows."
      info "Post-hash discovery skipped: CSV has no data rows."
    else
      if [[ "$ANALYSIS_MODE" = "automatic" ]]; then
        _run_post_hash_discovery "$OUTPUT"
      else
        info "Post-hash duplicate analysis is set to manual; discovery not run."
        bglog INFO "Post-hash discovery skipped: analysis_mode=manual"
      fi
    fi
  fi
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

# ───────────────────────── Post-hash Discovery (v1.3.29) ───
# Automatically run duplicate-folder and duplicate-file discovery after a
# successful hash run, so reports are waiting in logs/ when the user returns.
# Called only when AUTO_DISCOVER=true AND the manifest is complete (rc=0).
#
# Each tool is invoked as a subprocess with --input pointing at the CSV that
# was just produced. Failures are logged as warnings but do NOT change the
# hash run's exit status — the CSV is the primary deliverable.
#
# Ordering: folders first, then files — matching the menu note that says
# "dedup FOLDERS before FILES."
_run_post_hash_discovery() {
  local _csv="$1"
  local _disc_start _disc_end _disc_elapsed
  local _folder_groups=0 _folders_to_quarantine=0 _file_groups=0
  local _folder_status=disabled _file_status=disabled
  local _folder_before="" _folder_after="" _file_report="" _file_source=""
  _disc_start=$(date +%s)
  _folder_before=$(ls -1t "$LOGS_DIR"/duplicate-folders-groups-[0-9]*.tsv 2>/dev/null | head -n1 || true)

  info ""
  info "───────────────────────────────────────────────────────────────"
  info "Post-hash discovery: analysing manifest for duplicates..."
  info "  folders=$AUTO_FIND_DUPLICATE_FOLDERS files=$AUTO_FIND_DUPLICATE_FILES review-index=$AUTO_BUILD_REVIEW_INDEX"
  info "───────────────────────────────────────────────────────────────"
  bglog INFO "Post-hash discovery starting: input=$_csv"

  # 1. Duplicate folders
  local _folder_rc=0
  if [[ "$AUTO_FIND_DUPLICATE_FOLDERS" != "true" ]]; then
    _folder_status=disabled
    bglog INFO "Post-hash discovery: duplicate-folder scan disabled."
    info "Post-hash discovery [1/2]: duplicate-folder scan disabled."
  elif [[ -x "$ROOT_DIR/bin/find-duplicate-folders.sh" ]] || [[ -r "$ROOT_DIR/bin/find-duplicate-folders.sh" ]]; then
    info ""
    info "Post-hash discovery [1/2]: finding duplicate folders..."
    bglog INFO "Post-hash discovery: running find-duplicate-folders.sh"
    if bash "$ROOT_DIR/bin/find-duplicate-folders.sh" \
        --input "$_csv" \
        --mode plan \
        --keep shortest-path; then
      _folder_status=ready
      _folder_after=$(ls -1t "$LOGS_DIR"/duplicate-folders-groups-[0-9]*.tsv 2>/dev/null | head -n1 || true)
      if [[ -n "$_folder_after" && "$_folder_after" != "$_folder_before" ]]; then
        _folders_to_quarantine=$(wc -l < "$_folder_after" 2>/dev/null | tr -d ' ' || echo 0)
        _folder_groups=$(awk -F '\t' '{seen[$2]=1} END{for(k in seen)n++; print n+0}' "$_folder_after" 2>/dev/null || echo 0)
      fi
      bglog INFO "Post-hash discovery: folder scan completed successfully."
    else
      _folder_rc=$?
      _folder_status=failed
      bglog WARN "Post-hash discovery: folder scan exited with rc=$_folder_rc"
      warn "Post-hash folder discovery returned rc=$_folder_rc (see warnings above)."
      warn "  This does not affect the hash manifest. Use launcher option 'r' to rerun folder analysis."
    fi
  else
    _folder_status=failed
    bglog INFO "Post-hash discovery: find-duplicate-folders.sh not found; skipping folder scan."
  fi

  # 2. Duplicate files
  local _file_rc=0
  if [[ "$AUTO_FIND_DUPLICATE_FILES" != "true" ]]; then
    _file_status=disabled
    bglog INFO "Post-hash discovery: duplicate-file scan disabled."
    info "Post-hash discovery [2/2]: duplicate-file scan disabled."
  elif [[ -x "$ROOT_DIR/bin/find-duplicates.sh" ]] || [[ -r "$ROOT_DIR/bin/find-duplicates.sh" ]]; then
    info ""
    info "Post-hash discovery [2/2]: finding duplicate files..."
    bglog INFO "Post-hash discovery: running find-duplicates.sh"
    _file_args=( --input "$_csv" )
    [[ "$AUTO_BUILD_REVIEW_INDEX" = "true" ]] || _file_args+=( --no-review-index )
    if bash "$ROOT_DIR/bin/find-duplicates.sh" "${_file_args[@]}"; then
      _file_status=ready
      _file_report="$LOGS_DIR/duplicate-hashes-latest.txt"
      if [[ -r "$_file_report" ]]; then
        _file_source=$(awk -F': ' '/^# source-csv: /{print $2; exit}' "$_file_report" 2>/dev/null || true)
        if [[ "$_file_source" = "$_csv" ]]; then
          _file_groups=$(grep -c '^HASH ' "$_file_report" 2>/dev/null || true)
        fi
      fi
      bglog INFO "Post-hash discovery: file scan completed successfully."
    else
      _file_rc=$?
      _file_status=failed
      bglog WARN "Post-hash discovery: file scan exited with rc=$_file_rc"
      warn "Post-hash file discovery returned rc=$_file_rc (see warnings above)."
      warn "  This does not affect the hash manifest. Use launcher option 'r' to rerun file analysis."
    fi
  else
    _file_status=failed
    bglog INFO "Post-hash discovery: find-duplicates.sh not found; skipping file scan."
  fi

  _disc_end=$(date +%s)
  _disc_elapsed=$(( _disc_end - _disc_start ))
  local _dM=$(( _disc_elapsed / 60 )) _dS=$(( _disc_elapsed % 60 ))

  info ""
  info "───────────────────────────────────────────────────────────────"
  info "Post-hash discovery complete (${_dM}m ${_dS}s)."
  if [[ "$_folder_rc" -eq 0 && "$_file_rc" -eq 0 ]]; then
    info "  Results are in logs/ — use option 2 (folders) or 3 (files) to review."
    if [[ "$AUTO_FIND_DUPLICATE_FILES" = "true" && "$AUTO_BUILD_REVIEW_INDEX" = "true" ]]; then
      info "  File review index is prepared; option 3 should skip the long indexing stage."
    fi
  else
    warn "  One or both discovery scans had issues (see warnings above)."
    warn "  Hash manifest is unaffected. Re-run options 2/3 manually if needed."
  fi
  info "───────────────────────────────────────────────────────────────"

  # v1.3.32: publish a compact, run-matched summary for the launcher menu.
  local _summary_tag _summary_file _summary_tmp _files_hashed
  _summary_tag=$(basename "$_csv" .csv)
  _summary_file="$LOGS_DIR/post-hash-analysis-${_summary_tag}.meta"
  _summary_tmp="$LOGS_DIR/post-hash-analysis-latest.meta.tmp.$$"
  _files_hashed=$(( $(wc -l < "$_csv" 2>/dev/null | tr -d ' ' || echo 1) - 1 ))
  (( _files_hashed < 0 )) && _files_hashed=0
  {
    printf '# HASHER_POST_HASH_ANALYSIS v1\n'
    printf 'source_csv=%s\n' "$_csv"
    printf 'completed=%s\n' "$(date '+%F %H:%M')"
    printf 'files_hashed=%s\n' "$_files_hashed"
    printf 'folder_status=%s\n' "$_folder_status"
    printf 'folder_groups=%s\n' "${_folder_groups:-0}"
    printf 'folders_to_quarantine=%s\n' "${_folders_to_quarantine:-0}"
    printf 'file_status=%s\n' "$_file_status"
    printf 'file_groups=%s\n' "${_file_groups:-0}"
  } > "$_summary_file"
  cp -f -- "$_summary_file" "$_summary_tmp" && mv -f -- "$_summary_tmp" "$LOGS_DIR/post-hash-analysis-latest.meta"

  bglog INFO "Post-hash discovery finished in ${_dM}m ${_dS}s (folders=$_folder_rc, files=$_file_rc)"
}

# ───────────────────────── Post-run Reports ────────────────
post_run_reports() {
  local csv="$1"
  local run_tag="$2"  # v1.3.19 (finding #5): full run tag (F-HMS-PID),
                       # not just DATE_TAG. Same-day runs no longer overwrite.
  local publish_latest="${3:-true}"

  mkdir -p "$LOGS_DIR" "$ZERO_DIR"

  # v1.3.19 (peer-review finding #5): derived reports now include the run
  # tag so same-day runs don't overwrite each other. Two convenience
  # symlinks (*-latest.txt) always point at the newest report of each kind
  # — that's what next-step commands print, so they stay stable while
  # historical reports accumulate.
  local zero_txt="$ZERO_DIR/zero-length-$run_tag.txt"
  # v1.3.28: this is a preliminary summary from the raw hash manifest, not
  # the hard-link-filtered report produced by find-duplicates.sh. Keep the
  # namespaces separate so review/auto-dedup can consume only verified finder
  # output.
  local dupes_txt="$LOGS_DIR/hash-scan-duplicate-summary-$run_tag.txt"
  local zero_latest="$ZERO_DIR/zero-length-latest.txt"
  local dupes_latest="$LOGS_DIR/hash-scan-duplicate-summary-latest.txt"

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

  # Only complete snapshots may replace the stable latest pointers. Partial
  # run-specific reports are retained for diagnosis but never promoted.
  if [[ "$publish_latest" = "true" ]]; then
    if ln -sfn -- "$(basename "$zero_txt")" "$zero_latest" 2>/dev/null; then :; else
      rm -f -- "$zero_latest" 2>/dev/null || true
      cp -f -- "$zero_txt" "$zero_latest" 2>/dev/null || true
    fi
    if ln -sfn -- "$(basename "$dupes_txt")" "$dupes_latest" 2>/dev/null; then :; else
      rm -f -- "$dupes_latest" 2>/dev/null || true
      cp -f -- "$dupes_txt" "$dupes_latest" 2>/dev/null || true
    fi
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
  if [[ "$publish_latest" = "true" ]]; then
    if [[ "$AUTO_FIND_DUPLICATE_FOLDERS" = "true" || "$AUTO_FIND_DUPLICATE_FILES" = "true" ]]; then
      echo -e "${GREEN}[POST-HASH ANALYSIS]${NC}"
      [[ "$AUTO_FIND_DUPLICATE_FOLDERS" = "true" ]] && echo "  • Duplicate-folder discovery will run next."
      [[ "$AUTO_FIND_DUPLICATE_FILES" = "true" ]] && echo "  • Duplicate-file discovery will run next."
      [[ "$AUTO_FIND_DUPLICATE_FILES" = "true" && "$AUTO_BUILD_REVIEW_INDEX" = "true" ]] \
        && echo "  • The interactive review index will be prepared for option 4."
      echo "  • Discovery creates reports only; it never reviews, quarantines, or deletes files."
      echo
      echo -e "${GREEN}[AFTER DISCOVERY]${NC}"
      [[ "$AUTO_FIND_DUPLICATE_FOLDERS" = "true" ]] && echo "  1) Review duplicate folders with menu option r."
      [[ "$AUTO_FIND_DUPLICATE_FILES" = "true" ]] && echo "  2) Review duplicate files with menu option 4."
    else
      echo -e "${GREEN}[RECOMMENDED NEXT STEPS]${NC}"
      echo "  1) Find duplicate folders (highest value, lowest risk):"
      echo "       bin/find-duplicate-folders.sh --input \"$csv\""
      echo "  2) Find and review duplicate files:"
      echo "       bin/find-duplicates.sh --input \"$csv\""
      echo "       bin/review-duplicates.sh --from-report \"$LOGS_DIR/duplicate-hashes-latest.txt\""
    fi
    echo "  3) Remove zero-length files (review first, no changes):"
    echo "       bin/delete-zero-length.sh --report \"$zero_txt\" --dry-run"
    echo "       bin/delete-zero-length.sh --report \"$zero_txt\" --force"
  else
    warn "No dedupe or cleanup commands are recommended from this partial snapshot."
    warn "Re-run hashing successfully before using the normal review/apply workflow."
  fi
  echo
}

# ───────────────────────── Execute ─────────────────────────
main
