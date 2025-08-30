#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# review-duplicates.sh — Interactive review of duplicate groups (largest-first).
# Fast indexing (single CSV + report pass). Prompts with standard `read -rp`.
# Adds mirrored-folder detection and per-group folder summaries.

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
FILTER_PREFIX=""      # only consider groups including any file under this prefix (optional)
GROUP_DEPTH=2         # summary path depth
TOP_N=10              # top-N summary after plan built
SHOW_EACH_MAX=12      # show up to this many files per group in the UI
FOLDER_DEPTH=3        # depth for folder summaries / mirror detection (/vol/Share/Sub=3)

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
          [--group-depth N] [--top N] [--folder-depth N]
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
    --folder-depth)  FOLDER_DEPTH="${2:-3}"; shift ;;
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

TOTAL_GROUPS=$(grep -c '^HASH ' "$REPORT" 2>/dev/null || echo 0)

# ───────── Helpers ─────────
pp_size(){ b="$1"; u=(B KiB MiB GiB TiB PiB); i=0; while (( b>=1024 && i<${#u[@]}-1 )); do b=$(( (b+1023)/1024 )); i=$((i+1)); done; printf "%d %s" "$b" "${u[$i]}"; }
fmt_epoch(){ ts="$1"; date -d "@$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts"; }
folder_counts(){ # reads paths on stdin, prints "COUNT\tPREFIX" sorted by COUNT desc
  awk -v d="$FOLDER_DEPTH" -F'/' '
    function pref(a, n, d,   i,c,s){ s=""; c=0; for(i=1;i<=n;i++){ if(a[i]=="")continue; c++; if(c<=d){ s=s "/" a[i] } } if(s=="") s="/"; return s }
    { n=split($0,a,"/"); p=pref(a,n,d); g[p]++ } END{ for(k in g) printf("%d\t%s\n", g[k], k) }
  ' | sort -k1,1nr
}

echo -e "${GREEN}Indexing CSV and duplicate report…${NC}"
echo "  • CSV:     $CSV"
echo "  • Report:  $REPORT"
echo "  • Filters: min_size=${MIN_SIZE}B${FILTER_PREFIX:+, prefix=$FILTER_PREFIX}"
echo "  • Temp:    $TMPROOT"
echo

# ───────── One-pass index build (FAST) ─────────
awk -v csv="$CSV" -v report="$REPORT" -v outdir="$GROUPDIR" -v indexout="$INDEX_RAW" \
    -v minsize="$MIN_SIZE" -v wantprefix="$FILTER_PREFIX" -v total="$TOTAL_GROUPS" '
  function ltrim(s){ sub(/^[ \t\r\n]+/,"",s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/,"",s); return s }
  function unquote_csv(s){ gsub(/""/,"\"",s); return s }
  function hhmmss(sec,  h,m,s){ if (sec<0) sec=0; h=int(sec/3600); m=int((sec%3600)/60); s=int(sec%60); return sprintf("%02d:%02d:%02d",h,m,s) }

  function parse_csv_line(line,   path, rest, c, endq, size_str, mtime_str) {
    if (substr(line,1,1)=="\"") {
      endq=0
      for (i=2;i<=length(line);i++) {
        ch=substr(line,i,1)
        if (ch=="\"") { nxt=substr(line,i+1,1); if (nxt=="\"") { i++; continue } else { endq=i; break } }
      }
      if (endq==0) return 0
      path=substr(line,2,endq-2); path=unquote_csv(path)
      rest=substr(line,endq+2)
    } else {
      c=index(line,","); if (c==0) return 0
      path=substr(line,1,c-1); rest=substr(line,c+1)
    }
    c=index(rest,","); if (c==0) return 0
    size_str=substr(rest,1,c-1); size_str=ltrim(rtrim(size_str)); rest=substr(rest,c+1)
    c=index(rest,","); if (c==0) return 0
    mtime_str=substr(rest,1,c-1); mtime_str=ltrim(rtrim(mtime_str)); rest=substr(rest,c+1)
    PATH=path; SIZE=size_str+0; MTIME=mtime_str+0
    return 1
  }

  function flush_group(   detail, reclaim) {
    if (gcount<2) { gcount=0; return }
    if (first_size<minsize) { gcount=0; return }
    if (wantprefix!="" && hasprefix==0) { gcount=0; return }
    detail = outdir "/group-" sprintf("%06d", gidx) ".detail"
    reclaim = first_size * (gcount - 1)
    printf("%d\t%d\t%d\t%s\n", first_size, reclaim, gcount, detail) >> indexout
    groups_emitted++
    gcount=0; first_size=0; hasprefix=0
  }

  BEGIN{ FS=","; OFS="\t"; total_csv=0; t0=systime() }

  FILENAME==csv {
    if (NRcsv==0) { NRcsv++; next }
    if (parse_csv_line($0)) { size[PATH]=SIZE; mtime[PATH]=MTIME; total_csv++ }
    if (total_csv % 20000 == 0) { printf("... CSV loaded: %d rows\n", total_csv) > "/dev/stderr"; fflush("/dev/stderr") }
    NRcsv++; next
  }

  FILENAME==report {
    if ($0 ~ /^HASH[ ]/) {
      if (gidx>0) flush_group()
      gidx++; gcount=0; first_size=0; hasprefix=0
      if (gidx % 500 == 0) {
        elapsed = systime()-t0
        pct = (total>0 ? int(gidx*100/total) : 0)
        rate = (elapsed>0 ? gidx/elapsed : 0)
        eta = (rate>0 && total>0 ? int((total-gidx)/rate) : 0)
        printf("... Report groups parsed: %d/%d (%d%%) (files seen: %d) | elapsed=%s eta=%s\n",
               gidx, total, pct, files_seen, hhmmss(elapsed), hhmmss(eta)) > "/dev/stderr"; fflush("/dev/stderr")
      }
      next
    }
    if ($0 ~ /^[ ]{2}/) {
      f=$0; sub(/^[ ]+/, "", f); if (f=="") next
      s = (f in size ? size[f] : 0)
      t = (f in mtime ? mtime[f] : 0)
      detail = outdir "/group-" sprintf("%06d", gidx) ".detail"
      printf("%d\t%d\t%s\n", s, t, f) >> detail
      gcount++; files_seen++; if (gcount==1) first_size=s
      if (wantprefix!="" && index(f, wantprefix)==1) hasprefix=1
      next
    }
    next
  }

  END{
    if (gidx>0) flush_group()
    printf("Loaded CSV rows: %d\n", total_csv) > "/dev/stderr"; fflush("/dev/stderr")
    printf("Parsed report groups: %d/%d | Emitted indexed groups: %d | Files seen: %d\n",
           gidx, total, groups_emitted, files_seen) > "/dev/stderr"; fflush("/dev/stderr")
  }
' "$CSV" "$REPORT"

# Sort index by requested order
if [[ ! -s "$INDEX_RAW" ]]; then
  echo "No duplicate groups match filters."
  exit 0
fi
case "$ORDER" in
  size)    sort -k1,1nr -k3,3nr "$INDEX_RAW" -o "$INDEX_SORTED" ;;
  reclaim) sort -k2,2nr -k1,1nr "$INDEX_RAW" -o "$INDEX_SORTED" ;;
  *) echo -e "${YELLOW}Unknown --order '$ORDER' (use size|reclaim).${NC}"; exit 2 ;;
esac

INDEX_COUNT=$(wc -l < "$INDEX_SORTED" | tr -d ' ' || echo 0)

echo
echo -e "${GREEN}Index ready. Starting interactive review…${NC}"
echo "  • Ordering:     $ORDER (largest first)"
echo "  • Limit:        $LIMIT"
echo "  • Groups:       $INDEX_COUNT total"
echo "  • Plan:         $PLAN"
echo

# Require a real TTY on stdin for prompts
if [[ ! -t 0 ]]; then
  echo -e "${YELLOW}No interactive TTY on stdin; run from an interactive terminal to make selections.${NC}"
  exit 1
fi

pp_line() { # args: size mtime path idx
  local s="$1" t="$2" p="$3" idx="$4"
  local when; when="$(fmt_epoch "$t")"
  printf "   %2d) %-19s  %s\n" "$idx" "$(pp_size "$s")" "$p"
  printf "       modified: %s\n" "$when"
}

# Read the whole index into memory; fallback if `mapfile` missing
INDEX_LINES=()
if command -v mapfile >/dev/null 2>&1; then
  mapfile -t INDEX_LINES < "$INDEX_SORTED"
else
  while IFS= read -r _ln; do INDEX_LINES+=("$_ln"); done < "$INDEX_SORTED"
fi

shown=0
added_extras=0

for line in "${INDEX_LINES[@]}"; do
  (( shown >= LIMIT )) && break
  IFS=$'\t' read -r first_sz reclaim cnt detail <<< "$line" || continue

  ((shown++))
  echo -e "${CYAN}[$shown/$LIMIT] Size: $(pp_size "$first_sz")  |  Files: $cnt  |  Potential reclaim: $(pp_size "$reclaim")${NC}"

  # Load this group's items into arrays (so we can display + compute folder stats)
  GROUP_LINES=()
  if command -v mapfile >/dev/null 2>&1; then
    mapfile -t GROUP_LINES < "$detail"
  else
    while IFS= read -r gl; do GROUP_LINES+=("$gl"); done < "$detail"
  fi

  paths=(); sizes=(); mtimes=()
  for gl in "${GROUP_LINES[@]}"; do
    IFS=$'\t' read -r s t p <<< "$gl"
    sizes+=("$s"); mtimes+=("$t"); paths+=("$p")
  done

  # Display up to SHOW_EACH_MAX items
  total_in_group=${#paths[@]}
  to_show=$(( total_in_group < SHOW_EACH_MAX ? total_in_group : SHOW_EACH_MAX ))
  for ((i=0;i<to_show;i++)); do
    pp_line "${sizes[$i]}" "${mtimes[$i]}" "${paths[$i]}" "$((i+1))"
  done
  hidden=$(( total_in_group - to_show ))
  (( hidden > 0 )) && echo "       … and $hidden more not shown"

  # Folder summary & mirror detection
  {
    for p in "${paths[@]}"; do echo "$p"; done | folder_counts
  } > "$TMPROOT/group-$shown-folders.tsv"

  echo "       Top folders (depth=$FOLDER_DEPTH):"
  head -n 3 "$TMPROOT/group-$shown-folders.tsv" | awk -f - <<'AWK'
    BEGIN{FS="\t"} {printf "         - %s  (%s files)\n", $2, $1}
AWK

  mirror_hint=""
  if (( $(wc -l < "$TMPROOT/group-$shown-folders.tsv" | tr -d ' ') == 2 )); then
    a_count=$(awk 'NR==1{print $1}' "$TMPROOT/group-$shown-folders.tsv")
    b_count=$(awk 'NR==2{print $1}' "$TMPROOT/group-$shown-folders.tsv")
    a_pref=$(awk -F'\t' 'NR==1{print $2}' "$TMPROOT/group-$shown-folders.tsv")
    b_pref=$(awk -F'\t' 'NR==2{print $2}' "$TMPROOT/group-$shown-folders.tsv")
    if (( a_count == b_count && a_count + b_count == total_in_group )); then
      mirror_hint="mirror"
      echo "       Mirror folders suspected:"
      echo "         [A] $a_pref  ($a_count files)"
      echo "         [B] $b_pref  ($b_count files)"
      echo "       Tip: type 'ka' to keep A (drop B-side), or 'kb' to keep B (drop A-side)."
    fi
  fi

  echo
  read -rp "Select the file ID to KEEP [1-$total_in_group], ${mirror_hint:+or 'ka'/'kb', }'s' to skip, 'q' to quit: " choice || choice=""

  # Handle choice
  if [[ -z "${choice:-}" || "$choice" =~ ^[sS]$ ]]; then
    echo "  → Skipped."; echo; continue
  fi
  if [[ "$choice" =~ ^[qQ]$ ]]; then
    echo "  → Quitting early."; break
  fi

  added_here=0
  if [[ "$choice" == "ka" || "$choice" == "kb" ]]; then
    if [[ -f "$TMPROOT/group-$shown-folders.tsv" ]]; then
      keep_pref=$(awk -F'\t' -v c="$choice" 'c=="ka"&&NR==1{print $2} c=="kb"&&NR==2{print $2}' "$TMPROOT/group-$shown-folders.tsv")
      if [[ -n "$keep_pref" ]]; then
        for p in "${paths[@]}"; do
          if [[ "${p:0:${#keep_pref}}" != "$keep_pref" ]]; then
            printf '%s\n' "$p" >> "$PLAN"
            ((added_here++))
          fi
        done
        ((added_extras+=added_here))
        echo "  → Keeping folder '${keep_pref}'; added $added_here extras to plan."
      else
        echo -e "${YELLOW}  ! Could not resolve folder choice; skipping.${NC}"
      fi
    else
      echo -e "${YELLOW}  ! No folder summary; skipping.${NC}"
    fi
    echo
    continue
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > total_in_group )); then
    echo -e "${YELLOW}Invalid choice. Skipping.${NC}"; echo; continue
  fi

  keep_idx="$choice"
  for ((j=0;j<total_in_group;j++)); do
    (( j+1 == keep_idx )) && continue
    printf '%s\n' "${paths[$j]}" >> "$PLAN"
    ((added_here++))
  done
  ((added_extras+=added_here))
  echo "  → Keeping #$keep_idx; added $added_here extras to plan."
  echo
done

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
echo "  2) Move extras to quarantine (safe):"
echo "       while IFS= read -r p; do mkdir -p \"quarantine-$DATE_TAG\$(dirname \"\$p\")\"; mv -n -- \"\$p\" \"quarantine-$DATE_TAG\$p\"; done < \"$PLAN\""
echo "  3) Or delete extras (dangerous):"
echo "       xargs -0 rm -f -- < <(tr '\\n' '\\0' < \"$PLAN\")"
