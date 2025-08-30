#!/usr/bin/env bash
# delete-zero-length.sh — verify & (optionally) delete/move zero-length files from a list
# Dry-run by default. With no arguments, auto-selects the most recent report and asks for confirmation.

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
mkdir -p "$LOGS_DIR"

# ───────────────────────── Flags ───────────────────────────
FORCE=false
QUARANTINE_DIR=""
YES=false
INPUT=""

usage() {
  cat <<EOF
Usage: $0 [<pathlist.txt>] [--force] [--quarantine DIR] [--yes]

If <pathlist.txt> is omitted, the script will try to auto-select the most recent
report in $LOGS_DIR (prefers verified-*.txt, else zero-length-*.txt) and ask you
to confirm. Dry-run by default.

Options:
  --force              Actually delete/move verified files (otherwise dry-run)
  --quarantine DIR     Move verified files into DIR (preserves path under DIR)
  -y, --yes            Assume "yes" to confirmations (useful for non-interactive)
  -h, --help           Show this help

Examples:
  $0                                  # auto-pick latest report, dry-run
  $0 logs/zero-length-2025-08-29.txt  # use explicit input, dry-run
  $0 logs/verified-zero-length-*.txt --force
  $0 --force --quarantine quarantine-2025-08-30  # auto-pick + quarantine
EOF
}

log_line() {
  local level="$1"; shift
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [RUN $RUN_ID] [$level] $*"
  echo "$line" | tee -a "$SUMMARY_LOG" >/dev/null
}
info()  { log_line "INFO"  "$*"; }
warn()  { log_line "WARN"  "$*"; }
error() { log_line "ERROR" "$*"; }

confirm() {
  local prompt="$1"
  if $YES; then return 0; fi
  if [ -t 0 ]; then
    read -r -p "$prompt [Y/n] " ans || true
    case "${ans:-Y}" in
      Y|y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  else
    # non-interactive: require --yes
    warn "Non-interactive mode and no --yes supplied; refusing."
    return 1
  fi
}

# ───────────────────────── Parse args ──────────────────────
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=true ;;
    --quarantine) shift; QUARANTINE_DIR="${1:-}"; if [[ -z "$QUARANTINE_DIR" ]]; then error "Missing DIR for --quarantine"; exit 2; fi ;;
    -y|--yes) YES=true ;;
    *) if [[ -z "$INPUT" ]]; then INPUT="$1"; else error "Unexpected argument: $1"; usage; exit 2; fi ;;
  esac
  shift || true
done

# ───────────────────────── Auto-select input ───────────────
pick_latest_report() {
  # Prefer verified plans, then raw zero-length reports
  local list=()
  while IFS= read -r f; do list+=("$f"); done < <(ls -1t "$LOGS_DIR"/verified-zero-length-*.txt 2>/dev/null || true)
  while IFS= read -r f; do list+=("$f"); done < <(ls -1t "$LOGS_DIR"/zero-length-*.txt 2>/dev/null || true)

  # De-duplicate while preserving order
  local out=()
  local seen=""
  for f in "${list[@]}"; do
    [[ -e "$f" ]] || continue
    if [[ ":$seen:" != *":$f:"* ]]; then
      out+=("$f"); seen="$seen:$f"
    fi
  done

  if (( ${#out[@]} == 0 )); then
    echo ""
    return 0
  fi

  if (( ${#out[@]} == 1 )) || [ ! -t 0 ]; then
    echo "${out[0]}"
    return 0
  fi

  # Interactive menu
  echo "Select input report:"
  local i=1
  for f in "${out[@]}"; do
    local cnt; cnt="$(grep -v '^[[:space:]]*#' "$f" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    printf "  %2d) %s  (%s lines)\n" "$i" "$f" "$cnt"
    ((i++))
  done
  while true; do
    read -r -p "Enter number [1-${#out[@]}] (default 1): " pick || true
    pick="${pick:-1}"
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=${#out[@]} )); then
      echo "${out[$((pick-1))]}"
      return 0
    fi
    echo "Invalid selection."
  done
}

if [[ -z "$INPUT" ]]; then
  INPUT="$(pick_latest_report)"
  if [[ -z "$INPUT" ]]; then
    error "No report files found in $LOGS_DIR (expected zero-length-*.txt or verified-zero-length-*.txt)."
    usage
    exit 1
  fi
  info "Auto-selected input: $INPUT"
  confirm "Use \"$INPUT\"?" || { info "Aborted by user."; exit 0; }
fi

if [[ ! -r "$INPUT" ]]; then
  error "Input list not readable: $INPUT"
  exit 3
fi

# ───────────────────────── Derive verified plan path ───────
base="$(basename -- "$INPUT")"
VERIFIED_LIST="$LOGS_DIR/verified-${base%.*}-$DATE_TAG-$RUN_ID.txt"
: > "$VERIFIED_LIST"

# ───────────────────────── Mode banner ─────────────────────
if $FORCE; then
  if [[ -n "$QUARANTINE_DIR" ]]; then
    info "Mode: FORCE (quarantine to \"$QUARANTINE_DIR\")"
  else
    info "Mode: FORCE (delete)"
  fi
  confirm "Proceed with FORCE action?" || { info "Aborted by user."; exit 0; }
else
  info "Mode: DRY-RUN (no changes will be made)"
fi

info "Verifying zero-length files…"
info "Input list: $INPUT"
info "Summary log: $SUMMARY_LOG"
info "Run-ID: $RUN_ID"

# ───────────────────────── Pre-count for progress ─────────
TOTAL_LINES="$(grep -v '^[[:space:]]*#' "$INPUT" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
(( TOTAL_LINES < 0 )) && TOTAL_LINES=0
STEP=$(( TOTAL_LINES / 100 ))
(( STEP < 1 )) && STEP=1

# ───────────────────────── Counters ────────────────────────
seen=0; processed=0; still_zero=0; missing=0; nonzero=0; not_regular=0
deleted=0; moved=0; delete_failed=0; move_failed=0

# ───────────────────────── Progress UI ─────────────────────
draw_progress() {
  local p="$1" t="$2"
  (( t == 0 )) && t=1
  local pc=$(( p * 100 / t )); (( pc > 100 )) && pc=100
  local width=30; local fill=$(( pc * width / 100 ))
  local bar; bar="$(printf '%*s' "$fill" '' | tr ' ' '#')"
  bar="$bar$(printf '%*s' "$((width-fill))" '' | tr ' ' '.')"
  if [ -t 1 ]; then
    printf "\r[%-30s] %3d%% (%d/%d)" "$bar" "$pc" "$p" "$t"
  else
    if (( p % STEP == 0 )); then echo "Progress: $pc%% ($p/$t)"; fi
  fi
}
finish_progress() { if [ -t 1 ]; then printf "\n"; fi; }
trap 'finish_progress' EXIT

# ───────────────────────── Action helpers ──────────────────
do_delete() {
  local f="$1"
  if rm -f -- "$f"; then (( deleted++ )); else (( delete_failed++ )); warn "Failed to delete: $f"; fi
}
do_move() {
  local f="$1"
  local dest="$QUARANTINE_DIR/$f"              # preserve original path under quarantine root
  local dest_dir; dest_dir="$(dirname -- "$dest")"
  if mkdir -p -- "$dest_dir"; then
    if mv -n -- "$f" "$dest" 2>/dev/null; then
      (( moved++ ))
    else
      local alt="${dest}.${RUN_ID}"
      if mv -- "$f" "$alt"; then (( moved++ )); else (( move_failed++ )); warn "Failed to move: $f -> $dest"; fi
    fi
  else
    (( move_failed++ )); warn "Failed to create quarantine dir: $dest_dir"
  fi
}

# ───────────────────────── Verify pass (+optional act) ─────
start_ts=$(date +%s)
while IFS= read -r line || [[ -n "$line" ]]; do
  file="${line%$'\r'}"
  [[ -z "${file//[[:space:]]/}" ]] && continue
  [[ "$file" =~ ^[[:space:]]*# ]] && continue

  (( seen++ ))

  if [[ ! -e "$file" ]]; then
    (( missing++ ))
  elif [[ ! -f "$file" ]]; then
    (( not_regular++ ))
  elif [[ ! -s "$file" ]]; then
    echo "$file" >> "$VERIFIED_LIST"
    (( still_zero++ ))
    if $FORCE; then
      if [[ -n "$QUARANTINE_DIR" ]]; then do_move "$file"; else do_delete "$file"; fi
    fi
  else
    (( nonzero++ ))
  fi

  (( processed++ ))
  draw_progress "$processed" "$TOTAL_LINES"
done < "$INPUT"
finish_progress
elapsed=$(( $(date +%s) - start_ts ))

# ───────────────────────── Summary ─────────────────────────
info "Verification complete in ${elapsed}s"
info "Input entries considered: $TOTAL_LINES"
info " • Missing paths: $missing"
info " • Not regular files: $not_regular"
info " • No longer zero-length: $nonzero"
info " • Verified zero-length now: $still_zero"
info "Verified plan file: $VERIFIED_LIST"

if $FORCE; then
  if [[ -n "$QUARANTINE_DIR" ]]; then
    info "ACTION: Moved (quarantined): $moved  | Move failures: $move_failed | Quarantine root: $QUARANTINE_DIR"
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
