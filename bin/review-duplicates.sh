#!/bin/bash
# review-duplicates.sh — build a deletion PLAN for duplicate files
# - Reads a duplicates report (CSV: hash,size,path OR whitespace: hash size path)
# - Prefilters "low-value" groups (size <= LOW_VALUE_THRESHOLD_BYTES from hasher.conf, default 0)
#     → diverted to low-value/low-value-candidates-<date>-<RUN_ID>.txt
# - Presents remaining groups for review (interactive by default), or auto-keep by policy
# - Emits a plan file: logs/review-dedupe-plan-YYYY-MM-DD-<RUN_ID>.txt (one path per line to delete)
#
# Example:
#   ./review-duplicates.sh --from-report logs/2025-08-30-duplicate-hashes.txt --keep newest --limit 100
#
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ── Logging ───────────────────────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }
if [ -r /proc/sys/kernel/random/uuid ]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$-$RANDOM"
fi
log() { printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO"  "$*"; }
log_warn(){ log "WARN"  "$*"; }
log_error(){ log "ERROR" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
REPORT_FILE=""
KEEP_POLICY="none"   # none|newest|oldest|path-prefer=REGEX
LIMIT=100
ORDER="size-desc"    # size-desc|size-asc
NON_INTERACTIVE=false

usage(){
cat <<'EOF'
Usage: review-duplicates.sh --from-report <file> [options]

Options:
  --keep newest|oldest|path-prefer=REGEX|none
  --limit N                 Review at most N groups (default: 100)
  --order size-desc|size-asc
  --non-interactive         Apply --keep policy across all groups without prompting
  --plan-out FILE           Override default plan path
  -h, --help                Show this help

Notes:
  • "Low-value" groups (size <= LOW_VALUE_THRESHOLD_BYTES in hasher.conf) are diverted
    to low-value/low-value-candidates-<date>-<RUN_ID>.txt and NOT shown in the review UI.
  • The plan file contains paths to DELETE. No deletions happen in this script.
EOF
}

PLAN_OUT=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --from-report) REPORT_FILE="${2:-}"; shift ;;
    --keep) KEEP_POLICY="${2:-}"; shift ;;
    --limit) LIMIT="${2:-100}"; shift ;;
    --order) ORDER="${2:-size-desc}"; shift ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    --plan-out) PLAN_OUT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
  shift || true
done

[ -n "$REPORT_FILE" ] || { log_error "Missing --from-report"; exit 2; }
[ -r "$REPORT_FILE" ] || { log_error "Report not readable: $REPORT_FILE"; exit 2; }

mkdir -p logs low-value

# ── Load LOW_VALUE_THRESHOLD_BYTES from hasher.conf ───────────────────────────
LOW_VALUE_THRESHOLD_BYTES="0"
if [ -r "hasher.conf" ]; then
  val="$(awk -F= '/^[[:space:]]*LOW_VALUE_THRESHOLD_BYTES[[:space:]]*=/{print $2; exit}' hasher.conf | tr -d '\r\n"'\''[:space:]')"
  case "$val" in (''|*[!0-9]*) ;; (*) LOW_VALUE_THRESHOLD_BYTES="$val" ;; esac
fi

# ── Prefilter low-value groups into a side list ───────────────────────────────
PREFILTERED_REPORT="logs/$(date +%F)-duplicate-hashes-nonlow-${RUN_ID}.txt"
LOW_VALUE_DUMP="low-value/low-value-candidates-$(date +%F)-${RUN_ID}.txt"

# Detect CSV vs whitespace per line and re-emit only non-low-value rows to PREFILTERED_REPORT
awk -v dump="$LOW_VALUE_DUMP" -v out="$PREFILTERED_REPORT" -v thr="$LOW_VALUE_THRESHOLD_BYTES" '
  function isnum(x){ return (x ~ /^[0-9]+$/) }
  BEGIN{ FS="," }
  {
    # Try CSV first
    h=$1; s=$2; p=$3
    if(!isnum(s)){
      # Fallback: whitespace
      n=split($0,a,/[ \t]+/); h=a[1]; s=a[2]; p=""
      if(n>=3){
        # rebuild original path with spaces
        for(i=3;i<=n;i++){ p = (p? p " " : "") a[i] }
      }
    }
    if(isnum(s) && s <= thr){
      print p >> dump
      next
    }
    print $0 >> out
  }
' "$REPORT_FILE"

if [ -s "$LOW_VALUE_DUMP" ]; then
  log_info "Low-value duplicate entries diverted (<= ${LOW_VALUE_THRESHOLD_BYTES} bytes): $(wc -l < "$LOW_VALUE_DUMP")"
  log_info "  • Saved to: $LOW_VALUE_DUMP"
  log_info "  • Next steps: ./delete-low-value.sh --from-list \"$LOW_VALUE_DUMP\" --verify-only"
fi

# Use filtered report from here on
REPORT_FILE="$PREFILTERED_REPORT"

# ── Index groups (hash -> paths, size) ────────────────────────────────────────
# We normalise to "hash|size|path" lines to ease bash parsing.
INDEX_FILE="logs/dups-index-${RUN_ID}.txt"
: > "$INDEX_FILE"
awk '
  function isnum(x){ return (x ~ /^[0-9]+$/) }
  BEGIN{ FS="," }
  {
    h=$1; s=$2; p=$3
    if(!(s ~ /^[0-9]+$/)){
      # Fallback whitespace
      n=split($0,a,/[ \t]+/); h=a[1]; s=a[2]; p=""
      if(n>=3){
        for(i=3;i<=n;i++){ p = (p? p " " : "") a[i] }
      }
    }
    if(h=="" || !(s ~ /^[0-9]+$/) || p=="") next
    printf "%s|%s|%s\n", h, s, p
  }
' "$REPORT_FILE" >> "$INDEX_FILE"

TOTAL_ROWS=$(wc -l < "$INDEX_FILE" | tr -d ' ')
[ "$TOTAL_ROWS" -gt 0 ] || { log_warn "No duplicate rows after filtering; nothing to review."; exit 0; }

# Build group list: hash -> size,count
GROUP_LIST="logs/dups-groups-${RUN_ID}.txt"
: > "$GROUP_LIST"
awk -F'|' '{ c[$1]++; sz[$1]=$2 } END{ for(h in c){ printf "%s %s %s\n", sz[h], c[h], h } }' "$INDEX_FILE" \
  > "$GROUP_LIST"

TOTAL_GROUPS=$(wc -l < "$GROUP_LIST" | tr -d ' ')

# Sort groups by size
case "$ORDER" in
  size-asc)  SORTED_GROUPS="logs/dups-groups-sorted-${RUN_ID}.txt"; sort -n  "$GROUP_LIST" > "$SORTED_GROUPS" ;;
  *)         SORTED_GROUPS="logs/dups-groups-sorted-${RUN_ID}.txt"; sort -nr "$GROUP_LIST" > "$SORTED_GROUPS" ;;
esac

# Plan path
[ -n "$PLAN_OUT" ] || PLAN_OUT="logs/review-dedupe-plan-$(date +'%Y-%m-%d')-$(date +%s).txt"
: > "$PLAN_OUT"

# ── Helpers ───────────────────────────────────────────────────────────────────
# human size
hsize(){
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB PB",u); s=1; while (b>=1024 && s<6){ b/=1024; s++ } printf("%.0f %s", b, u[s])
  }'
}
mtime_epoch(){
  # stat -c %Y works on BusyBox/GNU on Synology typically; fallback to 0 if not available
  stat -c %Y -- "$1" 2>/dev/null || stat --format=%Y -- "$1" 2>/dev/null || echo 0
}
mtime_iso(){
  local e; e="$(mtime_epoch "$1")"
  date -d "@$e" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "1970-01-01 00:00:00"
}
choose_keep_by_policy(){
  local policy="$1"; local hash="$2"; shift 2
  local paths=("$@")
  local keep_idx=0

  case "$policy" in
    newest)
      local best_ts=0 ts i=0
      for p in "${paths[@]}"; do
        ts="$(mtime_epoch "$p")"; ts="${ts:-0}"
        if [ "$ts" -ge "$best_ts" ]; then best_ts="$ts"; keep_idx="$i"; fi
        i=$((i+1))
      done
      ;;
    oldest)
      local best_ts=9999999999 ts i=0
      for p in "${paths[@]}"; do
        ts="$(mtime_epoch "$p")"; ts="${ts:-0}"
        if [ "$ts" -le "$best_ts" ]; then best_ts="$ts"; keep_idx="$i"; fi
        i=$((i+1))
      done
      ;;
    path-prefer=*)
      local rx="${policy#path-prefer=}"
      local i=0
      for p in "${paths[@]}"; do
        echo "$p" | grep -Eiq -- "$rx" && { keep_idx="$i"; break; }
        i=$((i+1))
      done
      ;;
    *) keep_idx=0 ;;
  esac
  echo "$keep_idx"
}

# ── Review loop ───────────────────────────────────────────────────────────────
log_info "Index ready. Starting review…"
log_info "  • Ordering:     ${ORDER/size-/size }"
log_info "  • Limit:        $LIMIT"
log_info "  • Groups:       $TOTAL_GROUPS total"
log_info "  • Plan:         $PLAN_OUT"
[ "$KEEP_POLICY" != "none" ] && log_info "  • Keep policy:  $KEEP_POLICY"
$NON_INTERACTIVE && log_info "  • Mode:         non-interactive (auto-keep by policy)"

shown=0
while IFS=' ' read -r gsize gcount ghash; do
  [ "$shown" -ge "$LIMIT" ] && break

  # Collect paths for this hash
  mapfile -t paths < <(awk -F'|' -v h="$ghash" '$1==h{print $3}' "$INDEX_FILE")
  # Defensive: ensure count matches
  [ "${#paths[@]}" -lt 2 ] && continue

  # Display header
  sz_human="$(hsize "$gsize")"
  reclaim=$(( (gcount-1) * gsize ))
  reclaim_h="$(hsize "$reclaim")"
  idx=$((shown+1))
  printf "[%d/%d] Size: %s  |  Files: %s  |  Potential reclaim: %s\n" "$idx" "$LIMIT" "$sz_human" "$gcount" "$reclaim_h"

  # Display first 12 entries with mtimes
  i=1
  for p in "${paths[@]}"; do
    [ $i -le 12 ] || { echo "       … and $((gcount-12)) more not shown"; break; }
    printf "    %d) %s  \"%s\"\n" "$i" "$sz_human" "$p"
    printf "       modified: %s\n" "$(mtime_iso "$p")"
    i=$((i+1))
  done

  # Decide keep
  if $NON_INTERACTIVE && [ "$KEEP_POLICY" != "none" ]; then
    sel="$(choose_keep_by_policy "$KEEP_POLICY" "$ghash" "${paths[@]}")"
  else
    # Prompt
    read -r -p "Select the file ID to KEEP [1-${#paths[@]}], 's' to skip, 'q' to quit: " ans || ans="s"
    case "$ans" in
      q|Q) echo "  → Quit."; break ;;
      s|S|"") echo "  → Skipped."; shown=$((shown+1)); continue ;;
      *)
        if echo "$ans" | grep -Eq '^[0-9]+$' && [ "$ans" -ge 1 ] && [ "$ans" -le "${#paths[@]}" ]; then
          sel=$((ans-1))
        else
          echo "  → Invalid; skipped."; shown=$((shown+1)); continue
        fi
        ;;
    esac
  fi

  # Write deletions (all except selected)
  keep_path="${paths[$sel]}"
  for j in "${!paths[@]}"; do
    [ "$j" -eq "$sel" ] && continue
    printf "%s\n" "${paths[$j]}" >> "$PLAN_OUT"
  done
  echo "  → Keeping: \"$keep_path\"; marked $((gcount-1)) for deletion."
  shown=$((shown+1))
done < "$SORTED_GROUPS"

log_info "Plan written: $PLAN_OUT"
log_info "Next steps:"
log_info "  • Dry-run: ./delete-duplicates.sh --from-plan \"$PLAN_OUT\""
log_info "  • Execute: ./delete-duplicates.sh --from-plan \"$PLAN_OUT\" --force [--quarantine DIR]"
log_info "  • Low-value candidates, if any, saved to: $LOW_VALUE_DUMP"
exit 0
