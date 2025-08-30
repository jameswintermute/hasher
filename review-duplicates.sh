#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# review-duplicates.sh — Interactive review of duplicate groups (largest-first).
# Fast indexing: loads CSV once, parses the report once, writes per-group detail files.
# Safe: writes a plan only; never deletes.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────── Config ─────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="$(( (RANDOM<<16) ^ (RANDOM<<1) ^ $$ ))"

# Inputs (auto-picked if not provided)
REPORT="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"

# Review parameters
ORDER="size"          # size|reclaim   (largest-first)
LIMIT=100             # max groups to walk through interactively
MIN_SIZE=0            # ignore dup groups where per-file size < MIN_SIZE
FILTER_PREFIX=""      # if set, only consider groups that include any file under this prefix
GROUP_DEPTH=2         # summary path depth
TOP_N=10              # top-N summary after plan built

# Outputs
PLAN="$LOGS_DIR/review-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
SUMMARY_TSV="$LOGS_DIR/review-duplicates-summary-$DATE_TAG-$RUN_ID.tsv"
TMPROOT="$LOGS_DIR/review-groups-$DATE_TAG-$RUN_ID"
GROUPDIR="$TMPROOT/groups"
INDEX_RAW="$TMPROOT/groups-index-raw.tsv"
INDEX_SORTED="$TMPROOT/groups-sorted.tsv"

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

usage() {
cat <<EOF
Usage: $0 [--from-report FILE] [--from-csv FILE]
          [--order size|reclaim] [--limit N]
          [--min-size BYTES] [--filter-prefix PATH]
          [--group-depth N] [--top N]
          [-h|--help]
EOF
}

# ───────── Args ─────────
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

mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$GROUPDIR"
: > "$PLAN"
: > "$SUMMARY_TSV"

# ───────── Sanity ─────────
[[ -n "$REPORT" && -r "$REPORT" ]] || { echo "ERROR: No readable duplicate report (run find-duplicates.sh)"; exit 1; }
[[ -n "$CSV"    && -r "$CSV"    ]] || { echo "ERROR: No readable hasher CSV (run hasher.sh)"; exit 1; }

# ───────── Helpers ─────────
pp_size(){ b="$1"; u=(B KiB MiB GiB TiB PiB); i=0; while (( b>=1024 && i<${#u[@]}-1 )); do b=$(( (b+1023)/1024 )); i=$((i+1)); done; printf "%d %s" "$b" "${u[$i]}"; }
fmt_epoch(){ ts="$1"; date -d "@$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts"; }

echo -e "${GREEN}Indexing CSV and duplicate report…${NC}"
echo "  • CSV:     $CSV"
echo "  • Report:  $REPORT"
echo "  • Filters: min_size=${MIN_SIZE}B${FILTER_PREFIX:+, prefix=$FILTER_PREFIX}"
echo "  • Temp:    $TMPROOT"
echo

# ───────── One-pass index build (FAST) ─────────
# Loads CSV once (path -> size,mtime). Parses report once.
# Writes:
#   - $GROUPDIR/group-XXXXXX.detail  (lines: <size>\t<mtime>\t<path>)
#   - $INDEX_RAW (TSV: first_size  reclaim  count  detail_file)
awk -v csv="$CSV" -v report="$REPORT" -v outdir="$GROUPDIR" -v indexout="$INDEX_RAW" \
    -v minsize="$MIN_SIZE" -v wantprefix="$FILTER_PREFIX" '
  function ltrim(s){ sub(/^[ \t\r\n]+/,"",s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/,"",s); return s }
  function unquote_csv(s){ gsub(/""/,"\"",s); return s }

  function parse_csv_line(line,   path, rest, c, endq, size_str, mtime_str, hash) {
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
      path=substr(line,2,endq-2)
      path=unquote_csv(path)
      rest=substr(line,endq+2)
    } else {
      c=index(line,","); if (c==0) return 0
      path=substr(line,1,c-1)
      rest=substr(line,c+1)
    }
    c=index(rest,","); if (c==0) return 0
    size_str=substr(rest,1,c-1); size_str=ltrim(rtrim(size_str)); rest=substr(rest,c+1)
    c=index(rest,","); if (c==0) return 0
    mtime_str=substr(rest,1,c-1); mtime_str=ltrim(rtrim(mtime_str)); rest=substr(rest,c+1)
    # skip algo, keep hash (not needed here)
    PATH=path; SIZE=size_str+0; MTIME=mtime_str+0
    return 1
  }

  function flush_group(   detail, reclaim) {
    if (gcount<2) { gcount=0; return }
    if (first_size<minsize) { gcount=0; return }
    if (wantprefix!="") {
      if (hasprefix==0) { gcount=0; return }
    }
    detail = outdir "/group-" sprintf("%06d", gidx) ".detail"
    # write index line: first_size, reclaim, count, path_to_detail
    reclaim = first_size * (gcount - 1)
    printf("%d\t%d\t%d\t%s\n", first_size, reclaim, gcount, detail) >> indexout
    groups_emitted++
    gcount=0; first_size=0; hasprefix=0
  }

  BEGIN{
    FS=","; OFS="\t"
    # Load CSV
    total_csv=0
  }
  FILENAME==csv {
    if (NRcsv==0) { NRcsv++; next }     # skip header
    if (parse_csv_line($0)) { size[PATH]=SIZE; mtime[PATH]=MTIME; total_csv++ }
    if (total_csv % 20000 == 0) {
      printf("... CSV loaded: %d rows\n", total_csv) > "/dev/stderr"
    }
    NRcsv++
    next
  }
  FILENAME==report {
    if ($0 ~ /^HASH[ ]/) {
      # new group begin
      if (gidx>0) flush_group()
      gidx++
      gcount=0; first_size=0; hasprefix=0
      if (gidx % 500 == 0) {
        printf("... Report groups parsed: %d (files seen: %d)\n", gidx, files_seen) > "/dev/stderr"
      }
      next
    }
    if ($0 ~ /^[ ]{2}/) {
      f=$0; sub(/^[ ]+/, "", f)
      if (f=="") next
      s = (f in size ? size[f] : 0)
      t = (f in mtime ? mtime[f] : 0)
      detail = outdir "/group-" sprintf("%06d", gidx) ".detail"
      printf("%d\t%d\t%s\n", s, t, f) >> detail
      gcount++
      files_seen++
      if (gcount==1) first_size=s
      if (wantprefix!="" && index(f, wantprefix)==1) hasprefix=1
      next
    }
    next
  }
  END{
    if (gidx>0) flush_group()
    printf("Loaded CSV rows: %d\n", total_csv) > "/dev/stderr"
    printf("Parsed report groups: %d | Emitted indexed groups: %d | Files seen: %d\n", gidx, groups_emitted, files_seen) > "/dev/stderr"
  }
' "$CSV" "$REPORT"

# Immediate feedback from the index step gets printed above.
# Now sort index according to requested order.
if [[ ! -s "$INDEX_RAW" ]]; then
  echo "No duplicate groups match filters."
  exit 0
fi

case "$ORDER" in
  size)    sort -k1,1nr -k3,3nr "$INDEX_RAW" -o "$INDEX_SORTED" ;;
  reclaim) sort -k2,2nr -k1,1nr "$INDEX_RAW" -o "$INDEX_SORTED" ;;
  *) echo -e "${YELLOW}Unknown --order '$ORDER' (use size|reclaim).${NC}"; exit 2 ;;
esac

echo
echo -e "${GREEN}Index ready. Starting interactive review…${NC}"
echo "  • Ordering:     $ORDER (largest first)"
echo "  • Limit:        $LIMIT"
echo "  • Plan:         $PLAN"
echo

# ───────── Interactive review ─────────
reviewed=0
added_extras=0
shown=0

pp_line() {
  # args: size mtime path index width
  local s="$1" t="$2" p="$3" idx="$4"
  local when; when="$(fmt_epoch "$t")"
  printf "   %2d) %-19s  %s\n" "$idx" "$(pp_size "$s")" "$p"
  printf "       modified: %s\n" "$when"
}

while IFS=$'\t' read -r first_sz reclaim cnt detail; do
  ((shown++)); (( shown > LIMIT )) && break
  echo -e "${CYAN}[$shown/$LIMIT] Size: $(pp_size "$first_sz")  |  Files: $cnt  |  Potential reclaim: $(pp_size "$reclaim")${NC}"

  # Display group entries
  i=0
  while IFS=$'\t' read -r s t p; do
    ((i++))
    pp_line "$s" "$t" "$p" "$i"
  done < "$detail"

  echo
  read -r -p "Select the file ID to KEEP [1-$cnt], or 's' to skip, or 'q' to quit: " choice
  if [[ -z "${choice:-}" || "$choice" == "s" || "$choice" == "S" ]]; then echo "  → Skipped."; echo; continue; fi
  if [[ "$choice" == "q" || "$choice" == "Q" ]]; then echo "  → Quitting early."; break; fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > cnt )); then echo -e "${YELLOW}Invalid choice. Skipping.${NC}"; echo; continue; fi

  keep_idx="$choice"
  added_here=0
  j=0
  # Re-read detail to write all extras (not the chosen keep)
  while IFS=$'\t' read -r s t p; do
    ((j++))
    if (( j == keep_idx )); then continue; fi
    printf '%s\n' "$p" >> "$PLAN"
    ((added_here++))
  done < "$detail"

  ((added_extras+=added_here))
  echo "  → Keeping #$keep_idx; added $added_here extras to plan."
  echo
done < "$INDEX_SORTED"

# ───────── Summary of the plan ─────────
if [[ -s "$PLAN" ]]; then
  awk -v depth="$GROUP_DEPTH" '
    function pref(p, depth,   i,n,part,count,acc){
      n = split(p, a, "/"); acc=""; count=0
      for (i=1;i<=n;i++){ part=a[i]; if (part=="") continue; count++; if (count<=depth) acc=acc "/" part; else break }
      if (acc=="") acc="/"; return acc
    }
    { g[pref($0, depth)]++ }
    END{ for(k in g) printf("%s\t%d\n", k, g[k]) }
  ' "$PLAN" | sort -k2,2nr > "$SUMMARY_TSV"

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
echo "  • Plan entries (extras): ${added_extras:-0}"
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
