#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# review-duplicates.sh — Interactive review of duplicate groups.
# Sorts groups by size (largest-first) to maximise reclaim first.
# Lets you pick WHICH file to KEEP per group (by number) or skip the group.
#
# Inputs:
#   • Duplicate report: logs/YYYY-MM-DD-duplicate-hashes.txt  (from find-duplicates.sh)
#   • Hasher CSV:       hashes/hasher-*.csv                   (for size/mtime lookup; stat fallback)
#
# Output:
#   • Plan file (extras only): logs/review-dedupe-plan-<DATE>-<RUN>.txt
#   • Summary TSV by path:     logs/review-duplicates-summary-<DATE>-<RUN>.tsv
#
# Safe: This script NEVER deletes/moves files. It only writes a plan.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────── Config / defaults ─────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="$(
  (command -v uuidgen >/dev/null 2>&1 && uuidgen) \
  || cat /proc/sys/kernel/random/uuid 2>/dev/null \
  || echo "$(date +%s)-$$"
)"

REPORT=""                 # --from-report
CSV=""                    # --from-csv
ORDER="size"              # --order size|reclaim   (default size = per-file size, desc)
LIMIT=100                 # --limit N              (how many groups to interactively review)
MIN_SIZE=0                # --min-size BYTES       (skip groups with per-file size < MIN_SIZE)
FILTER_PREFIX=""          # --filter-prefix PATH   (only consider groups that include this prefix)
GROUP_DEPTH=2             # --group-depth N        (for summary)
TOP_N=10                  # --top N                (console top summary at the end)

PLAN="$LOGS_DIR/review-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
SUMMARY_TSV="$LOGS_DIR/review-duplicates-summary-$DATE_TAG-$RUN_ID.tsv"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

usage() {
cat <<EOF
Usage: $0 [--from-report FILE] [--from-csv FILE]
          [--order size|reclaim] [--limit N]
          [--min-size BYTES] [--filter-prefix PATH]
          [--group-depth N] [--top N]
          [-h|--help]

Behavior:
  • Sorts duplicate groups by SIZE (largest-first) by default.
  • Interactively shows each group and lets you select which file to KEEP (by number),
    or 's' to skip the group, or 'q' to quit early. Only EXTRAS go into the plan.
  • Writes:
      - Plan of extras:  $PLAN
      - Summary by path: $SUMMARY_TSV

Examples:
  $0                                  # review top 100 largest groups
  $0 --limit 50 --min-size 1048576    # top 50 groups of size >= 1 MiB
  $0 --filter-prefix /volume1/James   # review only groups containing paths under that prefix
  $0 --order reclaim                  # sort by (size * (count-1)) descending
EOF
}

# ───────── Arg parsing ─────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-report)   REPORT="${2:-}"; shift ;;
    --from-csv)      CSV="${2:-}"; shift ;;
    --order)         ORDER="${2:-size}"; shift ;;
    --limit)         LIMIT="${2:-100}"; shift ;;
    --min-size)      MIN_SIZE="${2:-0}"; shift ;;
    --filter-prefix) FILTER_PREFIX="${2:-}"; shift ;;
    --group-depth)   GROUP_DEPTH="${2:-2}"; shift ;;
    --top)           TOP_N="${2:-10}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo -e "${YELLOW}Unknown option: $1${NC}"; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$HASHES_DIR" "$LOGS_DIR"

# Auto-pick inputs
if [[ -z "$REPORT" ]]; then
  REPORT="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$REPORT" || ! -r "$REPORT" ]]; then
  echo "ERROR: No readable duplicate report found. Run find-duplicates.sh first." >&2
  exit 1
fi

if [[ -z "$CSV" ]]; then
  CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$CSV" || ! -r "$CSV" ]]; then
  echo "ERROR: No readable hasher CSV found. Run hasher.sh first." >&2
  exit 1
fi

# ───────── Helpers ─────────
pp_size() {  # pretty print bytes
  local b="$1"
  local u=(B KiB MiB GiB TiB PiB)
  local i=0
  while (( b >= 1024 && i < ${#u[@]}-1 )); do b=$(( (b + 1023) / 1024 )); i=$((i+1)); done
  printf "%d %s" "$b" "${u[$i]}"
}

fmt_epoch() {  # epoch -> "YYYY-MM-DD HH:MM:SS" (fallback to epoch)
  local ts="$1" out=""
  if out="$(date -d "@$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"; then
    printf "%s" "$out"
  elif out="$(date -r "$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"; then
    printf "%s" "$out"
  else
    printf "%s" "$ts"
  fi
}

path_meta() {  # prints "size<TAB>mtime" for a path using CSV map (fallback: stat)
  local p="$1"
  local line
  # robust CSV parse for first field (path)
  line="$(awk -v want="$p" -F',' '
    function uq(s){ gsub(/""/,"\"",s); return s }
    function get(line,  path,rest,c,endq,size,mtime,algo,hash){
      if (substr(line,1,1)=="\"") {
        endq=0
        for (i=2;i<=length(line);i++) {
          ch=substr(line,i,1)
          if (ch=="\"") { nxt=substr(line,i+1,1); if(nxt=="\"") {i++} else {endq=i; break} }
        }
        if (endq==0) return 0
        path=substr(line,2,endq-2); path=uq(path); rest=substr(line,endq+2)
      } else {
        c=index(line,","); if (c==0) return 0
        path=substr(line,1,c-1); rest=substr(line,c+1)
      }
      c=index(rest,","); if (c==0) return 0
      size_str=substr(rest,1,c-1); rest=substr(rest,c+1)
      c=index(rest,","); if (c==0) return 0
      mtime_str=substr(rest,1,c-1); rest=substr(rest,c+1)
      c=index(rest,","); if (c==0) return 0
      # algo
      hash=substr(rest,c+1)
      if (path==want) { print size_str "\t" mtime_str; exit 0 }
      return 1
    }
    NR==1 { next }
    { get($0) }
  ' "$CSV" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    printf "%s\n" "$line"
    return 0
  fi
  # fallback to stat if not found
  local sz mt
  sz="$(stat -c%s -- "$p" 2>/dev/null || echo 0)"
  mt="$(stat -c%Y -- "$p" 2>/dev/null || echo 0)"
  printf "%s\t%s\n" "$sz" "$mt"
}

# ───────── Build per-group files, then index them ─────────
TMPROOT="$LOGS_DIR/review-groups-$DATE_TAG-$RUN_ID"
GROUPDIR="$TMPROOT/groups"
mkdir -p "$GROUPDIR"

# Split report into group files (group-000001.lst ...)
awk -v outdir="$GROUPDIR" '
  /^HASH[ ]/ { idx++; next }
  /^[ ]{2}/ { sub(/^[ ]+/, "", $0); print > (outdir "/group-" sprintf("%06d", idx) ".lst") }
' "$REPORT"

# Build index: <size>\t<reclaim>\t<count>\t<groupfile>
INDEX="$TMPROOT/groups-index.tsv"
: > "$INDEX"
total_groups=0
shopt -s nullglob
for gf in "$GROUPDIR"/group-*.lst; do
  c=$(wc -l < "$gf" | tr -d ' '); (( c < 2 )) && continue
  first="$(head -n1 -- "$gf")"
  # size from CSV or stat:
  sz="$(path_meta "$first" | awk -F'\t' '{print $1+0}')"
  # filter by MIN_SIZE & prefix requirement
  if (( sz < MIN_SIZE )); then continue; fi
  if [[ -n "$FILTER_PREFIX" ]]; then
    if ! grep -qF -- "$FILTER_PREFIX" "$gf"; then
      continue
    fi
  fi
  reclaim=$(( sz * (c - 1) ))
  printf '%s\t%s\t%s\t%s\n' "$sz" "$reclaim" "$c" "$gf" >> "$INDEX"
  ((total_groups++))
done
shopt -u nullglob

if (( total_groups == 0 )); then
  echo "No duplicate groups match the filters (min_size=$MIN_SIZE, prefix='${FILTER_PREFIX}')." >&2
  exit 0
fi

# Sort index by requested order
SORTED="$TMPROOT/groups-sorted.tsv"
case "$ORDER" in
  size)    sort -k1,1nr -k3,3nr "$INDEX" -o "$SORTED" ;;
  reclaim) sort -k2,2nr -k1,1nr "$INDEX" -o "$SORTED" ;;
  *) echo "Unknown --order '$ORDER' (use size|reclaim)"; exit 2 ;;
esac

: > "$PLAN"        # truncate outputs
: > "$SUMMARY_TSV"

echo -e "${GREEN}Interactive review starting…${NC}"
echo "  • Ordering:     $ORDER (largest first)"
echo "  • Limit:        $LIMIT groups (of $total_groups candidates)"
echo "  • Filters:      min_size=${MIN_SIZE}B${FILTER_PREFIX:+, prefix=$FILTER_PREFIX}"
echo "  • Plan:         $PLAN"
echo "  • Summary TSV:  $SUMMARY_TSV"
echo

# ───────── Interactive loop ─────────
reviewed=0
added_extras=0
shown=0

while IFS=$'\t' read -r sz reclaim cnt gf; do
  ((shown++))
  ((shown > LIMIT)) && break

  # Read file list for this group into array
  mapfile -t files < "$gf" || files=()

  # Print header for this group
  echo -e "${CYAN}[$shown/$LIMIT] Size: $(pp_size "$sz")  |  Files: $cnt  |  Potential reclaim: $(pp_size "$reclaim")${NC}"
  # Show each candidate with index, mtime, path
  i=0
  for p in "${files[@]}"; do
    ((i++))
    meta="$(path_meta "$p")"
    fsz="${meta%%$'\t'*}"; fmtime="${meta#*$'\t'}"
    when="$(fmt_epoch "$fmtime")"
    printf "   %2d) %-19s  %s\n" "$i" "$(pp_size "$fsz")" "$p"
    printf "       modified: %s\n" "$when"
  done

  # Prompt
  echo
  read -r -p "Select the file ID to KEEP [1-$cnt], or 's' to skip, or 'q' to quit: " choice

  # Handle input
  if [[ -z "${choice:-}" || "$choice" == "s" || "$choice" == "S" ]]; then
    echo "  → Skipped."
    echo
    continue
  fi
  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    echo "  → Quitting early at your request."
    break
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > cnt )); then
    echo -e "${YELLOW}Invalid choice. Skipping this group.${NC}"
    echo
    continue
  fi

  keep_idx="$choice"
  keep_path="${files[$((keep_idx-1))]}"

  # Add extras (= all others) to plan
  added_here=0
  for j in "${!files[@]}"; do
    (( jj=j+1 ))
    [[ "$jj" -eq "$keep_idx" ]] && continue
    printf '%s\n' "${files[$j]}" >> "$PLAN"
    ((added_here++))
  done
  ((added_extras+=added_here))
  echo "  → Keeping #$keep_idx; added $added_here extras to plan."
  echo

  ((reviewed++))
done < "$SORTED"

# ───────── Summarise plan by path prefix ─────────
if [[ -s "$PLAN" ]]; then
  awk -v depth="$GROUP_DEPTH" -F'\t' '
    function pref(p, depth,   i,n,part,count,acc){
      n = split(p, a, "/"); acc=""; count=0
      for (i=1;i<=n;i++){ part=a[i]; if (part=="") continue; count++; if (count<=depth) acc=acc "/" part; else break }
      if (acc=="") acc="/"; return acc
    }
    { g[pref($0, depth)]++ }
    END{ for(k in g) printf("%s\t%d\n", k, g[k]) }
  ' "$PLAN" | sort -k2,2nr > "$SUMMARY_TSV"
fi

# Show top-N summary
if [[ -s "$SUMMARY_TSV" ]]; then
  total_extras=$(awk -F'\t' '{s+=$2} END{print s+0}' "$SUMMARY_TSV")
  echo "Top $TOP_N groups (depth=$GROUP_DEPTH):"
  rank=0
  while IFS=$'\t' read -r pref cnt; do
    ((rank++))
    pct=0
    if [[ "${total_extras:-0}" -gt 0 ]]; then
      pct=$(( (cnt * 100) / total_extras ))
    fi
    printf "  %2d) %-50s %6d extras  (%3d%%)\n" "$rank" "$pref" "$cnt" "$pct"
    (( rank >= TOP_N )) && break || true
  done < "$SUMMARY_TSV"
fi

echo
echo -e "${GREEN}Interactive review complete.${NC}"
echo "  • Groups reviewed:     $shown (limit=$LIMIT)"
echo "  • Plan entries (extras): $added_extras"
echo "  • Plan file:             $PLAN"
echo "  • Summary TSV:           $SUMMARY_TSV"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "  1) Review the plan:"
echo "       less \"$PLAN\""
echo "  2) Safer action — move extras to quarantine (preserve tree):"
echo "       QDIR=\"quarantine-$DATE_TAG\""
echo "       while IFS= read -r p; do mkdir -p \"\$QDIR\$(dirname \"\$p\")\"; mv -n -- \"\$p\" \"\$QDIR\$p\"; done < \"$PLAN\""
echo "  3) Or delete extras (dangerous):"
echo "       xargs -d '\n' -a \"$PLAN\" rm -f --"
echo
echo "Tip: Re-run with --limit 200 (or more) to review more groups, or --order reclaim to sort by space reclaimed."
