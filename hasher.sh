#!/usr/bin/env bash
# hasher.sh — fast, robust file hasher with CSV output & background mode
# Works well on NAS (e.g., Synology). No pv/parallel required.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Config ─────────────────────────
HASHES_DIR="hashes"
LOGS_DIR="logs"

DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"

BACKGROUND_LOG="$LOGS_DIR/background.log"  # captures stdout/stderr of background child
LOG_FILE="$LOGS_DIR/hasher.log"            # canonical run log (always appended to)

ALGO="sha256"           # default algo (sha256|sha1|sha512|md5|blake2)
PATHFILE=""             # file containing newline-delimited paths (supports # comments)
RUN_IN_BACKGROUND=false
IS_CHILD=false          # internal flag set when re-exec'ed under nohup
EXCLUDE_FILE=""         # optional glob-per-line exclude file

# Built-in excludes (NAS clutter, temp files, this script's output, etc)
# These are globs matched against full file paths.
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

# ──────────────────────── Helpers ─────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

gen_run_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}

RUN_ID="$(gen_run_id)"

# log() prints to stdout (goes to console or background.log) AND appends to LOG_FILE
log() {
  local level="$1"; shift
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

Flags:
  --pathfile FILE      File with one path per line (blank lines and #comments allowed).
  --algo NAME          Hash algorithm (default: sha256).
  --nohup              Re-execute in background; logs go to: $BACKGROUND_LOG
  --exclude-file FILE  Optional file of globs to exclude (one per line). Evaluated in addition to built-ins.

Output:
  CSV at: $OUTPUT
  Columns: timestamp,path,algo,hash,size_mb
Examples:
  $(basename "$0") --pathfile paths.txt --algo sha256
  $(basename "$0") --pathfile paths.txt --algo sha256 --nohup && tail -f $BACKGROUND_LOG
EOF
}

csv_quote() {
  local s=${1//\"/\"\"}
  printf '"%s"' "$s"
}

portable_stat_size() {
  local f="$1"
  if stat -c%s "$f" >/dev/null 2>&1; then
    stat -c%s "$f"
  elif stat -f%z "$f" >/dev/null 2>&1; then
    stat -f%z "$f"
  else
    wc -c <"$f" | tr -d ' '
  fi
}

format_secs() {
  local s=$1
  printf '%02d:%02d:%02d' "$((s/3600))" "$(( (s%3600)/60 ))" "$((s%60))"
}

# Collect exclude globs into an array (built-ins + optional file)
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

  # Always exclude our output dir/files
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
    *) die "Unknown --algo '$ALGO'. Use sha256|sha1|sha512|md5|blake2." ;;
  esac

  if ! command -v "$HASH_CMD" >/dev/null 2>&1; then
    die "Required command '$HASH_CMD' not found on this system."
  fi
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

# Ensure directories exist before any logging and resolve algo
mkdir -p "$HASHES_DIR" "$LOGS_DIR"
resolve_algo_cmd
load_excludes

# ─────────────────────── Background mode ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  # Re-exec this script with --headless, redirecting all output to the background log
  ( nohup bash "$0" --pathfile "$PATHFILE" --algo "$ALGO" ${EXCLUDE_FILE:+--exclude-file "$EXCLUDE_FILE"} --headless >"$BACKGROUND_LOG" 2>&1 & echo $! > "$LOGS_DIR/.hasher.pid" ) >/dev/null 2>&1
  pid="$(cat "$LOGS_DIR/.hasher.pid" 2>/dev/null || true)"; rm -f "$LOGS_DIR/.hasher.pid"
  printf 'Hasher started with nohup (PID %s). Run-ID: %s. Output: %s\n' "${pid:-?}" "$RUN_ID" "$OUTPUT"
  # Note: no parent writes to $BACKGROUND_LOG — avoids interleaving.
  exit 0
fi

# ─────────────────────── Preparation ───────────────────────
# Immediate reassurance from the single writer (this process)
log INFO "Run-ID: $RUN_ID"
log INFO "Hasher initiated — please standby; initial file discovery may take some time."

# Ensure CSV header exists
if [[ ! -s "$OUTPUT" ]]; then
  printf '"timestamp","path","algo","hash","size_mb"\n' >"$OUTPUT"
fi

# Read search paths from the file
declare -a SEARCH_PATHS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo -n "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -z "$line" ]] && continue
  SEARCH_PATHS+=("$line")
done <"$PATHFILE"

((${#SEARCH_PATHS[@]})) || die "No valid paths in $PATHFILE."

log INFO "Preparing file list..."

# Count files (without hashing) for progress
count_files_in() {
  local path="$1"
  local cnt=0
  while IFS= read -r -d '' f; do
    if ! is_excluded "$f"; then
      ((cnt++))
    fi
  done < <(find "$path" -type f -print0 2>/dev/null)
  printf '%s' "$cnt"
}

TOTAL=0
for p in "${SEARCH_PATHS[@]}"; do
  if [[ -d "$p" || -f "$p" ]]; then
    c=$(count_files_in "$p" || true)
    TOTAL=$((TOTAL + c))
  else
    log WARN "Path does not exist or is not accessible: $p"
  fi
done

START_TS=$(date +%s)
PROCESSED=0

log INFO "Starting hash: algo=$ALGO_NAME total_files=$TOTAL output=$OUTPUT"

trap 'log WARN "Interrupted. Processed '"$PROCESSED"'/'"$TOTAL"'. Partial CSV: '"$OUTPUT"'' INT TERM

progress_tick() {
  local now elapsed pct eta rem
  now=$(date +%s)
  elapsed=$((now - START_TS))
  if (( PROCESSED > 0 )); then
    rem=$(( TOTAL - PROCESSED ))
    eta=$(( elapsed * (rem) / (PROCESSED) ))
  else
    eta=0
  fi
  if (( TOTAL > 0 )); then
    pct=$(( PROCESSED * 100 / TOTAL ))
  else
    pct=100
  fi
  log PROGRESS "[$pct%%] $PROCESSED/$TOTAL | elapsed=$(format_secs "$elapsed") eta=$(format_secs "$eta")"
}

# ───────────────────────── Hashing ─────────────────────────
hash_one() {
  local f="$1"
  if is_excluded "$f"; then
    return 0
  fi

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

LAST_PRINT=$(date +%s)

for p in "${SEARCH_PATHS[@]}"; do
  [[ -d "$p" || -f "$p" ]] || continue
  while IFS= read -r -d '' f; do
    hash_one "$f"
    ((PROCESSED++))

    now=$(date +%s)
    if (( now - LAST_PRINT >= 1 )) || (( PROCESSED == TOTAL )) || (( PROCESSED % 500 == 0 )); then
      progress_tick
      LAST_PRINT="$now"
    fi
  done < <(find "$p" -type f -print0 2>/dev/null)
done

# ───────────────────────── Summary ─────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
log INFO "Completed. Hashed $PROCESSED/$TOTAL files in $(format_secs "$ELAPSED"). CSV: $OUTPUT"
