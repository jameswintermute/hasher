#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# review-duplicates.sh — Preview dedup actions from a duplicate report
# Dry-run only: computes what would be removed/moved for a chosen keep policy.
# Requires: a duplicate report (logs/YYYY-MM-DD-duplicate-hashes.txt) and a hasher CSV.

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

REPORT=""              # --from-report
CSV=""                 # --from-csv
KEEP="newest"          # newest|oldest|largest|smallest|first|last
MIN_SIZE=0             # per-file size threshold (bytes) for considering a group
FILTER_PREFIX=""       # only produce extras under this path prefix (kept file can be anywhere)
GROUP_DEPTH=2          # path grouping depth for summary (/volume1/Share = 2)
TOP_N=10               # show top N groups in console

PLAN="$LOGS_DIR/review-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
SUMMARY_TSV="$LOGS_DIR/review-duplicates-summary-$DATE_TAG-$RUN_ID.tsv"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

usage() {
cat <<EOF
Usage: $0 [--from-report FILE] [--from-csv FILE] [--keep POLICY]
          [--min-size BYTES] [--filter-prefix PATH] [--group-depth N] [--top N]
          [-h|--help]

Policies (which single file to KEEP in each hash group):
  newest | oldest | largest | smallest | first | last

Examples:
  $0 --keep newest
  $0 --keep largest --min-size 1048576 --group-depth 3 --top 20
  $0 --from-report logs/$(date +%F)-duplicate-hashes.txt --from-csv hashes/hasher-$(date +%F).csv
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-report) REPORT="${2:-}"; shift ;;
    --from-csv)    CSV="${2:-}"; shift ;;
    --keep)        KEEP="${2:-newest}"; shift ;;
    --min-size)    MIN_SIZE="${2:-0}"; shift ;;
    --filter-prefix) FILTER_PREFIX="${2:-}"; shift ;;
    --group-depth) GROUP_DEPTH="${2:-2}"; shift ;;
    --top)         TOP_N="${2:-10}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo -e "${YELLOW}Unknown option: $1${NC}"; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOGS_DIR"

# Auto-pick files if not specified
if [[ -z "$REPORT" ]]; then
  if ! REPORT="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1)"; then
    echo "ERROR: No duplicate report found in $LOGS_DIR. Run find-duplicates.sh." >&2
    exit 1
  fi
fi
if [[ -z "$CSV" ]]; then
  if ! CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1)"; then
    echo "ERROR: No hasher CSV found in $HASHES_DIR. Run hasher.sh first." >&2
    exit 1
  fi
fi

[[ -r "$REPORT" ]] || { echo "ERROR: Cannot read report: $REPORT" >&2; exit 1; }
[[ -r "$CSV"    ]] || { echo "ERROR: Cannot read CSV: $CSV" >&2; exit 1; }

# Pre-create/clear outputs safely (avoid weird awk shell calls)
: > "$PLAN"
: > "$SUMMARY_TSV"

# Count total groups to show progress
TOTAL_GROUPS=$(grep -c '^HASH ' "$REPORT" 2>/dev/null || echo 0)

echo -e "${GREEN}Reviewing duplicates (dry-run)…${NC}"
echo "  • Report:       $REPORT"
echo "  • CSV:          $CSV"
echo "  • Keep policy:  $KEEP"
echo "  • Filters:      min_size=${MIN_SIZE}B${FILTER_PREFIX:+, prefix=$FILTER_PREFIX}"
echo "  • Outputs:      plan=$PLAN"
echo "                  summary=$SUMMARY_TSV"
echo

# AWK does the heavy lifting: loads CSV (path->size,mtime), parses report groups,
# applies policy to choose keep, writes plan (extras; optionally filtered by prefix),
# and writes a summary TSV grouped by path prefix (depth). Also prints periodic progress.
awk -v csv="$CSV" -v report="$REPORT" -v plan="$PLAN" -v summary="$SUMMARY_TSV" \
    -v keep="$KEEP" -v minsize="$MIN_SIZE" -v wantprefix="$FILTER_PREFIX" \
    -v depth="$GROUP_DEPTH" -v topn="$TOP_N" -v total="$TOTAL_GROUPS" -v every=250 '
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
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
    c=index(rest,","); if (c==0) return 0
    hash=substr(rest,c+1); hash=ltrim(rtrim(hash))
    PATH=path; SIZE=size_str+0; MTIME=mtime_str+0; HASH=hash
    return 1
  }

  function prefix_of(p, depth,   i,n,part,count,acc) {
    n = split(p, a, "/")
    acc=""; count=0
    for (i=1; i<=n; i++) {
      part=a[i]
      if (part=="") continue
      count++
      if (count<=depth) acc=acc "/" part; else break
    }
    if (acc=="") acc="/"
    return acc
  }

  function load_csv(file) {
    while ((getline line < file) > 0) {
      if (NRcsv==0) { NRcsv++; continue }  # skip header
      if (parse_csv_line(line)) {
        size[PATH]=SIZE
        mtime[PATH]=MTIME
      }
      NRcsv++
    }
    close(file)
  }

  function cmp(a,b,policy) {
    if (policy=="newest")      { if (mtime[a]>mtime[b]) return 1; if (mtime[a]<mtime[b]) return -1; }
    else if (policy=="oldest") { if (mtime[a]<mtime[b]) return 1; if (mtime[a]>mtime[b]) return -1; }
    else if (policy=="largest"){ if (size[a]>size[b])  return 1; if (size[a]<size[b])  return -1; }
    else if (policy=="smallest"){if (size[a]<size[b])  return 1; if (size[a]>size[b])  return -1; }
    else if (policy=="first")  { if (a<b) return 1; if (a>b) return -1; }
    else if (policy=="last")   { if (a>b) return 1; if (a<b) return -1; }
    return 0
  }

  function choose_keep(arr, n, policy,   i, best) {
    best=arr[1]
    for (i=2;i<=n;i++){ if (cmp(arr[i], best, policy)>0) best=arr[i] }
    return best
  }

  function progress_tick() {
    if (total>0 && (grp_seen%every==0 || grp_seen==total)) {
      pct = int(grp_seen*100/total)
      printf("[PROGRESS] Groups: %d/%d (%d%%)\n", grp_seen, total, pct) > "/dev/stderr"
    } else if (total==0 && grp_seen%every==0) {
      printf("[PROGRESS] Groups processed: %d\n", grp_seen) > "/dev/stderr"
    }
  }

  function flush_group(   i, keepfile, pre, extra_count_in_group) {
    if (gcount<2) { gcount=0; return }
    if (gsize<minsize) { gcount=0; return }

    keepfile = choose_keep(gfiles, gcount, keep)

    extra_count_in_group = 0
    for (i=1;i<=gcount;i++) if (gfiles[i]!=keepfile) {
      if (wantprefix=="" || index(gfiles[i], wantprefix)==1) {
        print gfiles[i] >> plan
        extras_total++
        reclaim_total += (gfiles[i] in size ? size[gfiles[i]] : 0)
        extra_count_in_group++
        pre = prefix_of(gfiles[i], depth)
        grpcount[pre]++
      }
    }

    if (extra_count_in_group>0) {
      groups_considered++
      files_in_dup_groups += gcount
    }
    gcount=0
  }

  BEGIN{
    load_csv(csv)
    gcount=0; gsize=0
    groups_considered=0; files_in_dup_groups=0
    extras_total=0; reclaim_total=0
    grp_seen=0
  }

  # Parse report:
  # HASH <hash> (<N> files):
  #   /path/one
  #   /path/two
  /^HASH[ ]/ {
    flush_group()
    grp_seen++
    progress_tick()
    gcount=0; gsize=0
    next
  }

  /^[ ]{2}/ {
    f=$0; sub(/^[ ]+/, "", f)
    if (f=="") next
    gcount++; gfiles[gcount]=f
    if (gcount==1) gsize = (f in size ? size[f] : 0)
    next
  }

  /^$/ { next }

  END{
    flush_group()
    # write summary TSV (prefix \t count_of_extras)
    for (k in grpcount) print k "\t" grpcount[k] > summary
    close(summary)

    # console summary
    printf("%sPreview complete.%s\n", "\033[0;32m", "\033[0m") > "/dev/stderr"
    printf("  • Groups with extras (considered): %d\n", groups_considered) > "/dev/stderr"
    printf("  • Files in those dup groups:       %d\n", files_in_dup_groups) > "/dev/stderr"
    printf("  • Extras (would remove/move):      %d\n", extras_total) > "/dev/stderr"
    printf("  • Potential reclaim:               %d bytes\n", reclaim_total) > "/dev/stderr"
    printf("  • Plan file (extras):              %s\n", plan) > "/dev/stderr"
    printf("  • Summary TSV:                     %s\n", summary) > "/dev/stderr"
  }
' 

# Print Top-N groups from the summary TSV (sorted by count desc)
if [[ -s "$SUMMARY_TSV" ]]; then
  sort -k2,2nr "$SUMMARY_TSV" -o "$SUMMARY_TSV" || true
  echo
  echo "Top $TOP_N groups (depth=$GROUP_DEPTH):"
  rank=0
  total_extras=$(awk -F'\t' '{s+=$2} END{print s+0}' "$SUMMARY_TSV")
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
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "  1) Review the plan (extras to remove/move):"
echo "       less \"$PLAN\""
echo "  2) (Recommended) Quarantine the extras first with your dedupe tool, e.g.:"
echo "       ./deduplicate.sh --from-report \"$REPORT\" --keep $KEEP --quarantine \"quarantine-$DATE_TAG\""
echo "     Or, if your dedupe accepts a file list of extras:"
echo "       xargs -0 -I{} bash -c 'mkdir -p \"quarantine-$DATE_TAG\$(dirname \"{}\"); mv -n -- \"{}\" \"quarantine-$DATE_TAG{}\"' < <(tr '\\n' '\\0' < \"$PLAN\")"
echo "  3) When confident, you can delete extras instead of moving (dangerous):"
echo "       ./deduplicate.sh --from-report \"$REPORT\" --keep $KEEP --force"
