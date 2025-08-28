#!/usr/bin/env bash
# hasher.sh — fast, robust file hasher with CSV output & background mode
# Works well on NAS (e.g., Synology). No pv/parallel required.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Config ─────────────────────────
HASHES_DIR="hashes"
BACKGROUND_LOG="background.log"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"

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

log() {
  local level="$1"; shift
  # Foreground prints to console; background child’s stdout is already redirected to background.log
  printf '[%s] [%s] %s\n' "$(ts)" "$level" "$*" >&1
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
  # Always quote; double-up internal quotes
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
  # int seconds -> HH:MM:SS
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
resolve_algo_cmd
load_excludes

# ─────────────────────── Background mode ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  mkdir -p "$(dirname "$BACKGROUND_LOG")"
  # Re-exec this script with --headless, redirecting all output to the background log
  ( nohup bash "$0" --pathfile "$PATHFILE" --algo "$ALGO" ${EXCLUDE_FILE:+--exclude-file "$EXCLUDE_FILE"} --headless >"$BACKGROUND_LOG" 2>&1 & echo $! > .hasher.pid ) >/dev/null 2>&1
  pid="$(cat .hasher.pid 2>/dev/null || true)"; rm -f .hasher.pid
  printf 'Hasher started with nohup (PID %s). Output: %s\n' "${pid:-?}" "$OUTPUT"
  exit 0
fi

# ─────────────────────── Preparation ───────────────────────
mkdir -p "$HASHES_DIR"

# Ensure CSV header exists
if [[ ! -s "$OUTPUT" ]]; then
  printf '"timestamp","path","algo","hash","size_mb"\n' >"$OUTPUT"
fi

# Read search paths from the file
declare -a SEARCH_PATHS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # strip comments and trim
  line="${line%%#*}"
  line="$(echo -n "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -z "$line" ]] && continue
  SEARCH
