#!/usr/bin/env bash
# hasher.sh — robust file hasher with CSV output, background mode,
# Run-ID (consistent parent/child), INI config, per-run logs, unique file list, and heartbeats.

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
IS_CHILD=false

CONFIG_FILE=""       # preferred: INI file
EXCLUDE_FILE=""      # legacy: extra globs only

PROGRESS_INTERVAL=15 # default seconds (override via config [logging] background-interval)
PASSED_RUN_ID=""     # internal: provided by parent to child so Run-ID matches

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
  elif command -v uuidgen >/devnull 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}

# Will be set after parsing args (since PASSED_RUN_ID may be provided)
RUN_ID=""

# These depend on RUN_ID; set after RUN_ID is initialized
BACKGROUND_LOG=""          # symlink to per-run log for tail -f
LOG_FILE=""                # per-run log: logs/hasher-$RUN_ID.log
FILELIST=""                # per-run file list: logs/files-$RUN_ID.lst

log() {
  local level="$1"; shift || true
  local line
  line=$(printf '[%s] [RUN %s] [%s] %s\n' "$(ts)" "$RUN_ID" "$level" "$*")
  printf '%s\n' "$line" >&1
  { printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}

die() { log ERROR "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --pathfile paths.txt [--algo sha256|sha1|sha512|md5|blake2] [--nohup]
                   [--config hasher.conf] [--exclude-file excludes.txt]

Flags:
  --pathfile FILE        File with one path per line (# comments ok)
  --algo NAME            sha256|sha1|sha512|md5|blake2 (default sha256)
  --nohup                Re-exec in background (live log: logs/background.log)
  --config FILE          INI config ([logging] background-interval=SECONDS; [exclusions] …)
  --exclude-file FILE    Legacy extra globs (ignored if --config supplied)
  -h|--help              Show help

INI example:
  [logging]
  background-interval = 5
  [exclusions]
  inherit-defaults = true
  *.tmp
  */Cache/*
  glob = */.Trash*/**

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
  if [[ -n "$CONFIG_FILE" ]]; then parse_ini "$CONFIG_FILE"; fi
  if [[ -z "$CONFIG_FILE" && -n "$EXCLUDE_FILE" && -f "$EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      EXCLUDE_GLOBS+=("$line")
    done <"$EXCLUDE_FILE"
  fi
  if $INHERIT_DEFAULT_EXCLUDES; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      EXCLUDE_GLOBS+=("$line")
    done <<<"$EXCLUDE_DEFAULTS"
  fi
  EXCLUDE_GLOBS+=("$HASHES_DIR/*")  # never hash our own outputs
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
    *) die "Unknown --algo '$ALGO'. Use sha256|sha1|sha512|md5|blake2." ;;
  esac
  command -v "$HASH_CMD" >/dev/null 2>&1 || die "Required command '$HASH_CMD' not found."
}

percent_of() {
  local p="$1" t="$2"
  if (( t<=0 )); then echo 0; return; fi
  local pct=$(( (p * 100) / t ))
  (( pct<0 )) && pct=0
  (( pct>100 )) && pct=100
  echo "$pct"
}

# ───────────────────── Argument parsing ────────────────────
while (($#)); do
  case "${1:-}" in
    --pathfile)      PATHFILE="${2:-}"; shift 2 ;;
    --algo)          ALGO="${2:-}"; shift 2 ;;
    --nohup)         RUN_IN_BACKGROUND=true; shift ;;
    --headless)      IS_CHILD=true; shift ;;                 # internal
    --run-id)        PASSED_RUN_ID="${2:-}"; shift 2 ;;     # internal: parent passes to child
    --exclude-file)  EXCLUDE_FILE="${2:-}"; shift 2 ;;
    --config)        CONFIG_FILE="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown arg: $1 (use -h for help)";;
  esac
done

[[ -n "$PATHFILE" && -f "$PATHFILE" ]] || die "Please provide --pathfile FILE (found: '$PATHFILE')."

# Initialize RUN_ID and per-run paths
RUN_ID="$(gen_run_id)"
BACKGROUND_LOG="$LOGS_DIR/background.log"            # symlink to per-run log
LOG_FILE="$LOGS_DIR/hasher-$RUN_ID.log"              # per-run log file
FILELIST="$LOGS_DIR/files-$RUN_ID.lst"               # per-run file list

mkdir -p "$HASHES_DIR" "$LOGS_DIR"

# Touch per-run log so symlinks have a target; then create/update symlinks
: >"$LOG_FILE"
ln -sfn "$(basename "$LOG_FILE")" "$LOGS_DIR/hasher.log" || true
ln -sfn "$(basename "$LOG_FILE")" "$BACKGROUND_LOG"      || true

resolve_algo_cmd
load_excludes

# ─────────────────────── Background mode (FIXED) ───────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  # Launch child in nohup, append directly to per-run log; no subshell indirection
  nohup bash "$0" \
    --pathfile "$PATHFILE" --algo "$ALGO" \
    ${CONFIG_FILE:+--config "$CONFIG_FILE"} \
    ${EXCLUDE_FILE:+--exclude-file "$EXCLUDE_FILE"} \
    --run-id "$RUN_ID" --headless \
    >>"$LOG_FILE" 2>&1 &

  pid=$!
  # Symlinks already point to $LOG_FILE, so tailing works immediately
  printf 'Hasher started with nohup (PID %s). Run-ID: %s. Output: %s\n' "$pid" "$RUN_ID" "$OUTPUT"
  exit 0
fi

# ─────────────────────── Preparation ───────────────────────
log INFO "Run-ID: $RUN_ID"
log INFO "Config: ${CONFIG_FILE:-<none>} | Progress interval: ${PROGRESS_INTERVAL}s | Inherit default excludes: ${INHERIT_DEFAULT_EXCLUDES}"
log INFO "Hasher initiated — please standby; initial file discovery may take some time."

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

# ───────────── Discovery → unique file list with heartbeat ─
log INFO "Preparing file list..."
DISCOVERY_START=$(date +%s)
DISC_LAST_PRINT=$DISCOVERY_START
DISCOVERED=0
: >"$FILELIST"

add_file_if_included() {
  local f="$1"
  is_excluded "$f" && return 1
  printf '%s\0' "$f" >>"$FILELIST"
  ((DISCOVERED+=1))
  local now=$(date +%s)
  if (( now - DISC_LAST_PRINT >= PROGRESS_INTERVAL )); then
    log PROGRESS "Discovery: scanned=$DISCOVERED (last: $f)"
    DISC_LAST_PRINT=$now
  fi
}

for p in "${SEARCH_PATHS[@]}"; do
  if [[ -d "$p" || -f "$p" ]]; then
    while IFS= read -r -d '' f; do
      add_file_if_included "$f"
    done < <(find "$p" -type f -print0 2>/dev/null)
  else
    log WARN "Path does not exist or is not accessible: $p"
  fi
done

# Deduplicate by path while preserving NULs
TMP="$FILELIST.tmp"
awk -v RS='\0' '!seen[$0]++{printf "%s\0",$0}' "$FILELIST" >"$TMP" && mv -f "$TMP" "$FILELIST"

TOTAL=$(awk -v RS='\0' 'END{print NR}' "$FILELIST")
DISCOVERY_END=$(date +%s)
log INFO "Discovery complete: total_files=$TOTAL took=$(format_secs $((DISCOVERY_END-DISCOVERY_START)))"
log INFO "File list saved: $FILELIST"

# ───────────────────────── Hashing ─────────────────────────
START_TS=$(date +%s)
PROCESSED=0
FAILED=0
LAST_PRINT=$START_TS

log INFO "Starting hash: algo=$ALGO_NAME total_files=$TOTAL output=$OUTPUT"

trap 'log WARN "Interrupted. Processed ${PROCESSED}/${TOTAL}. Failed=${FAILED}. Partial CSV: ${OUTPUT}"' INT TERM

percent_of() {
  local p="$1" t="$2"
  if (( t<=0 )); then echo 0; return; fi
  local pct=$(( (p * 100) / t ))
  (( pct<0 )) && pct=0
  (( pct>100 )) && pct=100
  echo "$pct"
}

progress_tick() {
  local now elapsed eta rem pct
  now=$(date +%s)
  elapsed=$((now - START_TS))
  rem=$(( TOTAL - PROCESSED ))
  (( rem<0 )) && rem=0
  eta=$(( PROCESSED>0 ? (elapsed * rem / PROCESSED) : 0 ))
  pct=$(percent_of "$PROCESSED" "$TOTAL")
  log PROGRESS "Hashing: [${pct}%] ${PROCESSED}/${TOTAL} | elapsed=$(format_secs "$elapsed") eta=$(format_secs "$eta")"
}

hash_one() {
  local f="$1"
  if [[ ! -r "$f" ]]; then
    ((FAILED+=1))
    log WARN "Skipped (missing/unreadable): $f"
    return 1
  fi
  local sum
  if ! sum="$("$HASH_CMD" -- "$f" 2>/dev/null | awk 'NR==1{print $1}')"; then
    ((FAILED+=1))
    log WARN "Failed to hash: $f"
    return 1
  fi
  local bytes size_mb
  bytes="$(portable_stat_size "$f" 2>/dev/null || echo 0)"
  size_mb="$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1048576}')"
  local row
  row="$(csv_quote "$(ts)"),$(csv_quote "$f"),$(csv_quote "$ALGO_NAME"),$(csv_quote "$sum"),$(csv_quote "$size_mb")"
  printf '%s\n' "$row" >>"$OUTPUT"
  return 0
}

while IFS= read -r -d '' f; do
  if hash_one "$f"; then
    ((PROCESSED+=1))
  fi
  now=$(date +%s)
  if (( now - LAST_PRINT >= PROGRESS_INTERVAL )) || (( PROCESSED == TOTAL )); then
    progress_tick
    LAST_PRINT=$now
  fi
done <"$FILELIST"

# ───────────────────────── Summary ─────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
log INFO "Completed. Hashed ${PROCESSED}/${TOTAL} files (failures=${FAILED}) in $(format_secs "$ELAPSED"). CSV: $OUTPUT"
