#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# delete-duplicates.sh — Execute a dedupe plan (extras-only) or build it from a report.
# Safe by default (DRY-RUN). Use --force to actually delete or move to quarantine.
#
# Primary workflow:
#   hasher.sh → find-duplicates.sh → review-duplicates.sh → delete-duplicates.sh
#
# Modes:
#   • --from-plan FILE      Use the extras-only plan created by review-duplicates.sh
#   • --from-report FILE    Derive extras on-the-fly from a duplicate report; requires a CSV
#       [--keep newest|oldest|largest|smallest|first|last]  (default: newest)
#       [--from-csv FILE]   (auto-picks newest hashes/hasher-*.csv if omitted)
#
# Actions (dry-run unless --force):
#   • delete (default when --force and no --quarantine)
#   • move to quarantine DIR (when --quarantine DIR and --force)
#
# Outputs:
#   • Verified plan of actions: logs/verified-dedupe-plan-<DATE>-<RUN>.txt
#   • Summary TSV by path:     logs/delete-duplicates-summary-<DATE>-<RUN>.tsv
#   • Execution log:           logs/delete-duplicates-<DATE>.log

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

FROM_PLAN=""          # --from-plan FILE (extras list; one path per line)
FROM_REPORT=""        # --from-report FILE
CSV=""                # --from-csv FILE (needed if using --from-report)
KEEP="newest"         # keep policy when deriving from report
FORCE=false           # --force to actually mutate
QUARANTINE=""         # --quarantine DIR (requires --force)
YES=false             # --yes to auto-confirm
GROUP_DEPTH=2         # for summary TSV
TOP_N=10              # how many groups to print at end

VERIFIED="$LOGS_DIR/verified-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
SUMMARY_TSV="$LOGS_DIR/delete-duplicates-summary-$DATE_TAG-$RUN_ID.tsv"
EXEC_LOG="$LOGS_DIR/delete-duplicates-$DATE_TAG.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

usage() {
cat <<EOF
Usage: $0 [--from-plan FILE] | [--from-report FILE [--keep POLICY] [--from-csv FILE]]
          [--force] [--quarantine DIR] [--yes]
          [--group-depth N] [--top N] [-h|--help]

Actions:
  Dry-run always. Add --force to execute.
  If --quarantine DIR is set with --force, files are MOVED to DIR (tree preserved).
  Otherwise, files are DELETED with --force.

Examples:
  # Execute a reviewed plan (recommended path):
  $0 --from-plan "logs/review-dedupe-plan-*.txt"        # dry-run (auto-picks newest)
  $0 --from-plan "logs/review-dedupe-plan-2025-08-30-*.txt" --force
  $0 --from-plan "logs/review-dedupe-plan-*.txt" --force --quarantine "quarantine-$(date +%F)"

  # Derive from report (skip the interactive review step):
  $0 --from-report "logs/$(date +%F)-duplicate-hashes.txt" --keep newest --force --quarantine "quarantine-$(date +%F)"
EOF
}

# ───────── Args ─────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-plan)   FROM_PLAN="${2:-}"; shift ;;
    --from-report) FROM_REPORT="${2:-}"; shift ;;
    --from-csv)    CSV="${2:-}"; shift ;;
    --keep)        KEEP="${2:-newest}"; shift ;;
    --force)       FORCE=true ;;
    --quarantine)  QUARANTINE="${2:-}"; shift ;;
    --yes|-y)      YES=true ;;
    --group-depth) GROUP_DEPTH="${2:-2}"; shift ;;
    --top)         TOP_N="${2:-10}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo -e "${YELLOW}Unknown option: $1${NC}"; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOGS_DIR"

log() {
  local lvl="$1"; shift
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RUN %s] [%s] %s\n' "$ts" "$RUN_ID" "$lvl" "$*" | tee -a "$EXEC_LOG" >&2
}

# ───────── Input resolution ─────────

# Prefer --from-plan; if omitted, auto-pick newest review plan.
if [[ -z "$FROM_PLAN" && -z "$FROM_REPORT" ]]; then
  # try most recent review plan
  FROM_PLAN="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
fi

if [[ -n "$FROM_PLAN" ]]; then
  # expand globs safely
  set +f
  arr=( $FROM_PLAN )
  set -f
  if (( ${#arr[@]} > 1 )); then
    # pick newest
    FROM_PLAN="$(ls -1t "${arr[@]}" 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$FROM_PLAN" && -r "$FROM_PLAN" ]] || { echo -e "${RED}ERROR:${NC} Plan not found/readable."; exit 1; }
  MODE="plan"
else
  [[ -r "$FROM_REPORT" ]] || { echo -e "${RED}ERROR:${NC} Report not found/readable."; exit 1; }
  # CSV for policy decisions (mtime/size). Auto-pick newest if missing.
  if [[ -z "$CSV" ]]; then
    CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$CSV" && -r "$CSV" ]] || { echo -e "${RED}ERROR:${NC} CSV not found/readable (needed with --from-report)."; exit 1; }
  MODE="report"
fi

# ───────── If deriving from report, build a temp plan of EXTRAS ─────────
TMPPLAN=""
if [[ "$MODE" == "report" ]]; then
  TMPPLAN="$LOGS_DIR/tmp-plan-$DATE_TAG-$RUN_ID.txt"
  : > "$TMPPLAN"
  log INFO "Deriving extras from report using keep=$KEEP …"
  # Build extras-only plan from the report with help from CSV (mtime/size)
  awk -v report="$FROM_REPORT" -v csv="$CSV" -v keep="$KEEP" -v out="$TMPPLAN" '
    function ltrim(s){ sub(/^[ \t\r\n]+/,"",s); return s }
    function rtrim(s){ sub(/[ \t\r\n]+$/,"",s); return s }
    function uq(s){ gsub(/""/,"\"",s); return s }
    function parse_csv(line,  path,rest,c,endq,size_str,mtime_str,hash){
      if (substr(line,1,1)=="\"") {
        endq=0
        for(i=2;i<=length(line);i++){
          ch=substr(line,i,1)
          if(ch=="\""){ nxt=substr(line,i+1,1); if(nxt=="\""){i++} else {endq=i; break} }
        }
        if(endq==0) return 0
        path=substr(line,2,endq-2); path=uq(path); rest=substr(line,endq+2)
      } else {
        c=index(line,","); if(c==0) return 0
        path=substr(line,1,c-1); rest=substr(line,c+1)
      }
      c=index(rest,","); if(c==0) return 0
      size_str=substr(rest,1,c-1); rest=substr(rest,c+1)
      c=index(rest,","); if(c==0) return 0
      mtime_str=substr(rest,1,c-1); rest=substr(rest,c+1)
      c=index(rest,","); if(c==0) return 0
      hash=substr(rest,c+1); hash=ltrim(rtrim(hash))
      SIZE[path]=size_str+0; MTIME[path]=mtime_str+0
      return 1
    }
    function cmp(a,b){
      if (keep=="newest")     { if (MTIME[a]>MTIME[b]) return 1; if (MTIME[a]<MTIME[b]) return -1; }
      else if (keep=="oldest"){ if (MTIME[a]<MTIME[b]) return 1; if (MTIME[a]>MTIME[b]) return -1; }
      else if (keep=="largest"){ if (SIZE[a]>SIZE[b])  return 1; if (SIZE[a]<SIZE[b])  return -1; }
      else if (keep=="smallest"){if (SIZE[a]<SIZE[b])  return 1; if (SIZE[a]>SIZE[b])  return -1; }
      else if (keep=="first") { if (a<b) return 1; if (a>b) return -1; }
      else if (keep=="last")  { if (a>b) return 1; if (a<b) return -1; }
      return 0
    }
    function choose_keep(arr,n,  i,b){ b=arr[1]; for(i=2;i<=n;i++){ if(cmp(arr[i],b)>0) b=arr[i] } return b }
    BEGIN{
      while ((getline cl < csv) > 0) { if (NRc==0){NRc++; continue}; parse_csv(cl); NRc++ } close(csv)
    }
    /^HASH[ ]/ { flush(); gcount=0; next }
    /^[ ]{2}/  { f=$0; sub(/^[ ]+/,"",f); if(f!=""){ g[++gcount]=f } next }
    { next } # ignore
    function flush(  i,keepf){
      if (gcount<2) return
      keepf=choose_keep(g,gcount)
      for(i=1;i<=gcount;i++) if (g[i]!=keepf) print g[i] >> out
    }
    END{ flush() }
  ' "$FROM_REPORT"
  FROM_PLAN="$TMPPLAN"
fi

# ───────── Verify plan (existence, regular file) and compute basic stats ─────────
: > "$VERIFIED"
: > "$SUMMARY_TSV"

total_in=0
verified=0
missing=0
notreg=0
bytes_total=0

# verify loop
while IFS= read -r p || [[ -n "$p" ]]; do
  ((total_in++))
  if [[ ! -e "$p" ]]; then
    ((missing++))
    continue
  fi
  if [[ ! -f "$p" ]]; then
    ((notreg++))
    continue
  fi
  printf '%s\n' "$p" >> "$VERIFIED"
  # stat size (best-effort)
  sz="$(stat -c%s -- "$p" 2>/dev/null || echo 0)"
  bytes_total=$(( bytes_total + sz ))
done < "$FROM_PLAN"

# Build summary TSV by path prefix
if [[ -s "$VERIFIED" ]]; then
  awk -v depth="$GROUP_DEPTH" '
    function pref(p,depth,   i,n,part,count,acc){
      n=split(p,a,"/"); acc=""; count=0
      for(i=1;i<=n;i++){ part=a[i]; if(part=="") continue; count++; if(count<=depth) acc=acc "/" part; else break }
      if(acc=="") acc="/"; return acc
    }
    { g[pref($0,depth)]++ }
    END{ for(k in g) printf("%s\t%d\n",k,g[k]) }
  ' "$VERIFIED" | sort -k2,2nr > "$SUMMARY_TSV"
fi

pp_bytes() {  # simple pretty bytes (binary units)
  local b="${1:-0}" u=(B KiB MiB GiB TiB PiB) i=0
  while (( b >= 1024 && i < ${#u[@]}-1 )); do b=$(( (b + 1023) / 1024 )); i=$((i+1)); done
  printf "%d %s" "$b" "${u[$i]}"
}

log INFO "Mode: ${MODE^^}"
log INFO "Input: ${MODE^^} file: ${MODE=="plan" ? FROM_PLAN : FROM_REPORT}"
[[ "$MODE" == "report" ]] && log INFO "CSV: $CSV | keep=$KEEP"
log INFO "Verified plan: $VERIFIED"
log INFO "S
