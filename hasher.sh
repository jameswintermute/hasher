#!/usr/bin/env bash
# hasher.sh — robust file hasher with CSV output, background mode, Run-ID, and 15s heartbeats
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Config ─────────────────────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"

BACKGROUND_LOG="$LOGS_DIR/background.log"   # child stdout/stderr
LOG_FILE="$LOGS_DIR/hasher.log"             # canonical run log

ALGO="sha256"        # sha256|sha1|sha512|md5|blake2
PATHFILE=""
RUN_IN_BACKGROUND=false
IS_CHILD=false
EXCLUDE_FILE=""
PROGRESS_INTERVAL=15  # seconds

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

# ───────────────────────── Helpers ─────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

gen_run_id() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}
RUN_ID="$(gen_run_id)"

log() {
  # $1=LEVEL, rest=message
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
  $(basename "$0") --pathfile paths.txt [--algo sha256|sha1|sha512|md5|blake2] [--nohup] [--exclude-file excludes.txt]

Output CSV: $OUTPUT
Columns: timestamp,path,algo,hash,size_mb
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

format_secs() { local s=$1; printf '%02d:%02d:%02d' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"; }

# ───────────────────────── Excludes ────────────────────────
declare -a EXCLUDE_GLOBS=()
load_excludes() {
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    EXCLUDE_GLOBS+=("$line")
  done <<<"$EXCLUDE_DEFAULTS"

  if [[ -n "$EXCLUDE_FILE" && -f "$EXCLUDE_FILE" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      EXCLUDE_GLOBS+=("$line")
    done <"$EXCLUDE_FILE"
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

# ───────────────────── Argument parsing ────────────────────
while (($#)); do
  case "${1:-}" in
    --pathfile)      PATHFILE="${2:-}"; shift 2 ;;
    --algo)          ALGO="${2:-}"; shift 2 ;;
    --nohup)         RUN_IN_BACKGROUND=true; shift ;;
    --headless)      IS_CHILD=true; shift ;;   # internal
    --exclude-file)  EXCLUDE_FILE="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown arg: $1 (use -h for help)";;
  esac
done
[[ -n "$PATHFILE" && -f "$PATHFILE" ]] || die "Please provide --pathfile FILE (found: '$PATHFILE')."

mkdir -p "$HASHES_DIR" "$LOGS_DIR"
resolve_algo_cmd
load_excludes

# ─────────────────────── Background mode ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  ( nohup bash "$0" --pathfile "$PATHFILE" --algo "$ALGO" ${EXCLUDE_FILE:+--exclude-file "$EXCLUDE_FILE"} --headless >"$BACKGROUND_LOG" 2>&1 & echo $! > "$LOGS_DIR/.hasher.pid" ) >/dev/null 2>&1
  pid="$(cat "$LOGS_DIR/.hasher.pid" 2>/dev/null || true)"; rm -f "$LOGS_DIR/.hasher.pid"
  printf 'Hasher started with nohup (PID %s). Run-ID: %s. Output: %s\n' "${pid:-?}" "$RUN_ID" "$OUTPUT"
  exit 0
fi

# ─────────────────────── Preparation ───────────────────────
log INFO "Run-ID: $RUN_ID"
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

# ─────────────────── Discovery with heartbeat ──────────────
log INFO "Preparing file list..."
DISCOVERED=0
DISCOVERY_START=$(date +%s)
DISC_LAST_PRINT=$DISCOVERY_START

count_files_in() {
  local path="$1"
  local cnt=0
  local now
  while IFS= read -r -d '' f; do
    if ! is_excluded "$f"; then
      ((cnt+=1))
      ((DISCOVERED+=1))
      now=$(date +%s)
      if (( now - DISC_LAST_PRINT >= PROGRESS_INTERVAL )); then
        log PROGRESS "Discovery: scanned=$DISCOVERED (current path: $path)"
        DISC_LAST_PRINT=$now
      fi
    fi
  done < <(find "$path" -type f -print0 2>/dev/null)
  printf '%s' "$cnt"
}

TOTAL=0
for p in "${SEARCH_PATHS[@]}"; do
  if [[ -d "$p" || -f "$p" ]]; then
    c=$(count_files_in "$p" || printf '0')
    TOTAL=$((TOTAL + c))
  else
    log WARN "Path does not exist or is not accessible: $p"
  fi
done

DISCOVERY_END=$(date +%s)
log INFO "Discovery complete: total_files=$TOTAL took=$(format_secs $((DISCOVERY_END-DISCOVERY_START)))"

# ───────────────────────── Hashing ─────────────────────────
START_TS=$(date +%s)
PROCESSED=0
LAST_PRINT=$START_TS

log INFO "Starting hash: algo=$ALGO_NAME total_files=$TOTAL output=$OUTPUT"

# ✅ FIXED: safe quoting — variables expand at trap time, not here
trap 'log WARN "Interrupted. Processed ${PROCESSED}/${TOTAL}. Partial CSV: ${OUTPUT}"' INT TERM

progress_tick() {
  local now elapsed pct eta rem
  now=$(date +%s)
  elapsed=$((now - START_TS))
  if (( PROCESSED > 0 )); then
    rem=$(( TOTAL - PROCESSED ))
    eta=$(( elapsed * rem / PROCESSED ))
  else
    eta=0
  fi
  if (( TOTAL > 0 )); then
    pct=$(( PROCESSED * 100 / TOTAL ))
  else
    pct=100
  fi
  log PROGRESS "Hashing: [$pct%%] $PROCESSED/$TOTAL | elapsed=$(format_secs "$elapsed") eta=$(format_secs "$eta")"
}

hash_one() {
  local f="$1"
  is_excluded "$f" && return 0

  local sum
  if ! sum="$("$HASH_CMD" -- "$f" 2>/dev/null | awk 'NR==1{print $1}')"; then
    log WARN "Failed to hash: $f"
    return 0
  fi

  local bytes size_mb
  bytes="$(portable_stat_size "$f" 2>/dev/null || echo 0)"
  size_mb="$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1048576}')"

  local row
  row="$(csv_quote "$(ts)"),$(csv_quote "$f"),$(csv_quote "$ALGO_NAME"),$(csv_quote "$sum"),$(csv_quote "$size_mb")"
  printf '%s\n' "$row" >>"$OUTPUT"
}

for p in "${SEARCH_PATHS[@]}"; do
  [[ -d "$p" || -f "$p" ]] || continue
  while IFS= read -r -d '' f; do
    hash_one "$f"
    ((PROCESSED+=1))
    now=$(date +%s)
    if (( now - LAST_PRINT >= PROGRESS_INTERVAL )) || (( PROCESSED == TOTAL )); then
      progress_tick
      LAST_PRINT=$now
    fi
  done < <(find "$p" -type f -print0 2>/dev/null)
done

# ───────────────────────── Summary ─────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
log INFO "Completed. Hashed $PROCESSED/$TOTAL files in $(format_secs "$ELAPSED"). CSV: $OUTPUT"
