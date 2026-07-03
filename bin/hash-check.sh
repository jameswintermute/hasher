#!/bin/sh
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# hash-check.sh — lookup a file by its content hash in Hasher's outputs
# BusyBox / POSIX sh compatible

set -eu

HASH_DIR="${HASH_DIR:-./hashes}"
HASH_VALUE="${1:-}"

usage() {
    echo "Usage: $0 <sha256-hash>"
    echo "Looks for the hash in the latest Hasher CSV/report under: $HASH_DIR"
    exit 1
}

is_valid_sha256() {
    [ ${#HASH_VALUE} -eq 64 ] && echo "$HASH_VALUE" | grep -qiE '^[0-9a-f]+$'
}

latest_hash_file() {
    # shellcheck disable=SC2012
    ls -1t "$HASH_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true
}

list_all_hash_files() {
    ls -1t "$HASH_DIR"/hasher-*.csv 2>/dev/null || true
}

extract_date_from_filename() {
    bn=$(basename "$1")
    echo "$bn" | sed 's/^hasher-//; s/\.csv$//'
}

# Parse header to detect column positions dynamically
detect_columns() {
    hdr="$(head -n1 "$1" 2>/dev/null || true)"
    [ -z "$hdr" ] && return 1
    i=1
    echo "$hdr" | tr ',' '\n' | while IFS= read -r col; do
        lc="$(echo "$col" | tr '[:upper:]' '[:lower:]')"
        case "$lc" in
            *path*) echo "PATH_COL=$i" ;;
            *hash*) echo "HASH_COL=$i" ;;
            *algo*) echo "ALGO_COL=$i" ;;
            *size*) echo "SIZE_COL=$i" ;;
        esac
        i=$((i+1))
    done
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
[ -z "$HASH_VALUE" ] && usage

if ! is_valid_sha256 ; then
    echo "ERROR: '$HASH_VALUE' does not look like a valid 64-char SHA256 hash."
    exit 2
fi

if [ ! -d "$HASH_DIR" ]; then
    echo "ERROR: hash directory '$HASH_DIR' not found."
    exit 3
fi

LATEST_FILE="$(latest_hash_file)"
if [ -z "$LATEST_FILE" ] || [ ! -f "$LATEST_FILE" ]; then
    echo "No hasher-*.csv files found in $HASH_DIR"
    exit 4
fi

LATEST_DATE="$(extract_date_from_filename "$LATEST_FILE")"
echo "🔍 Searching latest report: $(basename "$LATEST_FILE") (date: $LATEST_DATE)..."

# Detect CSV column layout
eval "$(detect_columns "$LATEST_FILE" | grep -E 'PATH_COL|HASH_COL' || true)"
PATH_COL="${PATH_COL:-1}"
HASH_COL="${HASH_COL:-4}"

FOUND_LINE="$(grep -F "$HASH_VALUE" "$LATEST_FILE" | head -n1 || true)"
if [ -z "$FOUND_LINE" ]; then
    echo "❌ Hash not found in latest report."
    exit 0
fi

# v1.3.13 (recheck item 3): extract a CSV field QUOTE-AWARELY. The previous
# naive `awk -F,` misreported any path containing a comma (e.g. "a,b.txt" showed
# as `"/…/a`). This is the same RFC4180 state-machine parser used by
# find-duplicates.sh and delete-zero-length.sh: quoted fields may contain
# commas, and "" inside a quoted field is a literal quote.
csv_field() {  # csv_field LINE FIELD_NUM
  printf '%s\n' "$1" | awk -v p="$2" '
    function csv_split(s,    i, c, nf, cur, inq, n) {
      n = length(s); nf = 0; cur = ""; inq = 0;
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1);
        if (inq) {
          if (c == "\"") {
            if (substr(s, i+1, 1) == "\"") { cur = cur "\""; i++; }
            else { inq = 0; }
          } else { cur = cur c; }
        } else {
          if (c == "\"") { inq = 1; }
          else if (c == ",") { F[++nf] = cur; cur = ""; }
          else { cur = cur c; }
        }
      }
      F[++nf] = cur;
      return nf;
    }
    { nf = csv_split($0); if (p >= 1 && p <= nf) print F[p]; }'
}

PATH_FIELD="$(csv_field "$FOUND_LINE" "$PATH_COL")"
FILE_NAME="$(basename "$PATH_FIELD" 2>/dev/null || echo unknown)"

echo "✅ Found in latest hash report"
echo "📄 File: $FILE_NAME"
echo "📁 Path: $PATH_FIELD"
echo "🔑 Hash: $HASH_VALUE"
echo "📅 Seen in report date: $LATEST_DATE"

printf "\nWould you like to check older reports to find earliest record? [y/N]: "
read -r ans || ans=""
case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
  y|yes)
    FILES="$(list_all_hash_files)"
    COUNT=$(echo "$FILES" | wc -l | tr -d ' ')
    IDX=0
    FIRST_DATE="$LATEST_DATE"
    FIRST_FILE="$LATEST_FILE"
    echo ""
    for f in $FILES; do
        IDX=$((IDX+1))
        printf "\r⏳ Scanning %d/%d: %s" "$IDX" "$COUNT" "$(basename "$f")" 1>&2
        if grep -Fq "$HASH_VALUE" "$f"; then
            FIRST_FILE="$f"
            FIRST_DATE="$(extract_date_from_filename "$f")"
        fi
    done
    echo ""
    if [ "$FIRST_FILE" != "$LATEST_FILE" ]; then
        echo "🕓 Earliest occurrence found:"
        echo "📅 Date: $FIRST_DATE"
        echo "📁 File: $(basename "$FIRST_FILE")"
        echo "📄 File: $FILE_NAME"
    else
        echo "ℹ️  No earlier occurrences found (same as latest)."
    fi
    ;;
  *)
    echo "Skipped historical search."
    ;;
esac
