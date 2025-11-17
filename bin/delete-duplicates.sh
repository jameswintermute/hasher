#!/bin/sh
# delete-duplicates.sh — apply file delete plan (move to quarantine)
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs";        mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";          mkdir -p "$VAR_DIR"
QUAR_DIR="$ROOT_DIR/quarantine";  mkdir -p "$QUAR_DIR"

PLAN_FILE="${1:-}"

info()  { printf "[INFO] %s
"  "$1" >&2; }
warn()  { printf "[WARN] %s
"  "$1" >&2; }
error() { printf "[ERROR] %s
" "$1" >&2; }

if [ -z "$PLAN_FILE" ]; then
  # fall back to latest review plan if not explicitly given
  PLAN_FILE="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
fi

[ -n "${PLAN_FILE:-}" ] || { warn "No review dedupe plan file found."; exit 0; }
[ -r "$PLAN_FILE" ] || { error "Plan file not readable: $PLAN_FILE"; exit 1; }

info "Using FILE delete plan: $PLAN_FILE"

# Count DEL entries
TOTAL_DEL=$(grep -c '^DEL|' "$PLAN_FILE" 2>/dev/null || true)
if [ "$TOTAL_DEL" -eq 0 ]; then
  warn "No DEL entries found in plan (nothing to do)."
  exit 0
fi

# Pass 1: count existing vs missing
existing=0
missing=0

while IFS= read -r line; do
  case "$line" in
    DEL\|*)
      path=${line#DEL|}
      [ -z "$path" ] && continue
      if [ -e "$path" ]; then
        existing=$((existing+1))
      else
        missing=$((missing+1))
      fi
      ;;
  esac
done <"$PLAN_FILE"

if [ "$existing" -eq 0 ]; then
  warn "No existing files in plan (nothing to do)."
  exit 0
fi

info "Plan summary: $TOTAL_DEL DEL entries; $existing currently exist, $missing already missing."

# Quarantine layout: mirror full path under $QUAR_DIR
# e.g. /volume1/foo/bar.jpg -> $QUAR_DIR/volume1/foo/bar.jpg
moves_ok=0
moves_fail=0

while IFS= read -r line; do
  case "$line" in
    DEL\|*)
      src=${line#DEL|}
      [ -z "$src" ] && continue
      [ -e "$src" ] || continue

      # Build destination path
      case "$src" in
        /*) dest="$QUAR_DIR$src" ;;
        *)  dest="$QUAR_DIR/$src" ;;
      esac
      dest_dir=$(dirname "$dest")
      mkdir -p "$dest_dir"

      if mv -n -- "$src" "$dest"; then
        moves_ok=$((moves_ok+1))
      else
        warn "Failed to move: $src"
        moves_fail=$((moves_fail+1))
      fi
      ;;
  esac
done <"$PLAN_FILE"

info "Move complete: $moves_ok files moved to quarantine ($QUAR_DIR); $moves_fail failures."
exit 0
