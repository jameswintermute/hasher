#!/usr/bin/env bash
# delete-zero-length.sh — verify & (optionally) delete/move zero-length files from a list
# Dry-run by default. With no arguments, auto-selects the most recent report and asks for confirmation.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Constants ───────────────────────
LOGS_DIR="logs"
ZERO_DIR="zero-length"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="${RUN_ID:-$({ command -v uuidgen >/dev/null 2>&1 && uuidgen; } || \
                    { [ -r /proc/sys/kernel/random/uuid ] && cat /proc/sys/kernel/random/uuid; } || \
                    date +%s)}"
SUMMARY_LOG="$LOGS_DIR/delete-zero-length-$DATE_TAG.log"
MAX_MENU=10

mkdir -p "$LOGS_DIR" "$ZERO_DIR"

# Colors
RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'

# ───────────────────────── Flags ───────────────────────────
FORCE=false
QUARANTINE_DIR=""
YES=false
INPUT=""

usage() {
  cat <<EOF
Usage: $0 [<pathlist.txt>] [--force] [--quarantine DIR] [--yes]

If <pathlist.txt> is omitted, the script auto-selects the most recent report,
preferring $ZERO_DIR/verified-*.txt, then $ZERO_DIR/zero-length-*.txt, then same in $LOGS_DIR.

Options:
  --force              Actually delete/move verified files (otherwise dry-run)
  --quarantine DIR     Move verified files into DIR (preserve original path under DIR)
                       e.g. "$ZERO_DIR/quarantine-$DATE_TAG"
  -y, --yes            Assume "yes" to confirmations (useful for non-interactive)
  -h, --help           Show this help

Examples:
  $0
  $0 "$ZERO_DIR/zero-length-$DATE_TAG.txt"
  $0 -y --force --quarantine "$ZERO_DIR/quarantine-$DATE_TAG"
EOF
}

# ───────────────────────── Logging ─────────────────────────
_log_core() {
  local lvl="$1"; shift
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [RUN $RUN_ID] [$lvl] $*"
  case "$lvl" in
    INFO)  echo -e "${GREEN}$line${NC}" ;;
    WARN)  echo -e "${YELLOW}$line${NC}" ;;
    ERROR) echo -e "${RED}$line${NC}" ;;
    *)     echo "$line" ;;
  esac
  printf '%s\n' "$line" >> "$SUMMARY_LOG"
}
info()  { _log_core INFO  "$*"; }
warn()  { _log_core WARN  "$*"; }
error() { _log_core ERROR "$*"; }

confirm() {
  $YES && return 0
  if [ -t 0 ]; then
    read -r -p "$1 [Y/n] " ans || true
    case "${ans:-Y}" in Y|y|yes|YES) return 0 ;; *) return 1 ;; esac
  else
    warn "Non-interactive and no --yes supplied; refusing."
    return 1
  fi
}

# ───────────────────────── Parse args ──────────────────────
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=true ;;
    --quarantine) shift; QUARANTINE_DIR="${1:-}"; [[ -n "$QUARANTINE_DIR" ]] || { error "Missing DIR for --quarantine"; exit 2; } ;;
    -y|--yes) YES=true ;;
    *) [[ -z "$INPUT" ]] && INPUT="$1" || { error "Unexpected argument: $1"; usage; exit 2; } ;;
  esac
  shift || true
done

# ───────────────────────── Auto-select input ───────────────
pick_latest_report() {
  local raw=()
  # Prefer ZERO_DIR, then LOGS_DIR; prefer verified-* then zero-length-* (newest first)
  for d in "$ZERO_DIR" "$LOGS_DIR"; do
    while IFS= read -r f; do raw+=("$f"); done < <(ls -1t "$d"/verified-zero-length-*.txt 2>/dev/null || true)
    while IFS= read -r f; do raw+=("$f"); done < <(ls -1t "$d"/zero-length-*.txt        2>/dev/null || true)
  done
  # De-duplicate while preserving order
  local cands=() seen=""
  for f in "${raw[@]}"; do
    [[ -e "$f" ]] || continue
    if [[ ":$seen:" != *":$f:"* ]]; then cands+=("$f"); seen="$seen:$f"; fi
  done

  local total=${#cands[@]}
  if (( total == 0 )); then
    echo ""
    return 0
  fi

  # If only one candidate, just return it
  if (( total == 1 )); then
    echo "${cands[0]}"
    return 0
  fi

  # If stdin is non-interactive, pick first (log to stderr so it shows)
  if [ ! -t 0 ]; then
    >&2 echo "Auto-selecting latest (non-interactive): ${cands[0]}"
    echo "${cands[0]}"
    return 0
  fi

  # Interactive: ALWAYS print the menu to stderr so it isn't swallowed by command substitution
  local limit=$MAX_MENU
  (( total < limit )) && limit=$total

  >&2 echo "Select input report (showing $limit of $total most recent):"
  local i f cnt
  for (( i=0; i<limit; i++ )); do
    f="${cands[$i]}"
    cnt="$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || echo 0)"
    >&2 printf "  %2d) %s  (%s entries)\n" "$((i+1))" "$f" "$cnt"
  done
  if (( total > limit )); then
    >&2 echo "  … (older reports not shown; pass a path explicitly if needed)"
  fi

  local pick
  while true; do
    # read -p writes prompt to stderr by design — perfect for interactive menus
    read -r -p "Enter number [1-$limit] (default 1): " pick || true
    pick="${pick:-1}"
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=limit )); then
      echo "${cands[$((pick-1))]}"
      return 0
    fi
    >&2 echo "Invalid selection."
  done
}

if [[ -z "$INPUT" ]]; then
  INPUT="$(pick_latest_report)"
  [[ -n "$INPUT" ]] || { error "No report files found (looked in $ZERO_DIR and $LOGS_DIR for zero-length-*.txt or verified-zero-length-*.txt)."; usage; exit 1; }
  info "Auto-selected input: $INPUT"
  confirm "Use \"$INPUT\"?" || { info "Aborted by user."; exit 0; }
fi

[[ -r "$INPUT" ]] || { error "Input list not readable: $INPUT"; exit 3; }

# ───────────────────────── Verified plan path ──────────────
base="$(basename -- "$INPUT")"
date_hint="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<<"$base" || true)"
plan_date="${date_hint:-$DATE_TAG}"
VERIFIED_LIST="$ZERO_DIR/verified-zero-length-$plan_date-$RUN_ID.txt"
: > "$VERIFIED_LIST"

# ───────────────────────── Mode banner ─────────────────────
if $FORCE; then
  if [[ -n "$QUARANTINE_DIR" ]]; then info "Mode: FORCE (quarantine to \"$QUARANTINE_DIR\")"
  else info "Mode: FORCE (delete)"; fi
  confirm "Proceed with FORCE action?" || { info "Aborted by user."; exit 0; }
else
  info "Mode: DRY-RUN (no changes will be made)"
fi

info "Verifying zero-length files…"
info "Input list: $INPUT"
info "Summary log: $SUMMARY_LOG"
info "Run-ID: $RUN_ID"

# ───────────────────────── Pre-count for progress ─────────
TOTAL_LINES="$(grep -v '^[[:space:]]*#' "$INPUT" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || echo 0)"
(( TOTAL_LINES < 0 )) && TOTAL_LINES=0
STEP=$(( TOTAL_LINES / 100 )); (( STEP < 1 )) && STEP=1

# ───────────────────────── Counters ────────────────────────
seen=0; processed=0; still_zero=0; missing=0; nonzero=0; not_regular=0
deleted=0; moved=0; delete_failed=0; move_failed=0

# ───────────────────────── Progress UI ─────────────────────
draw_progress() {
  local p="$1" t="$2"; (( t == 0 )) && t=1
  local pc=$(( p * 100 / t )); (( pc > 100 )) && pc=100
  local width=30; local fill=$(( pc * width / 100 ))
  local bar; bar="$(printf '%*s' "$fill" '' | tr ' ' '#')"; bar="$bar$(printf '%*s' "$((width-fill))" '' | tr ' ' '.')"
  if [ -t 1 ]; then printf "\r[%-30s] %3d%% (%d/%d)" "$bar" "$pc" "$p" "$t"
  else (( p % STEP == 0 )) && echo "Progress: $pc%% ($p/$t)"; fi
}
finish_progress() { [ -t 1 ] && printf "\n"; }
trap 'finish_progress' EXIT

# ───────────────────────── Actions ─────────────────────────
do_delete() { rm -f -- "$1" && ((deleted++)) || { ((delete_failed++)); warn "Failed to delete: $1"; }; }
do_move() {
  local f="$1" dest="$QUARANTINE_DIR/$f" dest_dir
  dest_dir="$(dirname -- "$dest")"
  if mkdir -p -- "$dest_dir"; then
    mv -n -- "$f" "$dest" 2>/dev/null && ((moved++)) || {
      local alt="${dest}.${RUN_ID}"
      mv -- "$f" "$alt" && ((moved++)) || { ((move_failed++)); warn "Failed to move: $f -> $dest"; }
    }
  else
    ((move_failed++)); warn "Failed to create quarantine dir: $dest_dir"
  fi
}

# ───────────────────────── Verify pass (+optional act) ─────
start_ts=$(date +%s)
while IFS= read -r line || [[ -n "$line" ]]; do
  file="${line%$'\r'}"
  [[ -z "${file//[[:space:]]/}" ]] && continue
  [[ "$file" =~ ^[[:space:]]*# ]] && continue

  (( seen++ ))
  if [[ ! -e "$file" ]]; then (( missing++ ))
  elif [[ ! -f "$file" ]]; then (( not_regular++ ))
  elif [[ ! -s "$file" ]]; then
    echo "$file" >> "$VERIFIED_LIST"; (( still_zero++ ))
    if $FORCE; then
      if [[ -n "$QUARANTINE_DIR" ]]; then do_move "$file"; else do_delete "$file"; fi
    fi
  else
    (( nonzero++ ))
  fi

  (( processed++ )); draw_progress "$processed" "$TOTAL_LINES"
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
    echo "To execute deletion safely, run:"
    echo "  ./delete-zero-length.sh \"$VERIFIED_LIST\" --force"
    echo
    echo "To quarantine instead of delete, run:"
    echo "  ./delete-zero-length.sh \"$VERIFIED_LIST\" --force --quarantine \"$ZERO_DIR/quarantine-$plan_date\""
    echo
  else
    info "No zero-length files remain to delete."
  fi
fi
