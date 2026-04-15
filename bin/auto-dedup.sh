#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#
# auto-dedup.sh — non-interactive duplicate resolution
#
# Reads a duplicate report and automatically generates a dedup plan without
# any interactive prompts.  For each duplicate group the KEEP strategy
# decides which single copy to retain; all others are written as DEL entries.
#
# Keep strategies:
#   shortest-path  keep the copy with the fewest characters in its path (default)
#   longest-path   keep the copy with the most  characters in its path
#   newest         keep the most  recently modified copy
#   oldest         keep the least recently modified copy
#
# The plan file produced is identical in format to the one produced by
# review-duplicates.sh (KEEP|path / DEL|path lines) and is consumed by
# delete-duplicates.sh unchanged.
#
# Usage:
#   bin/auto-dedup.sh [--from-report PATH] [--plan-out PATH]
#                     [--keep shortest-path|longest-path|newest|oldest]
#                     [--dry-run] [--force]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs";   mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";     mkdir -p "$VAR_DIR"
LOCAL_DIR="$ROOT_DIR/local"; mkdir -p "$LOCAL_DIR"
EXCEPTIONS_FILE="$LOCAL_DIR/exceptions-hashes.txt"

REPORT_DEFAULT="$LOGS_DIR/duplicate-hashes-latest.txt"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
PLAN_DEFAULT="$LOGS_DIR/auto-dedup-plan-$(date +%F)-$RUN_ID.txt"

REPORT="$REPORT_DEFAULT"
PLAN_OUT="$PLAN_DEFAULT"
KEEP_STRATEGY="shortest-path"
DRY_RUN=0
FORCE=0

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  COK="$(printf '\033[1;32m')"; CW="$(printf '\033[1;33m')"
  CE="$(printf '\033[1;31m')";  CI="$(printf '\033[1;34m')"; C0="$(printf '\033[0m')"
else
  COK=""; CW=""; CE=""; CI=""; C0=""
fi
info()  { printf "%s[INFO]%s  %s\n"  "$COK" "$C0" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n"  "$CW"  "$C0" "$*"; }
err()   { printf "%s[ERROR]%s %s\n"  "$CE"  "$C0" "$*"; }
detail(){ printf "%s[AUTO]%s  %s\n"  "$CI"  "$C0" "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  --from-report PATH   Duplicate report to process
                       (default: logs/duplicate-hashes-latest.txt)
  --plan-out PATH      Where to write the plan file
                       (default: logs/auto-dedup-plan-DATE-RUNID.txt)
  --keep STRATEGY      Which copy to keep in each group (default: shortest-path)
                         shortest-path  keep the copy with the shortest file path
                         longest-path   keep the copy with the longest  file path
                         newest         keep the most  recently modified copy
                         oldest         keep the least recently modified copy
  --dry-run            Print what would be done without writing any plan file
  --force              Skip the confirmation prompt
  -h, --help           Show this help

The plan file is compatible with delete-duplicates.sh (KEEP|path / DEL|path).
Review it before applying:
  cat  <plan-file>
  bin/delete-duplicates.sh <plan-file>
EOF
}

# ── Parse args ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT="${2?'--from-report requires a path'}";     shift 2 ;;
    --plan-out)    PLAN_OUT="${2?'--plan-out requires a path'}";       shift 2 ;;
    --keep)        KEEP_STRATEGY="${2?'--keep requires a strategy'}";  shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --force)       FORCE=1;   shift ;;
    -h|--help)     usage; exit 0 ;;
    *) warn "Ignoring unknown argument: $1"; shift ;;
  esac
done

case "$KEEP_STRATEGY" in
  shortest-path|longest-path|newest|oldest) ;;
  *) err "Unknown --keep strategy: '$KEEP_STRATEGY'"; err "Valid: shortest-path, longest-path, newest, oldest"; exit 2 ;;
esac

# ── Validate inputs ────────────────────────────────────────────────────────────
[ -r "$REPORT" ] || { err "Report not found: $REPORT"; err "Run option 3 (Find duplicate files) first."; exit 1; }

if [ "$DRY_RUN" -eq 0 ]; then
  touch "$PLAN_OUT" 2>/dev/null || { err "Cannot write plan file: $PLAN_OUT"; exit 1; }
fi

# ── Load exceptions ────────────────────────────────────────────────────────────
EXC_CLEAN="$VAR_DIR/auto-dedup-exc-$RUN_ID.tmp"
if [ -f "$EXCEPTIONS_FILE" ]; then
  grep -v '^[[:space:]]*#' "$EXCEPTIONS_FILE" 2>/dev/null \
    | sed 's/[[:space:]]//g' | sed '/^$/d' > "$EXC_CLEAN" || true
else
  : > "$EXC_CLEAN"
fi
trap 'rm -f "$EXC_CLEAN" 2>/dev/null || true' EXIT INT TERM

hash_is_exception() {
  [ -f "$EXC_CLEAN" ] && grep -qxF "$1" "$EXC_CLEAN" 2>/dev/null
}

# ── Stat helpers ───────────────────────────────────────────────────────────────
file_mtime() {
  stat -c %Y "$1" 2>/dev/null && return
  stat -f %m "$1" 2>/dev/null && return
  echo 0
}

path_len() { printf '%s' "$1" | wc -c | awk '{print $1}'; }

# ── Choose keeper from a list of paths (one per line on stdin) ─────────────────
# Prints the single path that should be kept.
choose_keeper() {
  # Read all paths into positional params via a temp file
  _tmpf="$VAR_DIR/auto-dedup-grp-$RUN_ID.tmp"
  cat > "$_tmpf"
  [ -s "$_tmpf" ] || { rm -f "$_tmpf"; return; }

  case "$KEEP_STRATEGY" in

    shortest-path)
      # Keep the path with the fewest characters.
      awk '{print length, $0}' "$_tmpf" | sort -n -k1,1 | head -n1 | cut -d' ' -f2-
      ;;

    longest-path)
      awk '{print length, $0}' "$_tmpf" | sort -rn -k1,1 | head -n1 | cut -d' ' -f2-
      ;;

    newest)
      while IFS= read -r _p || [ -n "$_p" ]; do
        [ -z "$_p" ] && continue
        printf '%s\t%s\n' "$(file_mtime "$_p")" "$_p"
      done < "$_tmpf" | sort -rn -k1,1 | head -n1 | cut -f2-
      ;;

    oldest)
      while IFS= read -r _p || [ -n "$_p" ]; do
        [ -z "$_p" ] && continue
        printf '%s\t%s\n' "$(file_mtime "$_p")" "$_p"
      done < "$_tmpf" | sort -n -k1,1 | head -n1 | cut -f2-
      ;;

  esac
  rm -f "$_tmpf"
}

# ── Count groups ───────────────────────────────────────────────────────────────
TOTAL_GROUPS="$(awk '/^HASH /{n++} END{print n+0}' "$REPORT")"
[ "$TOTAL_GROUPS" -gt 0 ] || { warn "No duplicate groups found in report."; exit 0; }

EXC_COUNT="$(wc -l < "$EXC_CLEAN" | tr -d ' ')"

info "Report         : $REPORT"
info "Keep strategy  : $KEEP_STRATEGY"
info "Total groups   : $TOTAL_GROUPS"
info "Exceptions     : $EXC_COUNT hash(es) will be skipped"
[ "$DRY_RUN" -eq 1 ] && info "Mode           : DRY RUN (no plan file written)" \
                      || info "Plan output    : $PLAN_OUT"

# ── Confirm ────────────────────────────────────────────────────────────────────
if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  echo
  printf "This will automatically generate a dedup plan for ALL %d groups\n" "$TOTAL_GROUPS"
  printf "using strategy '%s'. No files will be moved yet.\n" "$KEEP_STRATEGY"
  printf "Review the plan before running delete-duplicates.sh.\n"
  echo
  printf "Proceed? [y/N] "
  read -r _ans || _ans="n"
  case "$_ans" in
    y|Y|yes|YES) ;;
    *) info "Aborted."; exit 0 ;;
  esac
fi

# ── Main processing pass ───────────────────────────────────────────────────────
echo

GRP_TMP="$VAR_DIR/auto-dedup-paths-$RUN_ID.tmp"
: > "$GRP_TMP"

groups_processed=0
groups_skipped=0
files_kept=0
files_del=0

in_group=0
cur_hash=""

flush_group() {
  [ "$in_group" -eq 1 ] || return 0
  [ -s "$GRP_TMP" ]     || return 0

  if hash_is_exception "$cur_hash"; then
    groups_skipped=$((groups_skipped+1))
    : > "$GRP_TMP"
    return 0
  fi

  # Determine keeper
  keeper="$(choose_keeper < "$GRP_TMP")"
  if [ -z "$keeper" ]; then
    warn "Could not determine keeper for hash $cur_hash — skipping group"
    groups_skipped=$((groups_skipped+1))
    : > "$GRP_TMP"
    return 0
  fi

  groups_processed=$((groups_processed+1))

  # Write plan entries
  while IFS= read -r _fp || [ -n "$_fp" ]; do
    [ -z "$_fp" ] && continue
    if [ "$_fp" = "$keeper" ]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        printf 'KEEP|%s\n' "$_fp" >> "$PLAN_OUT"
      else
        detail "KEEP  $_fp"
      fi
      files_kept=$((files_kept+1))
    else
      if [ "$DRY_RUN" -eq 0 ]; then
        printf 'DEL|%s\n' "$_fp" >> "$PLAN_OUT"
      else
        detail "DEL   $_fp"
      fi
      files_del=$((files_del+1))
    fi
  done < "$GRP_TMP"

  : > "$GRP_TMP"

  # Progress every 100 groups
  if [ $((groups_processed % 100)) -eq 0 ]; then
    info "  ... $groups_processed groups processed"
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HASH\ *)
      flush_group
      in_group=1
      cur_hash="$(printf '%s' "$line" | awk '{print $2}')"
      : > "$GRP_TMP"
      ;;
    *)
      if [ "$in_group" -eq 1 ]; then
        _trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
        case "$_trimmed" in
          /*) printf '%s\n' "$_trimmed" >> "$GRP_TMP" ;;
        esac
      fi
      ;;
  esac
done < "$REPORT"

flush_group  # handle last group
rm -f "$GRP_TMP" 2>/dev/null || true

# ── Summary ────────────────────────────────────────────────────────────────────
echo
info "── Auto-dedup complete ──────────────────────────────"
info "Groups processed : $groups_processed"
info "Groups skipped   : $groups_skipped (exceptions)"
info "Files to keep    : $files_kept"
info "Files to delete  : $files_del"

if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry run — no plan file written."
else
  info "Plan written to  : $PLAN_OUT"
  echo
  info "Next steps:"
  info "  1. Review the plan:   cat $PLAN_OUT | grep '^DEL' | head -50"
  info "  2. Apply the plan:    bin/delete-duplicates.sh $PLAN_OUT"
fi

exit 0
