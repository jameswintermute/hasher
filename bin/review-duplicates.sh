#!/bin/sh
# review-duplicates.sh — top-savings-first interactive reviewer (streaming, BusyBox-safe)
# Hasher — NAS File Hasher & Duplicate Finder
# Version: 1.0.9 (adds hash exceptions list & 'A' option)

set -eu

# ---------------------------------------------------------------------------
# Paths & setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"

BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
VAR_DIR="$APP_HOME/var"
DUP_VAR_DIR="$VAR_DIR/duplicates"
LOCAL_DIR="$APP_HOME/local"
EXCEPTIONS_FILE="$LOCAL_DIR/exceptions-hashes.txt"

mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$VAR_DIR" "$DUP_VAR_DIR" "$LOCAL_DIR"

# ---------------------------------------------------------------------------
# TTY-aware colours
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  RED="$(printf '\033[31m')"
  GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"
  BLU="$(printf '\033[34m')"
  MAG="$(printf '\033[35m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RST="$(printf '\033[0m')"
else
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYAN=""; BOLD=""; RST=""
fi

info(){  printf "%s[INFO]%s %s\n"  "$GRN" "$RST" "$*"; }
warn(){  printf "%s[WARN]%s %s\n"  "$YEL" "$RST" "$*"; }
err(){   printf "%s[ERR ]%s %s\n"  "$RED" "$RST" "$*"; }
next(){  printf "%s[NEXT]%s %s\n" "$CYAN" "$RST" "$*"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

human_size() {
  # Print human-readable size from bytes (integer).
  b="$1"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac

  if [ "$b" -lt 1024 ] 2>/dev/null; then
    printf "%s B" "$b"
    return
  fi

  kb=$((b / 1024))
  if [ "$kb" -lt 1024 ] 2>/dev/null; then
    printf "%s KB" "$kb"
    return
  fi

  mb=$((kb / 1024))
  if [ "$mb" -lt 1024 ] 2>/dev/null; then
    printf "%s MB" "$mb"
    return
  fi

  gb=$((mb / 1024))
  printf "%s GB" "$gb"
}

prompt_yn() {
  msg="$1"
  def="${2:-N}"
  case "$def" in
    Y|y) p=" [Y/n] " ;;
    *)   p=" [y/N] " ;;
  esac
  printf "%s%s" "$msg" "$p"
  read -r a || a=""
  [ -z "$a" ] && a="$def"
  case "$a" in Y|y|yes|YES) return 0 ;; *) return 1 ;; esac
}

numeric_or_zero() {
  v="$1"
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

# Add a hash to the local exceptions list (idempotent)
add_to_exceptions() {
  hash="$1"
  primary_size_bytes="$2"

  touch "$EXCEPTIONS_FILE"

  size_hr="$(human_size "$(numeric_or_zero "$primary_size_bytes")")"

  echo
  printf "You have selected to add this hash to your local exceptions list.\n"
  printf "  Hash: %s\n" "$hash"
  printf "  Example file size: %s\n" "$size_hr"
  printf "You will no longer be prompted for this hash in future runs.\n"
  if ! prompt_yn "Proceed and append to $(basename "$EXCEPTIONS_FILE")?" "N"; then
    info "Not adding hash to exceptions list."
    return 0
  fi

  if grep -q "^$hash\$" "$EXCEPTIONS_FILE" 2>/dev/null; then
    info "Hash already present in exceptions list."
  else
    printf "%s\n" "$hash" >>"$EXCEPTIONS_FILE"
    info "Hash added to exceptions list."
  fi
}

# ---------------------------------------------------------------------------
# Args: we support
#   --input PATH        duplicates-*.csv (hash|size|path)
#   --from-report PATH  duplicate-hashes report that references the CSV
#   --order size|none   group ordering (default: size)
# ---------------------------------------------------------------------------

INPUT_CSV=""
REPORT_FILE=""
ORDER="size"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      shift
      INPUT_CSV="${1:-}"
      ;;
    --from-report)
      shift
      REPORT_FILE="${1:-}"
      ;;
    --order)
      shift
      ORDER="${1:-size}"
      ;;
    --help|-h)
      cat <<EOF
Usage: review-duplicates.sh [--input duplicates.csv] [--from-report report.txt] [--order size|none]

Interactive duplicate reviewer (top-savings-first). Expected duplicates CSV format:
  HASH|SIZE_BYTES|ABSOLUTE_PATH
EOF
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift || true
done

# Resolve CSV from report if needed
if [ -z "$INPUT_CSV" ] && [ -n "$REPORT_FILE" ]; then
  if [ ! -f "$REPORT_FILE" ]; then
    err "Report file not found: $REPORT_FILE"
    exit 1
  fi
  # very simple convention: a line like CSV=/full/path/to/duplicates-*.csv
  INPUT_CSV="$(grep '^CSV=' "$REPORT_FILE" 2>/dev/null | tail -n1 | sed 's/^CSV=//')"
fi

if [ -z "$INPUT_CSV" ]; then
  # Try to guess latest duplicates CSV
  INPUT_CSV="$(ls -1t "$LOGS_DIR"/duplicates-*.csv 2>/dev/null | head -n1 || true)"
fi

if [ -z "$INPUT_CSV" ] || [ ! -f "$INPUT_CSV" ]; then
  err "Could not find duplicates CSV. Run 'find-duplicates.sh' (launcher menu option 3) first."
  exit 1
fi

info "Using duplicates CSV: $INPUT_CSV"

# Plan file path
STAMP="$(date +%Y%m%d-%H%M%S)"
PLAN_FILE="$LOGS_DIR/review-dedupe-plan-$STAMP.txt"
info "Plan will be written to: $PLAN_FILE"
: >"$PLAN_FILE"

# Also record a "latest plan" pointer for the launcher
LATEST_PLAN_LINK="$DUP_VAR_DIR/latest-plan.txt"
# shellcheck disable=SC2174
ln -sf "$PLAN_FILE" "$LATEST_PLAN_LINK" 2>/dev/null || {
  # Fallback: copy path into a tiny file
  printf "%s\n" "$PLAN_FILE" >"$LATEST_PLAN_LINK"
}

# Cleanup any previous temp group files
rm -f "$DUP_VAR_DIR"/group-*.txt "$DUP_VAR_DIR"/group-meta-*.txt 2>/dev/null || true

META_FILE="$DUP_VAR_DIR/group-meta-$STAMP.txt"
: >"$META_FILE"

# ---------------------------------------------------------------------------
# Build per-hash group files: group-HASH.txt with "size|path" lines
# Expected INPUT_CSV lines: HASH|SIZE_BYTES|PATH
# ---------------------------------------------------------------------------

# shellcheck disable=SC2162
while IFS='|' read -r hash size path _rest || [ -n "$hash" ]; do
  [ -z "$hash" ] && continue
  [ -z "$path" ] && continue
  size_num="$(numeric_or_zero "$size")"
  group_file="$DUP_VAR_DIR/group-$hash.txt"
  printf "%s|%s\n" "$size_num" "$path" >>"$group_file"
done <"$INPUT_CSV"

# Summarise each group for ordering
for gf in "$DUP_VAR_DIR"/group-*.txt; do
  [ -f "$gf" ] || continue
  base="${gf##*/group-}"
  hash="${base%.txt}"

  total=0
  maxsize=0
  count=0

  # shellcheck disable=SC2162
  while IFS='|' read -r size path || [ -n "$size" ]; do
    [ -z "$path" ] && continue
    sz="$(numeric_or_zero "$size")"
    total=$((total + sz))
    count=$((count + 1))
    if [ "$sz" -gt "$maxsize" ] 2>/dev/null; then
      maxsize="$sz"
    fi
  done <"$gf"

  [ "$count" -lt 2 ] && continue

  # Savings if we keep one and delete the rest
  savings=$((total - maxsize))
  [ "$savings" -le 0 ] && continue

  printf "%s|%s|%s|%s\n" "$hash" "$savings" "$count" "$gf" >>"$META_FILE"
done

if [ ! -s "$META_FILE" ]; then
  warn "No duplicate groups with savings found. Nothing to review."
  exit 0
fi

META_SORTED="$DUP_VAR_DIR/group-meta-sorted-$STAMP.txt"
if [ "$ORDER" = "size" ]; then
  # Sort by savings descending (field 2)
  sort -t'|' -k2,2nr "$META_FILE" >"$META_SORTED"
else
  cp "$META_FILE" "$META_SORTED"
fi

# ---------------------------------------------------------------------------
# Interactive per-group review
# ---------------------------------------------------------------------------

review_group() {
  group_hash="$1"
  group_file="$2"

  idx=0
  TOTAL_SAVINGS=0
  PRIMARY_SIZE=0
  PRIMARY_PATH=""

  GROUP_IDX_TMP="$DUP_VAR_DIR/group-idx-$$.txt"
  : >"$GROUP_IDX_TMP"

  echo
  printf "%s===== Duplicate group: HASH=%s =====%s\n" "$MAG" "$group_hash" "$RST"

  # shellcheck disable=SC2162
  while IFS='|' read -r size path || [ -n "$size" ]; do
    [ -z "$path" ] && continue
    idx=$((idx+1))

    # Normalise size to safe integer
    size_num="$(numeric_or_zero "$size")"

    if [ "$idx" -eq 1 ]; then
      PRIMARY_SIZE="$size_num"
      PRIMARY_PATH="$path"
    else
      TOTAL_SAVINGS=$((TOTAL_SAVINGS + size_num))
    fi

    size_hr="$(human_size "$size_num")"
    printf "  [%d] %s (%s)\n" "$idx" "$path" "$size_hr"
    printf "%d|%s|%s\n" "$idx" "$size_num" "$path" >>"$GROUP_IDX_TMP"
  done <"$group_file"

  if [ "$idx" -lt 2 ]; then
    info "Group has fewer than 2 files; skipping."
    rm -f "$GROUP_IDX_TMP" 2>/dev/null || true
    return 0
  fi

  savings_hr="$(human_size "$TOTAL_SAVINGS")"
  primary_hr="$(human_size "$PRIMARY_SIZE")"
  echo
  printf "Potential space savings if all but one are deleted: %s\n" "$savings_hr"
  printf "Primary candidate (index 1) size: %s\n" "$primary_hr"
  echo

  while :; do
    printf "Choose file index to KEEP, %ss%s, %sA%s=add hash to exceptions list, %sq%s=quit: " \
      "$BOLD" "$RST" "$BOLD" "$RST" "$BOLD" "$RST"
    read -r choice || { echo; choice="q"; }

    case "$choice" in
      q|Q)
        info "Quitting review."
        rm -f "$GROUP_IDX_TMP" 2>/dev/null || true
        exit 0
        ;;
      s|S)
        info "Skipping this group."
        rm -f "$GROUP_IDX_TMP" 2>/dev/null || true
        return 0
        ;;
      a|A)
        add_to_exceptions "$group_hash" "$PRIMARY_SIZE"
        info "Skipping this group after updating exceptions."
        rm -f "$GROUP_IDX_TMP" 2>/dev/null || true
        return 0
        ;;
      *)
        # must be a positive integer within range
        case "$choice" in ''|*[!0-9]*) warn "Invalid selection. Enter a number, s, a or q."; continue ;; esac
        keep_idx="$choice"
        if [ "$keep_idx" -lt 1 ] || [ "$keep_idx" -gt "$idx" ]; then
          warn "Selection out of range (1..$idx)."
          continue
        fi
        ;;
    esac

    # If we get here, we have a valid keep_idx
    break
  done

  echo
  next "Keeping index $keep_idx and queuing others for deletion in plan:"

  # Walk index file and append non-kept paths to plan
  # shellcheck disable=SC2162
  while IFS='|' read -r idx size path || [ -n "$idx" ]; do
    [ -z "$path" ] && continue
    if [ "$idx" -eq "$keep_idx" ] 2>/dev/null; then
      printf "  KEEP:    %s\n" "$path"
    else
      printf "  DELETE:  %s\n" "$path"
      # Plan format: DELETE|PATH  (kept simple for apply-file-plan.sh)
      printf "DELETE|%s\n" "$path" >>"$PLAN_FILE"
    fi
  done <"$GROUP_IDX_TMP"

  rm -f "$GROUP_IDX_TMP" 2>/dev/null || true
  echo
}

# ---------------------------------------------------------------------------
# Main loop over groups
# ---------------------------------------------------------------------------

# shellcheck disable=SC2162
while IFS='|' read -r hash savings count gf || [ -n "$hash" ]; do
  [ -z "$hash" ] && continue
  [ ! -f "$gf" ] && continue

  savings_hr="$(human_size "$(numeric_or_zero "$savings")")"
  echo
  printf "%s[GROUP]%s Hash=%s, files=%s, potential savings=%s\n" \
    "$BLU" "$RST" "$hash" "$count" "$savings_hr"

  review_group "$hash" "$gf"
done <"$META_SORTED"

info "Review complete. Plan saved to: $PLAN_FILE"
exit 0
