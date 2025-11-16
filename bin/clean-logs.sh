#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -eu

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"

LOGS_DIR="$APP_HOME/logs"
VAR_DIR="$APP_HOME/var"

mkdir -p "$LOGS_DIR" "$VAR_DIR"

# ---------------------------------------------------------------------------
# Colours / logging (TTY-aware)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RST="$(printf '\033[0m')"
else
  GRN=""; YEL=""; CYAN=""; BOLD=""; RST=""
fi

info() {  printf "%s[INFO]%s %s\n" "$GRN" "$RST" "$*"; }
warn() {  printf "%s[WARN]%s %s\n" "$YEL" "$RST" "$*"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

human_kb() {
  kb="$1"
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  if [ "$kb" -ge 1048576 ] 2>/dev/null; then
    # >= 1 GB
    # 1 GB ~ 1048576 KB
    printf "%.1f GiB" "$(awk "BEGIN{print $kb/1048576}")"
  elif [ "$kb" -ge 1024 ] 2>/dev/null; then
    printf "%.1f MiB" "$(awk "BEGIN{print $kb/1024}")"
  else
    printf "%d KiB" "$kb"
  fi
}

keep_latest_n() {
  pattern="$1"
  keep="$2"
  label="$3"

  # Use ls -1t so we get newest first; ignore errors if no matches
  files="$(ls -1t $pattern 2>/dev/null || true)"
  [ -z "${files:-}" ] && return 0

  echo "$files" | awk -v keep="$keep" 'NR>keep {print}' | while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -f "$f" ]; then
      info "Deleting old $label: $(basename "$f")"
      rm -f -- "$f"
    fi
  done
}

delete_empty_logs() {
  info "Removing 0-byte logs & plans in $LOGS_DIR…"
  # Only top-level files in logs/, not subdirs
  find "$LOGS_DIR" -maxdepth 1 -type f -size 0c 2>/dev/null | while IFS= read -r f; do
    [ -z "$f" ] && continue
    info "Deleting empty file: $(basename "$f")"
    rm -f -- "$f"
  done
}

rotate_if_big() {
  file="$1"
  label="$2"
  max_bytes="$3"

  [ -f "$file" ] || return 0

  size_bytes="$(wc -c <"$file" 2>/dev/null || echo 0)"
  case "$size_bytes" in ''|*[!0-9]*) size_bytes=0 ;; esac

  if [ "$size_bytes" -gt "$max_bytes" ] 2>/dev/null; then
    ts="$(date +%Y%m%d-%H%M%S)"
    rot="${file}.${ts}.rot"
    info "Rotating $label (size $size_bytes bytes) → $(basename "$rot")"
    mv -- "$file" "$rot"
    : >"$file"
  fi
}

du_kb() {
  # Return disk usage in KiB for a path
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

info "Hasher log housekeeping starting…"
before_kb="$(du_kb "$LOGS_DIR")"
[ -z "$before_kb" ] && before_kb=0
info "Current logs/ usage: $(human_kb "$before_kb")"

# 1) Remove empty logs/plans
delete_empty_logs

# 2) Apply retention rules for heavy files
info "Applying retention rules…"

# Keep last 5 daily duplicate-hashes (exclude duplicate-hashes-latest.txt)
keep_latest_n "$LOGS_DIR"/20*-duplicate-hashes.txt 5 "duplicate-hashes report"

# Keep last 5 duplicate-groups text reports
keep_latest_n "$LOGS_DIR"/duplicate-groups-*.txt 5 "duplicate-groups report"

# Keep last 5 duplicates CSVs
keep_latest_n "$LOGS_DIR"/duplicates-*.csv 5 "duplicates CSV"

# Keep last 10 large file index lists
keep_latest_n "$LOGS_DIR"/files-*.lst 10 "file index list"

# Keep last 10 review dedupe plans
keep_latest_n "$LOGS_DIR"/review-dedupe-plan-*.txt 10 "review dedupe plan"

# Keep last 10 duplicate-folders plans
keep_latest_n "$LOGS_DIR"/duplicate-folders-plan-*.txt 10 "duplicate-folders plan"

# Keep last 10 folder-review plans
keep_latest_n "$LOGS_DIR"/review-folder-dedupe-plan-*.txt 10 "folder review plan"

# Keep last 10 apply-file-plan logs
keep_latest_n "$LOGS_DIR"/apply-file-plan-*.log 10 "apply-file-plan log"

# 3) Rotate main logs if they grow too large (> 5 MiB)
MAX_LOG_BYTES=$((5 * 1024 * 1024))

rotate_if_big "$LOGS_DIR/hasher.log"        "hasher.log"        "$MAX_LOG_BYTES"
rotate_if_big "$LOGS_DIR/background.log"    "background.log"    "$MAX_LOG_BYTES"
rotate_if_big "$LOGS_DIR/cron-hasher.log"   "cron-hasher.log"   "$MAX_LOG_BYTES"

after_kb="$(du_kb "$LOGS_DIR")"
[ -z "$after_kb" ] && after_kb="$before_kb"

if [ "$after_kb" -le "$before_kb" ] 2>/dev/null; then
  saved=$((before_kb - after_kb))
else
  saved=0
fi

echo
info "Log housekeeping complete."
info "logs/ usage was: $(human_kb "$before_kb")"
info "logs/ usage now: $(human_kb "$after_kb")"
info "Approx freed:    $(human_kb "$saved")"

exit 0
