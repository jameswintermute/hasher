#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# find-duplicates.sh — Generate duplicate report from hasher CSV.
# Analyzes only; writes reports; does not delete/move.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────── Config ─────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="$(
  (command -v uuidgen >/dev/null 2>&1 && uuidgen) \
  || cat /proc/sys/kernel/random/uuid 2>/dev/null \
  || echo "$(date +%s)-$$"
)"

REPORT="$LOGS_DIR/$DATE_TAG-duplicate-hashes.txt"
SUMMARY_TSV="$LOGS_DIR/duplicate-summary-$DATE_TAG-$RUN_ID.tsv"
TOP_N=10               # console: top N path groups
GROUP_DEPTH=2          # grouping depth (/volume1/Share = 2)
FROM_CSV=""            # override input CSV
MIN_SIZE=0             # bytes; only consider groups where per-file size >= MIN_SIZE

# ───────── Colors ─────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() {
  local lvl="$1"; shift
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RUN %s] [%s] %s\n' "$ts" "$RUN_ID" "$lvl" "$*" >&2
}

usage() {
cat <<EOF
Usage: $0 [--from-csv FILE] [--min-size BYTES] [--group-depth N] [--top N] [-h|--help]

Find duplicate files by hash from a hasher CSV (default: newest hashes/hasher-*.csv),
write a report to: $REPORT, and a summary TSV to: $SUMMARY_TSV.

Options:
  --from-csv FILE     Use a specific hasher CSV (expects header: path,size_bytes,mtime_epoch,algo,hash)
  --min-size BYTES    Only include duplicate groups where per-file size >= BYTES (default: 0)
  --group-depth N     Grouping depth for summary (default: $GROUP_DEPTH)
  --top N             Show top N path groups in console (default: $TOP_N)
  -h, --help          Show this help

Examples:
  $0
  $0 --min-size 1048576            # only 1MB+ dup groups
  $0 --group-depth 3 --top 20      # deeper path summary
  $0 --from-csv hashes/hasher-$DATE_TAG.csv
EOF
}

# ───────── Args ─────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-csv)     FROM_CSV="${2:-}"; shift ;;
    --min-size)     MIN_SIZE="${2:-0}"; shift ;;
    --group-depth)  GROUP_DEPTH="${2:-2}"; shift ;;
    --top)          TOP_N="${2:-10}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo -e "${YELLOW}Unknown option: $1${NC}" >&2; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$HASHES_DIR" "$LOGS_DIR"

# Pick latest CSV if not provided
if [[ -z "$FROM_CSV" ]]; then
  if ! FROM_CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1)"; then
    log ERROR "No CSV found in $HASHES_DIR. Run hasher.sh first."
    exit 1
  fi
fi
[[ -r "$FROM_CSV" ]] || { log ERROR "Cannot read CSV: $FROM_CSV"; exit 1; }

log INFO "Using CSV: $FROM_CSV"
log INFO "Report will be written to: $REPORT"
log INFO "Summary TSV will be written to: $SUMMARY_TSV"
log INFO "Filters: min_size=${MIN_SIZE}B, group_depth=$GROUP_DEPTH"

# Truncate outputs up front
: > "$REPORT"
: > "$SUMMARY_TSV".tmp

# ───────── Build duplicate report ─────────
# POSIX-awk only. Robust CSV first-field parsing for quoted paths.
awk -v minsize="$MIN_SIZE" -v report="$REPORT" -v summarytmp="$SUMMARY_TSV.tmp" -v depth="$GROUP_DEPTH" '
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
  function unquote_csv(s){ gsub(/""/,"\"",s); return s }

  # Parse one CSV line from hasher: path,size_bytes,mtime_epoch,algo,hash
  function parse_line(line,   path, rest, c, endq, size_str, hash) {
    if (substr(line,1,1)=="\"") {
      endq=0
      for (i=2;i<=length(line);i++) {
        ch=substr(line,i,1)
        if (ch=="\"") {
          nxt=substr(line,i+1,1)
          if (nxt=="\"") { i++; continue } else { endq=i; break }
        }
      }
      if (endq==0) return 0
      path=substr(line,2,endq-2); path=unquote_csv(path)
      rest=substr(line,endq+2) # skip closing quote + comma
    } else {
      c=index(line,","); if (c==0) return 0
      path=substr(line,1,c-1); rest=substr(line,c+1)
    }
    # size
    c=index(rest,","); if (c==0) return 0
    size_str=substr(rest,1,c-1); size_str=ltrim(rtrim(size_str)); rest=substr(rest,c+1)
    # mtime (skip)
    c=index(rest,","); if (c==0) return 0
    rest=substr(rest,c+1)
    # algo (skip)
    c=index(rest,","); if (c==0) return 0
    hash=substr(rest,c+1); hash=ltrim(rtrim(hash))

    PATH=path; SIZE=size_str+0; HASH=hash
    return 1
  }

  function prefix(p, depth,   i,n,part,count,acc) {
    n = split(p, a, "/")
    acc=""; count=0
    for (i=1; i<=n; i++) {
      part=a[i]; if (part=="") continue
      count++
      if (count<=depth) acc=acc "/" part; else break
    }
    if (acc=="") acc="/"
    return acc
  }

  BEGIN{
    groups=0; dup_files=0; reclaim=0
    # make sure outputs start empty
    print "" > report; close(report)
    print "" > summarytmp; close(summarytmp)
  }

  NR==1 { next }  # skip header

  {
    if (!parse_line($0)) next
    if (!(HASH in count)) { count[HASH]=0; size_by_hash[HASH]=SIZE; files[HASH]="" }
    count[HASH]++
    files[HASH]=files[HASH] "\n" PATH
  }

  END{
    for (h in count) {
      c=count[h]; s=size_by_hash[h]+0
      if (c>1 && s>=minsize) {
        groups++
        dup_files += c
        reclaim += (c-1)*s
        printf("HASH %s (%d files):\n", h, c) >> report
        n=split(files[h], arr, "\n")
        for (i=1; i<=n; i++) {
          p=arr[i]; if (p=="") continue
          printf("  %s\n", p) >> report
          pre = prefix(p, depth)
          groupcount[pre]++
        }
        printf("\n") >> report
      }
    }
    # write summary tmp
    for (k in groupcount) printf("%s\t%d\n", k, groupcount[k]) >> summarytmp

    # emit totals for the shell to read if needed
    printf("DUP_GROUPS=%d\nDUP_FILES=%d\nRECLAIM=%d\n", groups, dup_files, reclaim) > "/dev/stderr"
  }
' "$FROM_CSV"

# Sort summary and show top-N
sort -k2,2nr "$SUMMARY_TSV".tmp -o "$SUMMARY_TSV" || true

# Compute total files across groups for percentages (sum of 2nd col)
total_in_groups=$(awk -F'\t' '{s+=$2} END{print s+0}' "$SUMMARY_TSV")

echo
echo -e "${GREEN}Duplicate analysis complete.${NC}"
echo "  • Report:           $REPORT"
echo "  • Summary TSV:      $SUMMARY_TSV"
echo "  • Total files in groups: $total_in_groups"
echo

if [[ -s "$SUMMARY_TSV" ]]; then
  echo "Top $TOP_N groups (depth=$GROUP_DEPTH):"
  rank=0
  while IFS=$'\t' read -r pref cnt; do
    ((rank++))
    pct=0
    if [[ "${total_in_groups:-0}" -gt 0 ]]; then
      pct=$(( (cnt * 100) / total_in_groups ))
    fi
    printf "  %2d) %-50s %6d files  (%3d%%)\n" "$rank" "$pref" "$cnt" "$pct"
    (( rank >= TOP_N )) && break || true
  done < "$SUMMARY_TSV"
fi

echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "  1) Review the duplicate report:"
echo "       less \"$REPORT\""
echo "  2) Preview actions & create a plan:"
echo "       ./review-duplicates.sh --from-report \"$REPORT\""
echo "  3) Safer dedupe (quarantine extras):"
echo "       ./deduplicate.sh --from-report \"$REPORT\" --keep newest --quarantine \"quarantine-$DATE_TAG\""
echo "  4) Or delete extras (dangerous):"
echo "       ./deduplicate.sh --from-report \"$REPORT\" --keep newest --force"
