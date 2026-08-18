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
ZERO_DIR="$VAR_DIR/zero-length"

mkdir -p "$LOGS_DIR" "$VAR_DIR"

# v1.3.13 (recheck item 8): this script takes NO arguments. Previously any
# argument (including --dry-run) was silently ignored, which made it look like
# a dry-run had happened when logs were actually pruned. Reject unknown args
# honestly rather than pretending.
if [ "$#" -gt 0 ]; then
  printf '[ERR] clean-logs.sh takes no arguments (got: %s)\n' "$*" >&2
  printf '      There is no --dry-run mode; it prunes according to fixed retention rules.\n' >&2
  exit 2
fi

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
  # v1.4.32: callers pass KEEP, LABEL, then the shell-expanded file set.
  # The old PATTERN-first API let an unquoted glob expand *before* function
  # invocation, shifting KEEP/LABEL into the wrong positional parameters as
  # soon as more than one report existed. Keep paths as distinct argv entries
  # and prune the oldest with Bash's -ot test instead of parsing `ls` output.
  local keep="$1" label="$2" f i oldest_index
  local -a files=()
  shift 2

  case "$keep" in
    ''|*[!0-9]*) warn "Invalid retention count for $label: $keep"; return 1 ;;
  esac

  # A no-match glob is passed literally by Bash; ignore anything that is not
  # currently a regular file. Quoted argv preserves spaces and other shell
  # metacharacters in real filenames.
  for f in "$@"; do
    [ -f "$f" ] && files[${#files[@]}]="$f"
  done

  while [ "${#files[@]}" -gt "$keep" ]; do
    oldest_index=""
    for i in "${!files[@]}"; do
      if [ -z "$oldest_index" ] || [ "${files[$i]}" -ot "${files[$oldest_index]}" ]; then
        oldest_index="$i"
      fi
    done

    [ -n "$oldest_index" ] || break
    f="${files[$oldest_index]}"
    info "Deleting old $label: $(basename "$f")"
    rm -f -- "$f"
    unset "files[$oldest_index]"
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
# v1.3.20 (peer-review recheck observation): v1.3.19's post_run_reports
# renamed these to `duplicate-hashes-YYYY-MM-DD-HHMMSS-PID.txt`. The old
# `20*-duplicate-hashes.txt` glob only matched the pre-v1.3.19 layout;
# without this update the new per-run reports accumulate indefinitely.
# Also legacy-cover any old-format files that may still exist on hosts
# that were upgraded from v1.3.18-or-earlier.
keep_latest_n 5 "verified duplicate-hashes report" "$LOGS_DIR"/duplicate-hashes-20*.txt
keep_latest_n 5 "preliminary hash-scan duplicate summary" "$LOGS_DIR"/hash-scan-duplicate-summary-20*.txt
keep_latest_n 5 "duplicate-hashes report (legacy)" "$LOGS_DIR"/20*-duplicate-hashes.txt

# Keep last 5 duplicate-groups text reports
keep_latest_n 5 "duplicate-groups report" "$LOGS_DIR"/duplicate-groups-*.txt

# v1.3.30: prepared review indexes are paired with verified duplicate reports.
# Preserve the latest pointer and retain the five newest immutable indexes.
keep_latest_n 5 "duplicate review index" "$LOGS_DIR"/duplicate-review-index-20*.tsv

# Keep last 5 duplicates CSVs
keep_latest_n 5 "duplicates CSV" "$LOGS_DIR"/duplicates-*.csv

# Keep last 10 large file index lists
keep_latest_n 10 "file index list" "$LOGS_DIR"/files-*.lst

# Keep last 10 review dedupe plans
keep_latest_n 10 "review dedupe plan" "$LOGS_DIR"/review-dedupe-plan-*.txt

# Keep last 10 duplicate-folders plans
keep_latest_n 10 "duplicate-folders plan" "$LOGS_DIR"/duplicate-folders-plan-*.txt

# Keep last 10 folder-review plans
# v1.3.13 (recheck item 8): retention patterns updated to CURRENT artefact
# names. The old review-folder-dedupe-plan-*.txt and apply-file-plan-*.log
# patterns matched nothing (those artefacts no longer exist). With v1.3.13's
# timestamped raw folder artefacts, same-day runs accumulate instead of
# overwriting — so groups TSVs need retention too.
keep_latest_n 10 "duplicate-folders groups TSV" "$LOGS_DIR"/duplicate-folders-groups-*.tsv
keep_latest_n 10 "reviewed folder plan" "$LOGS_DIR"/duplicate-folders-plan-reviewed-*.txt
keep_latest_n 10 "reviewed folder groups TSV" "$LOGS_DIR"/duplicate-folders-groups-reviewed-*.tsv
keep_latest_n 10 "apply-folder-plan log" "$LOGS_DIR"/apply-folder-plan-*.log
keep_latest_n 10 "delete-zero-length log" "$LOGS_DIR"/delete-zero-length-*.log

# v1.3.20 (peer-review recheck observation): per-run zero-length reports
# under var/zero-length/ now also get retention. Same 5-run policy as
# duplicate-hashes; the -latest symlink is preserved. Covers both the new
# CSV_TAG-based naming and any legacy date-only files.
if [ -d "$ZERO_DIR" ]; then
  keep_latest_n 5 "zero-length report" "$ZERO_DIR"/zero-length-20*.txt
fi

# 3) Rotate main logs if they grow too large (> 5 MiB)
MAX_LOG_BYTES=$((5 * 1024 * 1024))

rotate_if_big "$LOGS_DIR/hasher.log"        "hasher.log"        "$MAX_LOG_BYTES"
rotate_if_big "$LOGS_DIR/background.log"    "background.log"    "$MAX_LOG_BYTES"
rotate_if_big "$LOGS_DIR/cron-hasher.log"   "cron-hasher.log"   "$MAX_LOG_BYTES"
rotate_if_big "$LOGS_DIR/folder-actions.log" "folder-actions.log" "$MAX_LOG_BYTES"

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
