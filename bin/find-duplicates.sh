#!/bin/sh
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# Hasher — Duplicate Finder (BusyBox/POSIX safe, CSV-safe)
# Usage: bin/find-duplicates.sh --csv FILE [--out DIR] [--min-size-bytes N]
# Also accepts legacy: --input FILE
set -eu

BIN_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$BIN_DIR/.." && pwd -P)"

CSV=""
OUTDIR=""
MINSZ="0"

# Parse args
while [ "$#" -gt 0 ]; do
  case "$1" in
    --csv|--input) shift; CSV="${1:-}";;
    --out) shift; OUTDIR="${1:-}";;
    --min-size-bytes) shift; MINSZ="${1:-0}";;
    -h|--help)
      echo "Usage: $0 --csv FILE [--out DIR] [--min-size-bytes N]"; exit 0;;
    *) : ;;
  esac
  shift || true
done

[ -n "${CSV:-}" ] || { echo "ERROR: --csv FILE is required" >&2; exit 2; }
[ -r "$CSV" ] || { echo "ERROR: CSV not readable: $CSV" >&2; exit 2; }

# Default OUTDIR
if [ -z "${OUTDIR:-}" ]; then
  TS="$(date +%F-%H%M%S 2>/dev/null || date)"
  OUTDIR="$ROOT_DIR/logs/du-$TS"
fi
mkdir -p "$OUTDIR"

TMP_SUM="$OUTDIR/groups.tmp.tsv"      # hash<TAB>count<TAB>first_size_bytes
TMP_DUP="$OUTDIR/duplicates.txt"      # human list
: > "$TMP_SUM"
: > "$TMP_DUP"

# CSV-safe: split line from the RIGHT by 4 commas (only PATH may contain commas)
awk -v outsum="$TMP_SUM" -v outdup="$TMP_DUP" -v minsz="$MINSZ" '
  NR==1 { next } # header
  {
    s=$0
    n=0; pos=0
    while ( (i=index(substr(s,pos+1),",")) > 0 ) { pos += i; n++; c[n]=pos }
    if (n < 4) next
    c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]

    path = substr(s,1,c1-1)
    size = substr(s,c1+1,c2-c1-1)
    hash = substr(s,c4+1)

    # unquote path if quoted; undouble quotes
    if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }

    # normalize
    gsub(/^[ \t]+|[ \t]+$/,"",hash)
    gsub(/[^0-9]/,"",size)

    if (hash=="" || path=="") next
    if (size+0 < minsz+0) next

    cnt[hash]++
    if (!(hash in fsize)) fsize[hash]=size+0
    files[hash] = (hash in files ? files[hash] "\n" path : path)

    # clear positions
    for (k=1;k<=n;k++) delete c[k]
  }
  END{
    for (h in cnt) if (cnt[h]>1) {
      printf "%s\t%d\t%d\n", h, cnt[h], fsize[h] >> outsum
      printf "HASH %s (%d files):\n", h, cnt[h] >> outdup
      n=split(files[h], arr, "\n")
      for(i=1;i<=n;i++) printf "  %s\n", arr[i] >> outdup
      printf "\n" >> outdup
    }
  }
' "$CSV"

if [ ! -s "$TMP_SUM" ]; then
  echo "No duplicate groups found (or below min size)."
  exit 0
fi

# Derive outputs
awk -F'\t' '{printf "%s,%d\n", $1, $2}' "$TMP_SUM" > "$OUTDIR/groups.summary.txt"

# top-groups.txt (by count desc, up to 50)
if sort -t '	' -k2,2nr "$TMP_SUM" >/dev/null 2>&1; then
  sort -t '	' -k2,2nr "$TMP_SUM" | head -n 50 | awk -F'\t' '{printf "%s,%d\n", $1, $2}' > "$OUTDIR/top-groups.txt"
else
  awk -F'\t' '{print $2"\t"$0}' "$TMP_SUM" | sort -nr | cut -f2- | head -n 50 | awk -F'\t' '{printf "%s,%d\n", $1, $2}' > "$OUTDIR/top-groups.txt" || true
fi

# duplicates.csv with reclaim bytes (sorted by reclaim desc when possible)
awk -F'\t' '{reclaim=($2-1)*$3; printf "%s,%d,%d\n", $1,$2,reclaim}' "$TMP_SUM" \
  | sort -t',' -k3,3nr > "$OUTDIR/duplicates.csv" 2>/dev/null || \
awk -F'\t' '{reclaim=($2-1)*$3; printf "%s,%d,%d\n", $1,$2,reclaim}' "$TMP_SUM" > "$OUTDIR/duplicates.csv"

awk -F',' '{sum+=$3} END{printf "%d\n", (sum+0)}' "$OUTDIR/duplicates.csv" > "$OUTDIR/reclaimable.txt"

echo "Duplicate analysis complete."
echo "  • Summary:         $OUTDIR/groups.summary.txt"
echo "  • Top groups:      $OUTDIR/top-groups.txt"
echo "  • Reclaim (bytes): $OUTDIR/reclaimable.txt"
echo "  • CSV (reclaim):   $OUTDIR/duplicates.csv"
echo "  • Details:         $TMP_DUP"
