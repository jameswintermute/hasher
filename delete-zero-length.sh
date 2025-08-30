#!/usr/bin/env bash
# delete-zero-length.sh — verify & (optionally) delete/move zero-length files from a list
# Dry-run by default. Use --force to take action.
# The input list is expected to be one path per line (absolute or relative).
# Lines starting with '#' or blank lines are ignored.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Constants ───────────────────────
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="${RUN_ID:-$({ command -v uuidgen >/dev/null 2>&1 && uuidgen; } || \
                    { [ -r /proc/sys/kernel/random/uuid ] && cat /proc/sys/kernel/random/uuid; } || \
                    date +%s)}"
SUMMARY_LOG="$LOGS_DIR/delete-zero-length-$DATE_TAG.log"

# Will be set after we know the input name
VERIFIED_LIST=""

# ───────────────────────── Flags ───────────────────────────
FORCE=false
QUARANTINE_DIR=""

usage() {
  cat <<EOF
Usage: $0 <pathlist.txt> [--force] [--quarantine DIR]

Dry-run by default. Verifies paths still exist and are zero-length, writes a
verified list, shows progress, and prints a summary with a ready-to-run command.

Options:
  --force              Actually delete/move verified files (otherwise dry-run)
  --quarantine DIR     Move verified files into DIR (preserves absolute path
                       under DIR) instead of deleting (requires --force)

Examples:
  # Review only (dry-run), produce verified plan:
  $0 "logs/zero-length-2025-08-29.txt"

  # Execute deletion using the verified plan:
  $0 "logs/verified-zero-length-2025-08-29-<RUN>.txt" --force

  # Execute safer move to quarantine:
  $0 "logs/verified-zero-length-2025-08-29-<RUN>.txt" --force --quarantine "quarantine-2025-08-29"
EOF
}

# ───────────────────────── Logging ─────────────────────────
mkdir -p "$LOGS_DIR"

log_line() {
  local level="$1"; shift
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [RUN $RUN_ID] [$level] $*"
  echo "$line" | tee -a "$SUMMARY_LOG" >/dev/null
}

info()  { log_line "INFO"  "$*"; }
warn()  { log_line "WARN"  "$*"; }
error() { log_line "ERROR" "$*"; }

# ───────────────────────── Parse args ──────────────────────
if (( $# < 1 )); then usage; exit 1; fi

INPUT="$1"; shift || true
while (( $# )); do
  case "$1" in
    --force) FORCE=true ;;
    --quarantine) shift; QUARANTINE_DIR="${1:-}"; if [[ -z "$QUARANTINE_DIR" ]]; then error "Missing DIR for --quarantine"; exit 2; fi ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift || true
done

if [[ ! -r "$INPUT" ]]; then
  error "Input list not readable: $INPUT"
  exit 3
fi

# Derive verified plan path from input name
base="$(basename -- "$INPUT")"
VERIFIED_LIST="$LOGS_DIR/verified-${base%.*}-$DATE_TAG-$RUN_ID.txt"
# Avoid colliding with existing files
: > "$VERIFIED_LIST"

info "Delete Zero-Length (dry-run=${FORCE=false})"
info "Input list: $INPUT"
info "Summary log: $SUMMARY_LOG"
info "Run-ID: $RUN_ID"

# ───────────────────────── Pre-count for progress ─────────
# Count non-empty, non-comment lines for approximate progress
TOTAL_LINES="$(grep -v '^[[:space:]]*#' "$INPUT" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
(( TOTAL_LINES < 0 )) && TOTAL_LINES=0
STEP=$(( TOTAL_LINES / 100 ))
(( STEP < 1 )) && STEP=1

# ───────────────────────── Counters ────────────────────────
seen=0
processed=0
still_zero=0
missing=0
nonzero=0
not_regular=0
deleted=0
moved=0
delete_failed=0
move_failed=0

# ───────────────────────── Progress UI ─────────────────────
draw_progress() {
  local p="$1" t="$2"
  (( t == 0 )) && t=1
  local pc=$(( p * 100 / t ))
  (( pc > 100 )) && pc=100
  local width=30
  local fill=$(( pc * width / 100 ))
  local bar
  bar="$(printf '%*s' "$fill" '' | tr ' ' '#')"
  bar="$bar$(printf '%*s' "$((width-fill))" '' | tr ' ' '.')"
  if [ -t 1 ]; then
    printf "\r[%-30s] %3d%% (%d/%d)" "$bar" "$pc" "$p" "$t"
  else
    # non-TTY (e.g., nohup): print occasionally
    if (( p % STEP == 0 )); then
      echo "Progress: $pc%% ($p/$t)"
    fi
  fi
}

finish_progress() {
  if [ -t 1 ]; then
    printf "\n"
  fi
}

trap 'finish_progress' EXIT

# ───────────────────────── Action helpers ──────────────────
do_delete() {
  local f="$1"
  if rm -f -- "$f"; then
    (( deleted++ ))
  else
    (( delete_failed++ ))
    warn "Failed to delete: $f"
  fi
}

do_move() {
  local f="$1"
  local dest="$QUARANTINE_DIR/$f"  # preserve absolute path under quarantine root
  local dest_dir; dest_dir="$(dirname -- "$dest")"
  if mkdir -p -- "$dest_dir"; then
    # Try no-overwrite first; if exists, append run id
    if mv -n -- "$f" "$dest" 2>/dev/null; then
      (( moved++ ))
    else
      local alt="${dest}.${RUN_ID}"
      if mv -- "$f" "$alt"; then
        (( moved++ ))
      else
        (( move_failed++ ))
        warn "Failed to move: $f -> $dest"
      fi
    fi
  else
    (( move_failed++ ))
    warn "Failed to create quarantine dir: $dest_dir"
  fi
}

# ───────────────────────── Verify pass (+optional act) ─────
start_ts=$(date +%s)

while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip any trailing CR for Windowsy files
  file="${line%$'\r'}"

  # Skip comments/blank
  [[ -z "${file//[[:space:]]/}" ]] && continue
  [[ "$file" =~ ^[[:space:]]*# ]] && continue

  (( seen++ ))

  if [[ ! -e "$file" ]]; then
    (( missing++ ))
  elif [[ ! -f "$file" ]]; then
    (( not_regular++ ))
  elif [[ ! -s "$file" ]]; then
    # Verified zero-length now
    echo "$file" >> "$VERIFIED_LIST"
    (( still_zero++ ))

    if $FORCE; then
      if [[ -n "$QUARANTINE_DIR" ]]; then
        do_move "$file"
      else
        do_delete "$file"
      fi
    fi
  else
    (( nonzero++ ))
  fi

  (( processed++ ))
  draw_progress "$processed" "$TOTAL_LINES"
done < "$INPUT"

finish_progress

end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))

# ───────────────────────── Summary ─────────────────────────
info "Verification complete in ${elapsed}s"
info "Input lines considered: $TOTAL_LINES"
info "Seen entries: $seen"
info " • Missing paths: $missing"
info " • Not regular files: $not_regular"
info " • No longer zero-length: $nonzero"
info " • Verified zero-length now: $still_zero"
info "Verified plan file: $VERIFIED_LIST"

if $FORCE; then
  if [[ -n "$QUARANTINE_DIR" ]]; then
    info "ACTION: Moved (quarantined): $moved  | Move failures: $move_failed | Quarantine: $QUARANTINE_DIR"
  else
    info "ACTION: Deleted: $deleted | Delete failures: $delete_failed"
  fi
else
  if (( still_zero > 0 )); then
    echo
    info "SAFE TO DELETE: $still_zero files (verified zero-length)."
    echo
    echo "To execute deletion safely, run:"
    echo "  ./delete-zero-length.sh \"$VERIFIED_LIST\" --force"
    echo
    echo "To quarantine instead of delete, run:"
    echo "  ./delete-zero-length.sh \"$VERIFIED_LIST\" --force --quarantine \"quarantine-$DATE_TAG\""
    echo
  else
    info "No zero-length files remain to delete."
  fi
fi
