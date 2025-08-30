#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# review-duplicates.sh — Interactive review of duplicate groups (largest-first).
# Safe: writes a plan only; never deletes.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="$(( (RANDOM<<16) ^ (RANDOM<<1) ^ $$ ))"

REPORT="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
ORDER="size"
LIMIT=100
MIN_SIZE=0
FILTER_PREFIX=""
GROUP_DEPTH=2
TOP_N=10

PLAN="$LOGS_DIR/review-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
SUMMARY_TSV="$LOGS_DIR/review-duplicates-summary-$DATE_TAG-$RUN_ID.tsv"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

usage() {
cat <<EOF
Usage: $0 [--from-report FILE] [--from-csv FILE]
          [--order size|reclaim] [--limit N]
          [--min-size BYTES] [--filter-prefix PATH]
          [--group-depth N] [--top N]
EOF
}

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

[[ -n "$REPORT" && -r "$REPORT" ]] || { echo "ERROR: No readable duplicate report (run find-duplicates.sh)"; exit 1; }
[[ -n "$CSV" && -r "$CSV" ]]       || { echo "ERROR: No readable hasher CSV (run hasher.sh)"; exit 1; }

pp_size(){ b="$1"; u=(B KiB MiB GiB TiB); i=0; while (( b>=1024 && i<${#u[@]}-1 )); do b=$(( (b+1023)/1024 )); i=$((i+1)); done; printf "%d %s" "$b" "${u[$i]}"; }
fmt_epoch(){ ts="$1"; date -d "@$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts"; }

path_meta(){
  p="$1"
  awk -v want="$p" -F',' '
    function uq(s){ gsub(/""/,"\"",s); return s }
    function get(line,  path,rest,c,endq,size,mtime,hash){
      if (substr(line,1,1)=="\"") {
        endq=0
        for (i=2;i<=length(line);i++) { ch=substr(line,i,1); if (ch=="\"") { nxt=substr(line,i+1,1); if(nxt=="\""){i++} else {endq=i; break} } }
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
      if (path==want) { print size_str "\t" mtime_str; exit 0 }
      return 1
    }
    NR==1 { next } { get($0) }
  ' "$CSV" 2>/dev/null || true
}

TMPROOT="$LOGS_DIR/review-groups-$DATE_TAG-$RUN_ID"
GROUPDIR="$TMPROOT/groups"
mkdir -p "$GROUPDIR"

awk -v outdir="$GROUPDIR" '
  /^HASH[ ]/ { idx++; next }
  /^[ ]{2}/ { sub(/^[ ]+/, "", $0); print > (outdir "/group-" sprintf("%06d", idx) ".lst") }
' "$REPORT"

INDEX="$TMPROOT/groups-index.tsv"
: > "$INDEX"
shopt -s nullglob
for gf in "$GROUPDIR"/group-*.lst; do
  c=$(wc -l < "$gf" | tr -d ' '); (( c < 2 )) && continue
  first="$(head -n1 -- "$gf")"
  meta="$(path_meta "$first")"
  sz="${meta%%$'\t'*}"; [[ -z "$sz" ]] && sz=0
  (( sz < MIN_SIZE )) && continue
  if [[ -n "$FILTER_PREFIX" ]] && ! grep -qF -- "$FILTER_PREFIX" "$gf"; then continue; fi
  reclaim=$(( sz * (c - 1) ))
  printf '%s\t%s\t%s\t%s\n' "$sz" "$reclaim" "$c" "$gf" >> "$INDEX"
done
shopt -u nullglob

[[ -s "$INDEX" ]] || { echo "No duplicate groups match filters."; exit 0; }

SORTED="$TMPROOT/groups-sorted.tsv"
case "$ORDER" in
  size)    sort -k1,1nr -k3,3nr "$INDEX" -o "$SORTED" ;;
  reclaim) sort -k2,2nr -k1,1nr "$INDEX" -o "$SORTED" ;;
  *) echo "Unknown --order '$ORDER'"; exit 2 ;;
esac

: > "$PLAN"
: > "$SUMMARY_TSV"

echo -e "${GREEN}Interactive review starting…${NC}"
echo "  • Ordering:     $ORDER (largest first)"
echo "  • Limit:        $LIMIT"
echo "  • Plan:         $PLAN"
echo "  • Summary TSV:  $SUMMARY_TSV"
echo

reviewed=0
added_extras=0
shown=0

while IFS=$'\t' read -r sz reclaim cnt gf; do
  ((shown++)); (( shown > LIMIT )) && break
  mapfile -t files < "$gf" || files=()
  echo -e "${CYAN}[$shown/$LIMIT] Size: $(pp_size "$sz")  |  Files: $cnt  |  Potential reclaim: $(pp_size "$reclaim")${NC}"
  i=0
  for p in "${files[@]}"; do
    ((i++))
    meta="$(path_meta "$p")"
    fsz="${meta%%$'\t'*}"; fmtime="${meta#*$'\t'}"
    when="$(fmt_epoch "$fmtime")"
    printf "   %2d) %-19s  %s\n" "$i" "$(pp_size "$fsz")" "$p"
    printf "       modified: %s\n" "$when"
  done
  echo
  read -r -p "Select the file ID to KEEP [1-$cnt], or 's' to skip, or 'q' to quit: " choice
  if [[ -z "${choice:-}" || "$choice" == "s" || "$choice" == "S" ]]; then echo "  → Skipped."; echo; continue; fi
  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then echo "  → Quitting early."; break; fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > cnt )); then echo -e "${YELLOW}Invalid choice. Skipping.${NC}"; echo; continue; fi
  keep_idx="$choice"; keep_path="${files[$((keep_idx-1))]}"
  added_here=0
  for j in "${!files[@]}"; do (( jj=j+1 )); [[ "$jj" -eq "$keep_idx" ]] && continue; printf '%s\n' "${files[$j]}" >> "$PLAN"; ((added_here++)); done
  ((added_extras+=added_here))
  echo "  → Keeping #$keep_idx; added $added_here extras to plan."
  echo
done < "$SORTED"

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

if [[ -s "$SUMMARY_TSV" ]]; then
  total_extras=$(awk -F'\t' '{s+=$2} END{print s+0}' "$SUMMARY_TSV")
  echo "Top $TOP_N groups (depth=$GROUP_DEPTH):"
  rank=0
  while IFS=$'\t' read -r pref cnt; do
    ((rank++))
    pct=0
    if [[ "${total_extras:-0}" -gt 0 ]]; then pct=$(( (cnt * 100) / total_extras )); fi
    printf "  %2d) %-50s %6d extras  (%3d%%)\n" "$rank" "$pref" "$cnt" "$pct"
    (( rank >= TOP_N )) && break || true
  done < "$SUMMARY_TSV"
fi

echo
echo -e "${GREEN}Interactive review complete.${NC}"
echo "  • Groups reviewed:       $shown (limit=$LIMIT)"
echo "  • Plan entries (extras): $added_extras"
echo "  • Plan file:             $PLAN"
echo "  • Summary TSV:           $SUMMARY_TSV"
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "  1) Review the plan:"
echo "       less \"$PLAN\""
echo "  2) Safer action — move extras to quarantine (preserve tree):"
echo "       ./delete-duplicates.sh --from-plan \"$PLAN\" --force --quarantine \"quarantine-$DATE_TAG\""
echo "  3) Or delete extras (dangerous):"
echo "       ./delete-duplicates.sh --from-plan \"$PLAN\" --force"
