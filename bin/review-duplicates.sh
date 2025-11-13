#!/bin/sh
# review-duplicates.sh — top-savings-first interactive reviewer (streaming, BusyBox-safe)
# Hasher — NAS File Hasher & Duplicate Finder
# Version: 1.0.9 (adds hash exceptions list & 'A' option)
#
# EXPECTED INPUT
# ---------------
# This script expects a CSV-like duplicates file with lines:
#   HASH,SIZE_BYTES,ABSOLUTE_PATH
# (No header, or header lines starting with '#'.)
#
# Groups are contiguous by HASH (i.e. all lines for a given hash sit together).
# The duplicates generator is responsible for ordering groups (e.g. top-savings-first).
#
# PLAN OUTPUT
# -----------
# A plan file is written with one absolute path per line representing files to delete.
# apply-file-plan.sh should be aligned with this format.
#
# NEW IN 1.0.9
# ------------
# - local/exceptions-hashes.txt: list of SHA256 hashes to NEVER be prompted for.
# - Interactive option [A]: add current group hash to exceptions list.
# - Groups whose hash is in the exceptions list are auto-kept & skipped.

set -eu

# ---------------------------------------------------------------------------
# Resolve ROOT_DIR (repo root: parent of bin/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

LOGS_DIR="$ROOT_DIR/logs"; mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var"; mkdir -p "$VAR_DIR"
DUP_VAR_DIR="$VAR_DIR/duplicates"; mkdir -p "$DUP_VAR_DIR"

PLAN_FILE="$LOGS_DIR/review-dedupe-plan-$(date +%Y%m%d-%H%M%S).txt"
LATEST_PLAN_SYMLINK="$DUP_VAR_DIR/latest-plan.txt"

# Exceptions file: hashes we never want to be prompted for
EXCEPTIONS_FILE="$ROOT_DIR/local/exceptions-hashes.txt"
EXCEPTIONS_DIR="$(dirname "$EXCEPTIONS_FILE")"
[ -d "$EXCEPTIONS_DIR" ] || mkdir -p "$EXCEPTIONS_DIR"
[ -f "$EXCEPTIONS_FILE" ] || : >"$EXCEPTIONS_FILE"

# ---------------------------------------------------------------------------
# Optional TTY colours (BusyBox-safe)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  RED="\033[31m"
  GRN="\033[32m"
  YEL="\033[33m"
  BLU="\033[34m"
  MAG="\033[35m"
  BOLD="\033[1m"
  RST="\033[0m"
else
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; BOLD=""; RST=""
fi

info(){  printf "%s[INFO]%s %s\n"  "$GRN" "$RST" "$*"; }
ok(){    printf "%s[OK  ]%s %s\n"  "$BLU" "$RST" "$*"; }
warn(){  printf "%s[WARN]%s %s\n" "$YEL" "$RST" "$*"; }
err(){   printf "%s[ERR ]%s %s\n"  "$RED" "$RST" "$*"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

human_size() {
  # $1 = size in bytes
  bytes="$1"
  if [ -z "${bytes:-}" ] || [ "$bytes" -lt 0 ] 2>/dev/null; then
    echo "unknown"
    return
  fi

  kb=$((1024))
  mb=$((1024 * 1024))
  gb=$((1024 * 1024 * 1024))

  if [ "$bytes" -ge "$gb" ] 2>/dev/null; then
    int=$((bytes / gb))
    frac=$(((bytes % gb) * 10 / gb))
    echo "${int}.${frac} GB"
  elif [ "$bytes" -ge "$mb" ] 2>/dev/null; then
    int=$((bytes / mb))
    frac=$(((bytes % mb) * 10 / mb))
    echo "${int}.${frac} MB"
  elif [ "$bytes" -ge "$kb" ] 2>/dev/null; then
    int=$((bytes / kb))
    frac=$(((bytes % kb) * 10 / kb))
    echo "${int}.${frac} KB"
  else
    echo "${bytes} B"
  fi
}

_normalise_hash_line() {
  # $1 = line
  case "$1" in
    \#*|"") return 1 ;;
  esac
  # Trim to first field using awk (BusyBox-safe)
  echo "$1" | awk '{print $1}'
}

hash_in_exceptions() {
  # $1 = hash (cur_hash)
  h="$1"
  [ -f "$EXCEPTIONS_FILE" ] || return 1
  # shellcheck disable=SC2162
  while IFS= read -r line || [ -n "$line" ]; do
    norm="$(_normalise_hash_line "$line")" || continue
    [ "$norm" = "$h" ] && return 0
  done <"$EXCEPTIONS_FILE"
  return 1
}

add_hash_to_exceptions() {
  # $1 = hash, $2 = size bytes
  h="$1"
  size_bytes="${2:-0}"
  size_hr="$(human_size "$size_bytes")"

  printf "\nYou have selected to add the hash for this file to your local exceptions list.\n"
  printf "The size of this file is %s.\n" "$size_hr"
  printf "You will no longer be prompted for duplicates with this hash,\n"
  printf "but you can manually remove it later by editing:\n"
  printf "  %s\n\n" "$EXCEPTIONS_FILE"
  printf "Proceed and add this hash to your exceptions list? [y/N]: "

  read -r ans || ans=""
  case "$(echo "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      if hash_in_exceptions "$h"; then
        info "Hash is already in exceptions list."
      else
        printf "%s\n" "$h" >>"$EXCEPTIONS_FILE"
        ok "Hash added to exceptions. This group will be kept."
      fi
      return 0
      ;;
    *)
      info "Not adding hash to exceptions."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Determine input duplicates file
# ---------------------------------------------------------------------------

pick_duplicates_file() {
  # 1) explicit arg
  if [ "${1:-}" != "" ] && [ -f "$1" ]; then
    printf "%s" "$1"
    return 0
  fi

  # 2) known locations in var/duplicates
  # shellcheck disable=SC2012
  latest="$(ls -1t "$DUP_VAR_DIR"/duplicates-*.csv "$DUP_VAR_DIR"/duplicates-latest.csv 2>/dev/null | head -n1 || true)"
  if [ -n "${latest:-}" ] && [ -f "$latest" ]; then
    printf "%s" "$latest"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Flush / handle one group of duplicates
# ---------------------------------------------------------------------------
# Uses global temp file GROUP_TMP containing lines: SIZE_BYTES|ABS_PATH
# Variables:
#   CUR_HASH
# ---------------------------------------------------------------------------

process_group() {
  # no current hash => nothing to do
  [ -n "${CUR_HASH:-}" ] || return 0
  [ -f "$GROUP_TMP" ] || return 0

  # If hash is in exceptions, keep all and skip
  if hash_in_exceptions "$CUR_HASH"; then
    info "Hash %s is in exceptions list; keeping all files in this group." "$CUR_HASH"
    : >"$GROUP_TMP"
    return 0
  fi

  # Build numbered listing and gather sizes
  if [ ! -s "$GROUP_TMP" ]; then
    : >"$GROUP_TMP"
    return 0
  fi

  echo
  printf "%s==== Duplicate group: HASH=%s ====%s\n" "$BOLD" "$CUR_HASH" "$RST"

  # Show candidate files
  idx=0
  TOTAL_SAVINGS=0
  PRIMARY_SIZE=0
  PRIMARY_PATH=""

  # We will copy to a second file with index for later
  GROUP_IDX_TMP="$DUP_VAR_DIR/group-idx-$$.txt"
  : >"$GROUP_IDX_TMP"

  # shellcheck disable=SC2162
  while IFS='|' read -r size path || [ -n "$size" ]; do
    [ -z "$path" ] && continue
    idx=$((idx+1))

    if [ "$idx" -eq 1 ]; then
      PRIMARY_SIZE="$size"
      PRIMARY_PATH="$path"
    else
      TOTAL_SAVINGS=$((TOTAL_SAVINGS + size))
    fi

    size_hr="$(human_size "$size")"
    printf "  [%d] %s (%s)\n" "$idx" "$path" "$size_hr"
    printf "%d|%s|%s\n" "$idx" "$size" "$path" >>"$GROUP_IDX_TMP"
  done <"$GROUP_TMP"

  if [ "$idx" -lt 2 ]; then
    info "Group has fewer than 2 files; skipping."
    rm -f "$GROUP_TMP" "$GROUP_IDX_TMP" 2>/dev/null || true
    return 0
  fi

  savings_hr="$(human_size "$TOTAL_SAVINGS")"
  primary_hr="$(human_size "$PRIMARY_SIZE")"
  echo
  printf "Potential space savings if all but one are deleted: %s\n" "$savings_hr"
  printf "Primary candidate (index 1) size: %s\n" "$primary_hr"

  while :; do
    echo
    printf "Choose the number to keep, or [s]kip, [A]dd hash to exceptions, [q]uit: "
    read -r choice || choice=""
    case "$choice" in
      [0-9]*)
        # validate index
        sel="$choice"
        # find selected entry and delete others
        # shellcheck disable=SC2162
        found=0
        # Pass 1: confirm selection exists
        while IFS='|' read -r idx size path || [ -n "$idx" ]; do
          [ -z "$idx" ] && continue
          if [ "$idx" -eq "$sel" ] 2>/dev/null; then
            found=1
            break
          fi
        done <"$GROUP_IDX_TMP"

        if [ "$found" -eq 0 ]; then
          warn "Invalid selection: $sel"
          continue
        fi

        # Pass 2: write plan entries for all except selected index
        # shellcheck disable=SC2162
        while IFS='|' read -r idx size path || [ -n "$idx" ]; do
          [ -z "$idx" ] && continue
          if [ "$idx" -ne "$sel" ] 2>/dev/null; then
            printf "%s\n" "$path" >>"$PLAN_FILE"
          fi
        done <"$GROUP_IDX_TMP"

        ok "Recorded delete plan for group (kept index %s)." "$sel"
        break
        ;;
      s|S)
        info "Skipping this group (no plan entries written)."
        break
        ;;
      a|A)
        # Add hash to exceptions
        if add_hash_to_exceptions "$CUR_HASH" "$PRIMARY_SIZE"; then
          # treat as keep-all and move on
          break
        else
          # user declined; re-prompt
          continue
        fi
        ;;
      q|Q)
        warn "Quitting review early. Plan so far: $PLAN_FILE"
        rm -f "$GROUP_TMP" "$GROUP_IDX_TMP" 2>/dev/null || true
        exit 0
        ;;
      *)
        warn "Unknown choice: $choice"
        ;;
    esac
  done

  rm -f "$GROUP_TMP" "$GROUP_IDX_TMP" 2>/dev/null || true
  : >"$GROUP_TMP"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

INPUT_FILE="$(pick_duplicates_file "${1:-}")" || {
  err "Could not find duplicates file. Pass path as first argument or ensure files in $DUP_VAR_DIR."
  exit 1
}

info "Using duplicates file: $INPUT_FILE"
info "Plan will be written to: $PLAN_FILE"

GROUP_TMP="$DUP_VAR_DIR/group-$$.txt"
: >"$GROUP_TMP"
CUR_HASH=""
CUR_SIZE_BYTES=0

# shellcheck disable=SC2162
while IFS=, read -r hash size path || [ -n "$hash" ]; do
  case "$hash" in
    \#*|"") continue ;;
  esac

  # Trim whitespace from hash
  hash_trimmed="$(echo "$hash" | awk '{print $1}')"
  size_trimmed="$(echo "$size" | awk '{print $1}')"

  # New group?
  if [ -n "$CUR_HASH" ] && [ "$hash_trimmed" != "$CUR_HASH" ]; then
    process_group
    CUR_HASH="$hash_trimmed"
    CUR_SIZE_BYTES="$size_trimmed"
    : >"$GROUP_TMP"
  fi

  if [ -z "$CUR_HASH" ]; then
    CUR_HASH="$hash_trimmed"
    CUR_SIZE_BYTES="$size_trimmed"
  fi

  printf "%s|%s\n" "$size_trimmed" "$path" >>"$GROUP_TMP"

done <"$INPUT_FILE"

# Process final group
process_group

ok "Review complete. Plan saved to: $PLAN_FILE"

# Update latest-plan symlink/copy for launcher/apply-plan helpers
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  # Prefer symlink if possible
  if command -v ln >/dev/null 2>&1; then
    ln -sf "$PLAN_FILE" "$LATEST_PLAN_SYMLINK" 2>/dev/null || cp -f "$PLAN_FILE" "$LATEST_PLAN_SYMLINK"
  else
    cp -f "$PLAN_FILE" "$LATEST_PLAN_SYMLINK" 2>/dev/null || true
  fi
fi

exit 0
