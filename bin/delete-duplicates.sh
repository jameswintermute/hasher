#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# delete-duplicates.sh — act on a review PLAN (delete or quarantine duplicate files)
# - Reads a plan file (one absolute path per line) created by review-duplicates.sh
# - Defaults to DRY-RUN; use --force to actually delete or move
# - CRLF-safe, skips blanks and comments
# - Layout-aware via bin/lib_paths.sh
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# Path/layout discovery
. "$(dirname "$0")/lib_paths.sh" 2>/dev/null || true

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
if [ -r /proc/sys/kernel/random/uuid ]; then RUN_ID="$(cat /proc/sys/kernel/random/uuid)"; else RUN_ID="$(date +%s)-$$-$RANDOM"; fi
log(){ printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO" "$*"; }; log_warn(){ log "WARN" "$*"; }; log_error(){ log "ERROR" "$*"; }

PLAN_FILE=""; FORCE=false; QUARANTINE_DIR=""

usage(){
  cat <<'EOF'
Usage: delete-duplicates.sh --from-plan <file> [--force] [--quarantine DIR]

Options:
  --from-plan FILE     Path to plan file with one filesystem path per line
  --force              Execute actions (delete/quarantine). Default is dry-run
  --quarantine DIR     Move files to DIR instead of deleting (tree is preserved below DIR)

Notes:
  - Plan lines that are blank or start with # are ignored.
  - On quarantine, the original directory structure is preserved under DIR.
  - All actions/errors are logged to logs/delete-duplicates-YYYY-MM-DD.log
EOF
}

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --from-plan) PLAN_FILE="${2:-}"; shift ;;
    --force) FORCE=true ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
  shift || true
done

[ -n "$PLAN_FILE" ] || { log_error "Missing --from-plan"; exit 2; }
[ -r "$PLAN_FILE" ] || { log_error "Plan file not readable: $PLAN_FILE"; exit 2; }

mkdir -p "$LOG_DIR"
SUMMARY_LOG="$LOG_DIR/delete-duplicates-$(date +'%Y-%m-%d').log"
VERIFIED_PLAN="$LOG_DIR/verified-duplicates-$(date +'%Y-%m-%d')-${RUN_ID}.txt"
: > "$VERIFIED_PLAN"

log_info "Plan: $PLAN_FILE"
log_info "Summary log: $SUMMARY_LOG"
[ -n "$QUARANTINE_DIR" ] && log_info "Quarantine dir: $QUARANTINE_DIR"

# Verification pass
has_crlf=false; grep -q $'\r' "$PLAN_FILE" && has_crlf=true
considered=0; missing=0; not_regular=0; verified=0

while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%$'\r'}"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  considered=$((considered+1))
  if [ ! -e "$line" ]; then missing=$((missing+1)); continue; fi
  if [ ! -f "$line" ]; then not_regular=$((not_regular+1)); continue; fi
  printf '%s\n' "$line" >> "$VERIFIED_PLAN"
  verified=$((verified+1))
done < "$PLAN_FILE"

$has_crlf && log_warn "Plan has CRLF line endings; handled during read. To normalise: sed -i 's/\r$//' "$PLAN_FILE""

log_info "Verification complete."
log_info "  • Considered: $considered"
log_info "  • Missing: $missing"
log_info "  • Not regular files: $not_regular"
log_info "  • Verified (will act on): $verified"
log_info "Verified plan file: $VERIFIED_PLAN"

if ! $FORCE; then
  printf "[DRY-RUN SUMMARY]\n"
  printf "  Files that would be acted on: %s\n" "$verified"
  printf "  To execute delete:    ./bin/delete-duplicates.sh --from-plan "%s" --force\n" "$PLAN_FILE"
  printf "  To quarantine to dir: ./bin/delete-duplicates.sh --from-plan "%s" --force --quarantine "var/quarantine/$(date +%F)"\n" "$PLAN_FILE"
  exit 0
fi

# Ensure quarantine dir if used
if [ -n "$QUARANTINE_DIR" ]; then mkdir -p "$QUARANTINE_DIR"; fi

# Execute
acted=0; errs=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  if [ -n "$QUARANTINE_DIR" ]; then
    # Preserve tree under quarantine dir
    clean="${path#/}"                             # strip leading slashes
    dest="${QUARANTINE_DIR%/}/$clean"
    dest_dir="$(dirname -- "$dest")"
    mkdir -p -- "$dest_dir"
    if mv -f -- "$path" "$dest" 2>>"$SUMMARY_LOG"; then
      log_info "Quarantined: $path -> $dest"; acted=$((acted+1))
    else
      log_error "Failed to quarantine: $path"; errs=$((errs+1))
    fi
  else
    if rm -f -- "$path" 2>>"$SUMMARY_LOG"; then
      log_info "Deleted: $path"; acted=$((acted+1))
    else
      log_error "Failed to delete: $path"; errs=$((errs+1))
    fi
  fi
done < "$VERIFIED_PLAN"

log_info "Execution complete. Acted on: $acted, errors: $errs"
exit 0
