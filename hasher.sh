#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute <jameswinter@protonmail.ch>
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Constants ───────────────────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"

ALGO="sha256"        # sha256|sha1|sha512|md5|blake2
PATHFILE=""
RUN_IN_BACKGROUND=false
IS_CHILD=false       # set when re-exec'ed under nohup

# Config sources
CONFIG_FILE=""       # INI config via --config
EXCLUDE_FILE=""      # legacy plain excludes file
: "${HASHER_CONFIG:=}"   # env fallback (parent exports to child)

PROGRESS_INTERVAL=15 # seconds (override via config [logging] background-interval)
LOG_LEVEL="info"     # debug|info|warn|error (override via config)
XTRACE=false         # enable 'set -x' if true (override via config)

PASSED_RUN_ID=""     # parent passes to child so IDs match

# ───────────────────── Built-in excludes ───────────────────
read -r -d '' EXCLUDE_DEFAULTS <<'GLOBS' || true
*@eaDir*
*/#recycle/*
*/.Recycle.Bin/*
*/.Trash*/**
*/lost+found/*
*/.Spotlight-V100/*
*/.fseventsd/*
*/.AppleDouble/*
*/._*
*.DS_Store
Thumbs.db
*.part
*.tmp
*/.synology*/**
*@SynoResource*
GLOBS
INHERIT_DEFAULT_EXCLUDES=true

# ───────────────────────── Helpers ─────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

gen_run_id() {
  if [[ -n "${PASSED_RUN_ID:-}" ]]; then
    printf '%s' "$PASSED_RUN_ID"
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}

# Level filter
lvl_rank() {
  case "$1" in debug) echo 10 ;; info) echo 20 ;; warn) echo 30 ;; error) echo 40 ;; *) echo 20 ;; esac
}
LOG_RANK=$(lvl_rank "$LOG_LEVEL")

RUN_ID="$(gen_run_id)"     # set early so errors include a Run-ID
BACKGROUND_LOG=""          # symlink to per-run log (for tail -f)
LOG_FILE=""                # per-run log: logs/hasher-$RUN_ID.log
FILELIST=""                # per-run file list: logs/files-$RUN_ID.lst

_log_core() {
  # $1=LEVEL, $2=msg
  local level="$1"; shift
  local line; line=$(printf '[%s] [RUN %s] [%s] %s\n' "$(ts)" "$RUN_ID" "$level" "$*")
  if $IS_CHILD; then
    printf '%s\n' "$line" >&1
  else
    printf '%s\n' "$line" >&1
    { printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
  fi
}
log() {
  # honor level
  local level="$1"; shift || true
  local want=$(lvl_rank "$level")
  if (( want >= LOG_RANK )); then _log_core "$level" "$@"; fi
}

die() { _log_core ERROR "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --pathfile paths.txt [--algo sha256|sha1|sha512|md5|blake2]
                   [--nohup] [--config hasher.conf] [--exclude-file excludes.txt]

Flags:
  --pathfile FILE        File with one path per line (# comments ok)
  --algo NAME            sha256|sha1|sha512|md5|blake2 (default sha256)
  --nohup                Re-exec in background (live log: logs/background.log)
  --config FILE          INI config ([logging] background-interval, level, xtrace; [exclusions] …)
  --exclude-file FILE    Legacy extra globs (ignored if --config supplied)
  -h|--help              Show help

CSV columns: timestamp,path,algo,hash,size_mb
EOF
}

csv_quote() { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }

portable_stat_size() {
  local f="$1"
  if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"
  elif stat -f%z "$f" >/dev/null 2>&1; then stat -f%z "$f"
  else wc -c <"$f" | tr -d ' '
  fi
}

format_secs() { local s=$1; (( s<0 )) && s=0; printf '%02d:%02d:%02d' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"; }

percent_of() {
  local p="$1" t="$2"
  if (( t<=0 )); then echo 0; return; fi
  local pct=$(( (p * 100) / t ))
  (( pct<0 )) && pct=0
  (( pct>100 )) && pct=100
  echo "$pct"
}

# ─────────────────────── INI parser ────────────────────────
parse_ini() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local section="" line key val raw
  while IFS= read -r line || [[ -n "$line" ]]; do
    raw="${line%%[#;]*}"
    raw="$(echo -n "$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$raw" ]] && continue
    if [[ "$raw" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1],,}"; continue; fi
    case "$section" in
      logging)
        if [[ "$raw" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
          key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
          case "$key" in
            background-interval|progress-interval) [[ "$val" =~ ^[0-9]+$ ]] && PROGRESS_INTERVAL="$val" ;;
            level) LOG_LEVEL="${val,,}"; LOG_RANK=$(lvl_rank "$LOG_LEVEL") ;;
            xtrace) case "${val,,}" in true|1|yes) XTRACE=true ;; *) XTRACE=false ;; esac ;;
          esac
        fi
        ;;
      exclusions)
        if [[ "$raw" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
          key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
          case "$key" in
            glob) EXCLUDE_GLOBS+=("$val") ;;
            inherit-defaults)
              case "${val,,}" in false|no|0) INHERIT_DEFAULT_EXCLUDES=false ;; true|yes|1) INHERIT_DEFAULT_EXCLUDES=true ;; esac
              ;;
          esac
        else
          EXCLUDE_GLOBS+=("$raw")
        fi
        ;;
    esac
  done <"$file"
}

# ───────────────────────── Excludes ────────────────────────
declare -a EXCLUDE_GLOBS=()
load_excludes() {
  # 1) Config file (flag)
  if [[ -n "$CONFIG_FILE" ]]; then parse_ini "$CONFIG_FILE"; fi
  # 2) Fallback env var if flag not set
  if [[ -z "$CONFIG_FILE" && -n "$HASHER_CONFIG" && -f "$HASHER_CONFIG" ]]; then
    CONFIG_FILE="$HASHER_CONFIG"
    parse_ini "$CONFIG_FILE"
  fi
  # 3) Legacy exclude file (only if no config)
  if [[ -z "$CONFIG_FILE" && -n "$EXCLUDE_FILE" && -f "$EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      EXCLUDE_GLOBS+=("$line")
    done <"$EXCLUDE_FILE"
  fi
  # built-ins unless disabled
  if $INHERIT_DEFAULT_EXCLUDES; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      EXCLUDE_GLOBS+=("$line")
    done <<<"$EXCLUDE_DEFAULTS"
  fi
  # never hash our own outputs
  EXCLUDE_GLOBS+=("$HASHES_DIR/*")
}

is_excluded() {
  local path="$1"
  for pat in "${EXCLUDE_GLOBS[@]}"; do
    [[ "$path" == $pat ]] && return 0
  done
  return 1
}

resolve_algo_cmd() {
  case "$ALGO" in
    sha256)  HASH_CMD="sha256sum"; ALGO_NAME="sha256" ;;
    sha1)    HASH_CMD="sha1sum";   ALGO_NAME="sha1" ;;
    sha512)  HASH_CMD="sha512sum"; ALGO_NAME="sha512" ;;
    md5)     HASH_CMD="md5sum";    ALGO_NAME="md5" ;;
    blake2)  HASH_CMD="b2sum";     ALGO_NAME="blake2" ;;
    *) log WARN "Unknown --algo '$ALGO'. Defaulting to sha256."; HASH_CMD="sha256sum"; ALGO_NAME="sha256" ;;
  esac
  command -v "$HASH_CMD" >/dev/null 2>&1 || die "Required command '$HASH_CMD' not found."
}

# ───────────────────── Argument parsing ────────────────────
while (($#)); do
  case "${1:-}" in
    --pathfile)      PATHFILE="${2:-}"; shift 2 ;;
    --algo)          ALGO="${2:-}"; shift 2 ;;
    --nohup)         RUN_IN_BACKGROUND=true; shift ;;
    --headless)      IS_CHILD=true; shift ;;                 # internal
    --run-id)        PASSED_RUN_ID="${2:-}"; RUN_ID="$PASSED_RUN_ID"; shift 2 ;;  # internal
    --exclude-file)  EXCLUDE_FILE="${2:-}"; shift 2 ;;
    --config)        CONFIG_FILE="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    --*)             log WARN "Ignoring unknown flag: $1"; shift ;;
    *)               log WARN "Ignoring unexpected arg: $1"; shift ;;
  esac
done

[[ -n "$PATHFILE" && -f "$PATHFILE" ]] || die "Please provide --pathfile FILE (found: '$PATHFILE')."

# Initialize per-run paths
BACKGROUND_LOG="$LOGS_DIR/background.log"
LOG_FILE="$LOGS_DIR/hasher-$RUN_ID.log"
FILELIST="$LOGS_DIR/files-$RUN_ID.lst"

mkdir -p "$HASHES_DIR" "$LOGS_DIR"
: >"$LOG_FILE"
ln -sfn "$(basename "$LOG_FILE")" "$LOGS_DIR/hasher.log" || true
ln -sfn "$(basename "$LOG_FILE")" "$BACKGROUND_LOG"      || true

# Optional shell tracing to the log (GNU bash supports BASH_XTRACEFD)
if $XTRACE 2>/dev/null; then
  exec {__xtrace_fd}>>"$LOG_FILE" || true
  if [[ -n "${__xtrace_fd:-}" ]]; then
    export BASH_XTRACEFD="$__xtrace_fd"
    set -x
  fi
fi

resolve_algo_cmd
load_excludes

# ─────────────────────── Background mode (robust) ──────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  export HASHER_CONFIG="${CONFIG_FILE}"
  nohup bash "$0" \
    --pathfile "$PATHFILE" --algo "$ALGO" \
    ${CONFIG_FILE:+--config "$CONFIG_FILE"} \
    ${EXCLUDE_FILE:+--exclude-file "$EXCLUDE_FILE"} \
    --run-id "$RUN_ID" --headless >>"$LOG_FILE" 2>&1 &
  pid=$!
  printf 'Hasher started with nohup (PID %s). Run-ID: %s. Output: %s\n' "$pid" "$RUN_ID" "$OUTPUT"
  exit 0
fi

# ─────────────────────── Startup log ───────────────────────
log INFO "Run-ID: $RUN_ID"
log INFO "Config: ${CONFIG_FILE:-${HASHER_CONFIG:-<none>}} | Progress interval: ${PROGRESS_INTERVAL}s | Inherit default excludes: ${INHERIT_DEFAULT_EXCLUDES} | Level: ${LOG_LEVEL}"
log INFO "Hasher initiated — please standby; initial file discovery may take some time."
log INFO "Preparing file list..."

# Ensure CSV header exists
if [[ ! -s "$OUTPUT" ]]; then
  printf '"timestamp","path","algo","hash","size_mb"\n' >"$OUTPUT"
fi

# Load search paths
declare -a SEARCH_PATHS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo -n "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -z "$line" ]] && continue
  SEARCH_PATHS+=("$line")
done <"$PATHFILE"
((${#SEARCH_PATHS[@]})) || die "No valid paths in $PATHFILE."

# ───────────── Discovery (FIFO-based, BusyBox-safe) ────────
DISCOVERY_START=$(date +%s)
DISC_LAST_PRINT=$DISCOVERY_START
DISCOVERED=0
: >"$FILELIST"

FIFO="$LOGS_DIR/.findfifo-$RUN_ID"
cleanup_fifo() { [[ -p "$FIFO" ]] && rm -f "$FIFO" || true; }
trap cleanup_fifo EXIT INT TERM
mkfifo "$FIFO"

# Start find in the background writing NUL-delimited paths to FIFO
(
  # One 'find' per root so we still get early streaming if one path is huge
  for p in "${SEARCH_PATHS[@]}"; do
    if [[ -d "$p" || -f "$p" ]]; then
      find "$p" -type f -print0 2>/dev/null || true
    else
      printf '[%s] [RUN %s] [WARN] Path does not exist or is not accessible: %s\n' "$(ts)" "$RUN_ID" "$p" >"$FIFO"
    fi
  done
) >"$FIFO" &
FIND_PID=$!

# Reader: consume from FIFO in the *current* shell (no subshell), apply excludes, build FILELIST, heartbeat
while true; do
  IFS= read -r -d '' f <"$FIFO" || break
  # Skip any injected WARN lines (if a path was missing and echoed into FIFO)
  if [[ "$f" == \[*WARN* ]]; then _log_core WARN "${f#*WARN] }"; continue; fi
  if ! is_excluded "$f"; then
    printf '%s\0' "$f" >>"$FILELIST"
    ((DISCOVERED+=1))
  fi
  now=$(date +%s)
  if (( now - DISC_LAST_PRINT >= PROGRESS_INTERVAL )); then
    log PROGRESS "Discovery: scanned=$DISCOVERED (last: $f)"
    DISC_LAST_PRINT=$now
  fi
done

# Wait for find to finish (avoid zombies)
wait "$FIND_PID" 2>/dev/null || true
cleanup_fifo

TOTAL="$DISCOVERED"
DISCOVERY_END=$(date +%s)
log INFO "Discovery complete: total_files=$TOTAL took=$(format_secs $((DISCOVERY_END-DISCOVERY_START)))"
log INFO "File list saved: $FILELIST"

# ───────────────────────── Hashing ─────────────────────────
START_TS=$(date +%s)
PROCESSED=0
FAILED=0
LAST_PRINT=$START_TS

log INFO "Starting hash: algo=$ALGO total_files=$TOTAL output=$OUTPUT"

trap 'log WARN "Interrupted. Processed ${PROCESSED}/${TOTAL}. Failed=${FAILED}. Partial CSV: ${OUTPUT}"' INT TERM

progress_tick() {
  local now elapsed eta rem pct
  now=$(date +%s)
  elapsed=$((now - START_TS))
  rem=$(( TOTAL - PROCESSED )); (( rem<0 )) && rem=0
  eta=$(( PROCESSED>0 ? (elapsed * rem / PROCESSED) : 0 ))
  pct=$(percent_of "$PROCESSED" "$TOTAL")
  log PROGRESS "Hashing: [${pct}%] ${PROCESSED}/${TOTAL} | elapsed=$(format_secs "$elapsed") eta=$(format_secs "$eta")"
}

hash_one() {
  local f="$1"
  if [[ ! -r "$f" ]]; then ((FAILED+=1)); log WARN "Skipped (missing/unreadable): $f"; return 1; fi
  local sum
  # BusyBox-friendly: strip after first whitespace
  if ! sum="$("$HASH_CMD" -- "$f" 2>/dev/null | sed 's/[[:space:]].*$//')"; then
    ((FAILED+=1)); log WARN "Failed to hash: $f"; return 1
  fi
  local bytes size_mb
  bytes="$(portable_stat_size "$f" 2>/dev/null || echo 0)"
  size_mb="$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1048576}')"
  local row
  row="$(csv_quote "$(ts)"),$(csv_quote "$f"),$(csv_quote "$ALGO"),$(csv_quote "$sum"),$(csv_quote "$size_mb")"
  printf '%s\n' "$row" >>"$OUTPUT"
  return 0
}

if (( TOTAL == 0 )); then
  log WARN "No files discovered. Nothing to hash."
else
  while IFS= read -r -d '' f; do
    if hash_one "$f"; then ((PROCESSED+=1)); fi
    now=$(date +%s)
    if (( now - LAST_PRINT >= PROGRESS_INTERVAL )) || (( PROCESSED == TOTAL )); then
      progress_tick
      LAST_PRINT=$now
    fi
  done <"$FILELIST"
fi

# ───────────────────────── Summary ─────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
log INFO "Completed. Hashed ${PROCESSED}/${TOTAL} files (failures=${FAILED}) in $(format_secs "$ELAPSED"). CSV: $OUTPUT"
