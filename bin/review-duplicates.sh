#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#!/bin/bash
# review-duplicates.sh — build a deletion PLAN for duplicate files
# - Reads a duplicates report (CSV: hash,size,path OR whitespace: hash size path)
# - Prefilters "low-value" groups (size <= LOW_VALUE_THRESHOLD_BYTES from hasher.conf, default 0)
#     → diverted to $LOW_DIR/low-value-candidates-<date>-<RUN_ID>.txt
# - Presents remaining groups for review (interactive by default), or auto-keep by policy
# - Emits a plan file: $LOG_DIR/review-dedupe-plan-YYYY-MM-DD-<RUN_ID>.txt
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# Path/layout discovery
. "$(dirname "$0")/lib_paths.sh" 2>/dev/null || true

ts() { date +"%Y-%m-%d %H:%M:%S"; }
if [ -r /proc/sys/kernel/random/uuid ]; then RUN_ID="$(cat /proc/sys/kernel/random/uuid)"; else RUN_ID="$(date +%s)-$$-$RANDOM"; fi
log(){ printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO" "$*"; }; log_warn(){ log "WARN" "$*"; }; log_error(){ log "ERROR" "$*"; }

REPORT_FILE=""; KEEP_POLICY="none"; LIMIT=100; ORDER="size-desc"; NON_INTERACTIVE=false; PLAN_OUT=""
usage(){ cat <<'EOF'
Usage: review-duplicates.sh --from-report <file> [options]
  --keep newest|oldest|path-prefer=REGEX|none
  --limit N                 Review at most N groups (default: 100)
  --order size-desc|size-asc
  --non-interactive         Apply --keep policy across all groups without prompting
  --plan-out FILE           Override default plan path
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT_FILE="${2:-}"; shift ;;
    --keep) KEEP_POLICY="${2:-}"; shift ;;
    --limit) LIMIT="${2:-100}"; shift ;;
    --order) ORDER="${2:-size-desc}"; shift ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    --plan-out) PLAN_OUT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown arg: $1"; usage; exit 2 ;;
  esac; shift || true
done
[ -n "$REPORT_FILE" ] || { log_error "Missing --from-report"; exit 2; }
[ -r "$REPORT_FILE" ] || { log_error "Report not readable: $REPORT_FILE"; exit 2; }

mkdir -p "$LOG_DIR" "$LOW_DIR"

LOW_VALUE_THRESHOLD_BYTES="0"
if [ -r "$CONF_FILE" ]; then
  val="$(awk -F= '/^[[:space:]]*LOW_VALUE_THRESHOLD_BYTES[[:space:]]*=/{print $2; exit}' "$CONF_FILE" | tr -d '\r\n"'\''[:space:]')"
  case "$val" in (''|*[!0-9]*) ;; (*) LOW_VALUE_THRESHOLD_BYTES="$val" ;; esac
fi

PREFILTERED_REPORT="$LOG_DIR/$(date +%F)-duplicate-hashes-nonlow-${RUN_ID}.txt"
LOW_VALUE_DUMP="$LOW_DIR/low-value-candidates-$(date +%F)-${RUN_ID}.txt"
awk -v dump="$LOW_VALUE_DUMP" -v out="$PREFILTERED_REPORT" -v thr="$LOW_VALUE_THRESHOLD_BYTES" '
  function isnum(x){ return (x ~ /^[0-9]+$/) }
  BEGIN{ FS="," }
  {
    h=$1; s=$2; p=$3
    if(!isnum(s)){
      n=split($0,a,/[ \t]+/); h=a[1]; s=a[2]; p="";
      if(n>=3){ for(i=3;i<=n;i++){ p = (p? p " " : "") a[i] } }
    }
    if(isnum(s) && s<=thr){ print p >> dump; next }
    print $0 >> out
  }
' "$REPORT_FILE"

if [ -s "$LOW_VALUE_DUMP" ]; then
  log_info "Low-value duplicate entries diverted (<= ${LOW_VALUE_THRESHOLD_BYTES} bytes): $(wc -l < "$LOW_VALUE_DUMP")"
  log_info "  • Saved to: $LOW_VALUE_DUMP"
  log_info "  • Next steps: ./bin/delete-low-value.sh --from-list \"$LOW_VALUE_DUMP\" --verify-only"
fi
REPORT_FILE="$PREFILTERED_REPORT"

INDEX_FILE="$LOG_DIR/dups-index-${RUN_ID}.txt"; : > "$INDEX_FILE"
awk '
  function isnum(x){ return (x ~ /^[0-9]+$/) }
  BEGIN{ FS="," }
  {
    h=$1; s=$2; p=$3
    if(!(s ~ /^[0-9]+$/)){
      n=split($0,a,/[ \t]+/); h=a[1]; s=a[2]; p="";
      if(n>=3){ for(i=3;i<=n;i++){ p = (p? p " " : "") a[i] } }
    }
    if(h=="" || !(s ~ /^[0-9]+$/) || p=="") next
    printf "%s|%s|%s\n", h, s, p
  }
' "$REPORT_FILE" >> "$INDEX_FILE"

TOTAL_ROWS=$(wc -l < "$INDEX_FILE" | tr -d ' ')
[ "$TOTAL_ROWS" -gt 0 ] || { log_warn "No duplicate rows after filtering; nothing to review."; exit 0; }

GROUP_LIST="$LOG_DIR/dups-groups-${RUN_ID}.txt"; : > "$GROUP_LIST"
awk -F'|' '{ c[$1]++; sz[$1]=$2 } END{ for(h in c){ printf "%s %s %s\n", sz[h], c[h], h } }' "$INDEX_FILE" > "$GROUP_LIST"
TOTAL_GROUPS=$(wc -l < "$GROUP_LIST" | tr -d ' ')

case "$ORDER" in
  size-asc)  SORTED_GROUPS="$LOG_DIR/dups-groups-sorted-${RUN_ID}.txt"; sort -n  "$GROUP_LIST" > "$SORTED_GROUPS" ;;
  *)         SORTED_GROUPS="$LOG_DIR/dups-groups-sorted-${RUN_ID}.txt"; sort -nr "$GROUP_LIST" > "$SORTED_GROUPS" ;;
esac

[ -n "$PLAN_OUT" ] || PLAN_OUT="$LOG_DIR/review-dedupe-plan-$(date +'%Y-%m-%d')-$(date +%s).txt"; : > "$PLAN_OUT"

hsize(){ awk -v b="$1" 'BEGIN{ split("B KB MB GB TB PB",u); s=1; while (b>=1024 && s<6){ b/=1024; s++ } printf("%.0f %s", b, u[s]) }'; }
mtime_epoch(){ stat -c %Y -- "$1" 2>/dev/null || stat --format=%Y -- "$1" 2>/dev/null || echo 0; }
mtime_iso(){ local e; e="$(mtime_epoch "$1")"; date -d "@$e" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "1970-01-01 00:00:00"; }
choose_keep_by_policy(){
  local policy="$1"; shift; local hash="$1"; shift; local paths=("$@"); local keep_idx=0
  case "$policy" in
    newest) local best=0 ts i=0; for p in "${paths[@]}"; do ts="$(mtime_epoch "$p")"; [ "$ts" -ge "$best" ] && { best="$ts"; keep_idx="$i"; }; i=$((i+1)); done ;;
    oldest) local best=9999999999 ts i=0; for p in "${paths[@]}"; do ts="$(mtime_epoch "$p")"; [ "$ts" -le "$best" ] && { best="$ts"; keep_idx="$i"; }; i=$((i+1)); done ;;
    path-prefer=*) local rx="${policy#path-prefer=}"; local i=0; for p in "${paths[@]}"; do echo "$p" | grep -Eiq -- "$rx" && { keep_idx="$i"; break; }; i=$((i+1)); done ;;
    *) keep_idx=0 ;;
  esac; echo "$keep_idx"
}

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
  mapfile -t paths < <(awk -F'|' -v h="$ghash" '$1==h{print $3}' "$INDEX_FILE")
  [ "${#paths[@]}" -lt 2 ] && continue

  sz_human="$(hsize "$gsize")"; reclaim=$(( (gcount-1) * gsize )); reclaim_h="$(hsize "$reclaim")"; idx=$((shown+1))
  printf "[%d/%d] Size: %s  |  Files: %s  |  Potential reclaim: %s\n" "$idx" "$LIMIT" "$sz_human" "$gcount" "$reclaim_h"

  i=1
  for p in "${paths[@]}"; do
    [ $i -le 12 ] || { echo "       … and $((gcount-12)) more not shown"; break; }
    printf "    %d) %s  \"%s\"\n" "$i" "$sz_human" "$p"
    printf "       modified: %s\n" "$(mtime_iso "$p")"; i=$((i+1))
  done

  if $NON_INTERACTIVE && [ "$KEEP_POLICY" != "none" ]; then
    sel="$(choose_keep_by_policy "$KEEP_POLICY" "$ghash" "${paths[@]}")"
  else
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

  keep_path="${paths[$sel]}"
  for j in "${!paths[@]}"; do [ "$j" -eq "$sel" ] && continue; printf "%s\n" "${paths[$j]}" >> "$PLAN_OUT"; done
  echo "  → Keeping: \"$keep_path\"; marked $((gcount-1)) for deletion."
  shown=$((shown+1))
done < "$SORTED_GROUPS"

log_info "Plan written: $PLAN_OUT"
log_info "Next steps:"
log_info "  • Dry-run: ./bin/delete-duplicates.sh --from-plan \"$PLAN_OUT\""
log_info "  • Execute: ./bin/delete-duplicates.sh --from-plan \"$PLAN_OUT\" --force [--quarantine DIR]"
log_info "  • Low-value candidates, if any, saved to: $LOW_VALUE_DUMP"
exit 0
