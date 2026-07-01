#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
LOCAL="$ROOT_DIR/local"
PATHS_FILE="$LOCAL/paths.txt"
JUNK_FILE="$LOCAL/junk-extensions.txt"
LOGS="$ROOT_DIR/logs"; mkdir -p "$LOGS"
LISTFILE="$LOGS/junk-candidates-$(date +%F-%H%M%S)-$$.txt"

# Colours + logging helpers (v1.3.9). Previously this script used plain
# `echo "[INFO] ..."` with no colour, so its messages were uncoloured unlike
# the rest of the tool. Build real ESC bytes with printf (TTY only), matching
# the pattern used across the codebase, and route messages through info/warn/err.
if [ -t 1 ]; then
  C_INFO="$(printf '\033[0;36m')"; C_OK="$(printf '\033[0;32m')"
  C_WARN="$(printf '\033[1;33m')"; C_ERR="$(printf '\033[0;31m')"
  C_RST="$(printf '\033[0m')"
else
  C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_RST=''
fi
info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n'   "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RST" "$*"; }
err()  { printf '%s[ERR]%s %s\n'  "$C_ERR"  "$C_RST" "$*" >&2; }

human_size() {
  b="$1"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    awk "BEGIN{printf \"%.1fG\", $b/1073741824}"
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    awk "BEGIN{printf \"%.1fM\", $b/1048576}"
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    awk "BEGIN{printf \"%.1fK\", $b/1024}"
  else
    printf "%dB" "$b"
  fi
}

# read flags
DRY=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force)  FORCE=1 ;;
    --paths-file) PATHS_FILE="$2"; shift ;;
  esac
  shift
done

[ -s "$JUNK_FILE" ] || { err "junk list not found"; exit 1; }
[ -s "$PATHS_FILE" ] || { err "paths file not found"; exit 1; }

info "Using junk list: $JUNK_FILE"
info "Scanning paths from: $PATHS_FILE"

# Build candidates
: > "$LISTFILE"
while IFS= read -r root || [ -n "$root" ]; do
  case "$root" in \#*|"") continue ;; esac
  [ -d "$root" ] || continue
  while IFS= read -r rule || [ -n "$rule" ]; do
    rule_clean="$(printf "%s" "$rule" | sed 's/#.*$//' | xargs)"
    [ -z "$rule_clean" ] && continue
    case "$rule_clean" in
      *.*)
        find "$root" -type f -iname "$rule_clean" -print0 2>/dev/null
        ;;
      *)
        find "$root" -type f -iname "*.$rule_clean" -print0 2>/dev/null
        ;;
    esac
  done < "$JUNK_FILE"
done < "$PATHS_FILE" | tr '\0' '\n' | sort -u > "$LISTFILE"

count=$(wc -l < "$LISTFILE" | tr -d ' ')
[ "$count" -eq 0 ] && { info "No junk files found."; exit 0; }

# Collect sizes
TMP="$LISTFILE.sizes"
: > "$TMP"
total=0
while IFS= read -r f; do
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  total=$((total + sz))
  printf "%s\t%s\n" "$sz" "$f" >> "$TMP"
done < "$LISTFILE"

total_hr=$(human_size "$total")
info "Junk candidates found: $count files, total size ~ $total_hr."

if [ "$count" -le 25 ]; then
  echo
  echo "The following files are marked as junk and can be deleted:"
  echo "( sizes are approximate )"
  echo "---------------------------------------------------------"
  printf "   %s  %s\n" "Size" "Path"
  printf '%s\n' "--------  ---------------------------------------------------------------"
  sort -nr -k1,1 "$TMP" | while IFS=$(printf '\t') read -r s p; do
    printf "%8s  %s\n" "$(human_size "$s")" "$p"
  done
  printf '%s\n' "--------  ---------------------------------------------------------------"
  echo "Total: $count files, ~$total_hr"
  echo "---------------------------------------------------------"
else
  echo
  info "List is long ($count files). Showing top 10 by size:"
  printf "   %s  %s\n" "Size" "Path"
  printf '%s\n' "--------  ---------------------------------------------------------------"
  sort -nr -k1,1 "$TMP" | head -n 10 | while IFS=$(printf '\t') read -r s p; do
    printf "%8s  %s\n" "$(human_size "$s")" "$p"
  done
  printf '%s\n' "--------  ---------------------------------------------------------------"
  echo
  echo "Full list saved to: $LISTFILE"
fi

# confirm
if [ "$DRY" -eq 1 ]; then
  info "Dry run only. No deletions performed."
  exit 0
fi

if [ "$FORCE" -eq 0 ]; then
  printf "Proceed to DELETE these %s junk files (~%s)? [y/N] " "$count" "$total_hr"
  read ans
  case "$ans" in y|Y|yes|YES) ;; *) info "Aborted."; exit 0 ;; esac
fi

info "Deleting junk files…"
del=0
while IFS=$(printf '\t') read -r s p; do
  rm -f -- "$p" 2>/dev/null || true
  del=$((del + 1))
done < "$TMP"

info "Junk deletion complete."
info "Deleted: $del files."
