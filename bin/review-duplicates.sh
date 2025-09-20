#!/usr/bin/env bash
# review-duplicates.sh — interactive/non-interactive review of duplicate file groups
# License: GPLv3
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$APP_HOME/logs"
VAR_DIR="$APP_HOME/var/duplicates"
mkdir -p "$LOGS_DIR" "$VAR_DIR"

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_blue='\033[0;34m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

usage() {
  cat <<'EOF'
Usage: review-duplicates.sh --from-report FILE [options]
  --order size|count     (default: size)
  --skip N               (default: 0)
  --take M               (overrides --limit)
  --limit N              (interactive only; default: 100)
  --keep POLICY          newest|oldest|largest|smallest|first|last (default: newest)
  --non-interactive      apply policy without prompts
  --quiet                reduce chatter
  --config FILE          k=v file (supports LOW_VALUE_THRESHOLD_BYTES=NNN)
EOF
}

FROM_REPORT=""
ORDER="size"; SKIP=0; TAKE=""; LIMIT=100
KEEP_POLICY="newest"; NON_INTERACTIVE=false; QUIET=false; CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --from-report) FROM_REPORT="${2:-}"; shift 2 ;;
    --order) ORDER="${2:-}"; shift 2 ;;
    --skip) SKIP="${2:-0}"; shift 2 ;;
    --take) TAKE="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-100}"; shift 2 ;;
    --keep) KEEP_POLICY="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

LOW_VALUE_THRESHOLD_BYTES=""
if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="$(echo "$val" | tr -d '[:space:]' | tr -d '"')"
    case "$key" in LOW_VALUE_THRESHOLD_BYTES) LOW_VALUE_THRESHOLD_BYTES="$val" ;; esac
  done < "$CONFIG"
  $QUIET || info "Config loaded: LOW_VALUE_THRESHOLD_BYTES=${LOW_VALUE_THRESHOLD_BYTES:-unset}"
fi

if [[ -z "${FROM_REPORT:-}" ]]; then
  if [[ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]]; then
    FROM_REPORT="$LOGS_DIR/duplicate-hashes-latest.txt"
    $QUIET || info "No --from-report supplied; using latest: $FROM_REPORT"
  else
    cand="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
    if [[ -n "$cand" && -s "$cand" ]]; then
      FROM_REPORT="$cand"
      $QUIET || info "No --from-report supplied; using newest: $FROM_REPORT"
    else
      err "Missing --from-report and no reports found in $LOGS_DIR."
      err "Next: run 'find-duplicates.sh' (or menu option 3) to generate the report."
      usage; exit 2
    fi
  fi
fi

if [[ ! -s "$FROM_REPORT" ]]; then
  err "Report not found or empty: $FROM_REPORT"
  usage; exit 2
fi

get_size() {
  local f="$1" out=""
  if out="$(stat -c '%s' -- "$f" 2>/dev/null)"; then printf "%s" "$out"
  elif out="$(busybox stat -c '%s' "$f" 2>/dev/null)"; then printf "%s" "$out"
  elif out="$(ls -ln -- "$f" 2>/dev/null | awk '{print $5}' || true)"; then printf "%s" "${out:-0}"
  else printf "0"; fi
}
get_mtime() {
  local f="$1" out=""
  if out="$(stat -c '%Y' -- "$f" 2>/dev/null)"; then printf "%s" "$out"
  elif out="$(busybox stat -c '%Y' "$f" 2>/dev/null)"; then printf "%s" "$out"
  else printf "0"; fi
}
human() { awk -v b="$1" 'function hum(x){ s="B KMGTPEZY"; while (x>=1024 && length(s)>1){x/=1024; s=substr(s,3)}; return sprintf("%.1f %s", x, substr(s,1,1)) } BEGIN{print hum(b+0)}'; }

timestamp="$(date +'%Y-%m-%d-%H%M%S')"
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
GROUPS_META="$TMPDIR/groups.meta"; > "$GROUPS_META"

total_lines="$(wc -l < "$FROM_REPORT" 2>/dev/null || echo 0)"
lines_seen=0; group_id=0; current_hash=""; declare -a current_paths=()

flush_group() {
  local id="$1" hash="$2"; local count="${#current_paths[@]}"
  (( count == 0 )) && return 0
  (( group_id++ ))
  local total=0; local csv="$TMPDIR/g${group_id}.csv"; : > "$csv"
  local p size mt
  for p in "${current_paths[@]}"; do
    if [[ -e "$p" ]]; then size="$(get_size "$p")"; mt="$(get_mtime "$p")"; else size="0"; mt="0"; fi
    printf "%s,%s,%s\n" "$size" "$mt" "$p" >> "$csv"
    total=$(( total + size ))
  done
  printf "%s,%s,%s,%s\n" "$group_id" "$hash" "$count" "$total" >> "$GROUPS_META"
  current_paths=()
}

$QUIET || printf "${c_blue}Parsing report: %s — this may take a moment…${c_reset}\n" "$FROM_REPORT"
while IFS= read -r line || [[ -n "$line" ]]; do
  lines_seen=$((lines_seen+1))
  if (( lines_seen % 2000 == 0 )) && [[ "$QUIET" != true ]]; then
    printf "  … %d / %d lines\r" "$lines_seen" "$total_lines"
  fi
  if [[ "$line" =~ ^HASH[[:space:]]+([a-fA-F0-9]+)[[:space:]]+\(N=([0-9]+)\) ]]; then
    flush_group "$group_id" "$current_hash"
    current_hash="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]{2}(/.*)$ ]]; then
    current_paths+=("${BASH_REMATCH[1]}"); continue
  fi
done < "$FROM_REPORT"
flush_group "$group_id" "$current_hash"
[[ "$QUIET" != true ]] && printf "  … %d / %d lines\n" "$lines_seen" "$total_lines"

total_groups="$(wc -l < "$GROUPS_META" | tr -d '[:space:]')"
if [[ "${total_groups:-0}" -eq 0 ]]; then
  warn "No duplicate groups parsed from: $FROM_REPORT"
  warn "If you just ran hashing, run 'find-duplicates.sh' (menu option 3) first."
  exit 0
fi
$QUIET || info "Parsed groups: $total_groups from: $FROM_REPORT"

ordered_ids_file="$TMPDIR/ordered.ids"
case "$ORDER" in
  size)  sort -t',' -k4,4nr "$GROUPS_META" | awk -F',' '{print $1}' > "$ordered_ids_file" ;;
  count) sort -t',' -k3,3nr "$GROUPS_META" | awk -F',' '{print $1}' > "$ordered_ids_file" ;;
  *) warn "Unknown --order '$ORDER', defaulting to size"; sort -t',' -k4,4nr "$GROUPS_META" | awk -F',' '{print $1}' > "$ordered_ids_file" ;;
esac

start=$(( SKIP + 1 ))
if [[ -n "${TAKE:-}" ]]; then
  sed -n "${start},$(( SKIP + TAKE ))p" "$ordered_ids_file" > "$TMPDIR/selected.ids"
else
  if [[ "$NON_INTERACTIVE" == true ]]; then
    sed -n "${start},\$p" "$ordered_ids_file" > "$TMPDIR/selected.ids"
  else
    sed -n "${start},$(( SKIP + LIMIT ))p" "$ordered_ids_file" > "$TMPDIR/selected.ids"
  fi
fi

selected_count="$(wc -l < "$TMPDIR/selected.ids" | tr -d '[:space:]')"
if [[ "${selected_count:-0}" -eq 0 ]]; then
  warn "No groups selected after applying --skip/--take/--limit."
  exit 0
fi
$QUIET || info "Selected groups: $selected_count  (order: $ORDER, skip: $SKIP, take: ${TAKE:-all})"

PLAN="$LOGS_DIR/review-dedupe-plan-$timestamp.txt"
SUMMARY="$LOGS_DIR/review-summary-$timestamp.txt"
: > "$PLAN"; : > "$SUMMARY"

pick_index_by_policy() {
  local csv="$1" policy="$2"; local best_idx=1 best_val=0 idx=0
  case "$policy" in
    newest)   best_val=0; idx=0; while IFS=, read -r size mt path; do idx=$((idx+1)); (( mt > best_val )) && { best_val="$mt"; best_idx="$idx"; }; done < "$csv" ;;
    oldest)   best_val=9999999999; idx=0; while IFS=, read -r size mt path; do idx=$((idx+1)); (( mt < best_val )) && { best_val="$mt"; best_idx="$idx"; }; done < "$csv" ;;
    largest)  best_val=0; idx=0; while IFS=, read -r size mt path; do idx=$((idx+1)); (( size > best_val )) && { best_val="$size"; best_idx="$idx"; }; done < "$csv" ;;
    smallest) best_val=9223372036854775807; idx=0; while IFS=, read -r size mt path; do idx=$((idx+1)); (( size < best_val )) && { best_val="$size"; best_idx="$idx"; }; done < "$csv" ;;
    last)     best_idx="$(wc -l < "$csv" | tr -d '[:space:]')" ;;
    first|*)  best_idx=1 ;;
  esac
  printf "%s" "$best_idx"
}

reviewed=0; deleted_candidates=0; low_threshold="${LOW_VALUE_THRESHOLD_BYTES:-}"

while IFS= read -r gid; do
  csv="$TMPDIR/g${gid}.csv"
  count="$(wc -l < "$csv" | tr -d '[:space:]')"
  total_bytes="$(awk -F',' '{s+=$1} END{print s+0}' "$csv")"
  gline="$(grep -E "^${gid}," "$GROUPS_META" | head -n1 || true)"
  ghash="$(printf "%s" "$gline" | awk -F',' '{print $2}')"
  def_idx="$(pick_index_by_policy "$csv" "$KEEP_POLICY")"

  if [[ "$NON_INTERACTIVE" == true ]]; then
    idx=0; while IFS=, read -r size mt path; do idx=$((idx+1)); (( idx != def_idx )) && { printf "%s\n" "$path" >> "$PLAN"; deleted_candidates=$((deleted_candidates+1)); }; done < "$csv"
    reviewed=$((reviewed+1)); continue
  fi

  if [[ "$QUIET" != true ]]; then
    echo
    printf "${c_blue}─ Group #%s — hash: %s — files: %s — total: %s${c_reset}\n" "$gid" "$ghash" "$count" "$(human "$total_bytes")"
    printf "  Default keep policy: %s (suggested: index %s)\n" "$KEEP_POLICY" "$def_idx"
    idx=0
    while IFS=, read -r size mt path; do
      idx=$((idx+1))
      tag=""
      if [[ -n "$low_threshold" && "$size" =~ ^[0-9]+$ ]] && (( size > 0 && size < low_threshold )); then tag=" [low]"; fi
      marker=" "; [[ "$idx" -eq "$def_idx" ]] && marker="*"
      printf "  %s %2d) %s  (%s)%s\n" "$marker" "$idx" "$path" "$(human "$size")" "$tag"
    done < "$csv"
    echo
  fi

  read -rp $'Choose keep [1..N], Enter=default, s=skip, q=quit: ' answer || true
  if [[ -z "${answer:-}" ]]; then keep_idx="$def_idx"
  else
    case "$answer" in
      q|Q) info "Stopping early at user request."; break ;;
      s|S) reviewed=$((reviewed+1)); continue ;;
      ''|*[!0-9]*) warn "Invalid input. Using default."; keep_idx="$def_idx" ;;
      *) keep_idx="$answer" ;;
    esac
  fi

  idx=0
  while IFS=, read -r size mt path; do
    idx=$((idx+1))
    if (( idx != keep_idx )); then
      printf "%s\n" "$path" >> "$PLAN"
      deleted_candidates=$((deleted_candidates+1))
    fi
  done < "$csv"

  reviewed=$((reviewed+1))
  if [[ -z "${TAKE:-}" && "$reviewed" -ge "$LIMIT" ]]; then
    warn "Reached interactive --limit=$LIMIT groups. Continue later with --skip $((SKIP+LIMIT)) to resume."
    break
  fi
done < "$TMPDIR/selected.ids"

if [[ -s "$PLAN" ]]; then
  cp -f "$PLAN" "$VAR_DIR/latest-plan.txt" || true
  {
    echo "Review summary — $timestamp"
    echo "Report: $FROM_REPORT"
    echo "Order: $ORDER  | Skip: $SKIP  | Take: ${TAKE:-all}  | Limit: $LIMIT  | Policy: $KEEP_POLICY  | Mode: $([[ "$NON_INTERACTIVE" == true ]] && echo 'non-interactive' || echo 'interactive')"
    echo "Groups parsed: $total_groups"
    echo "Groups reviewed: $reviewed"
    echo "Deletion candidates written: $deleted_candidates"
    echo "Plan: $PLAN"
    echo "Latest plan copy: $VAR_DIR/latest-plan.txt"
  } > "$SUMMARY"
  info "Plan written: $PLAN"
  info "Latest plan: $VAR_DIR/latest-plan.txt"
  $QUIET || info "Next: review the plan, then apply via menu option 6 (Delete duplicates)."
else
  warn "No deletion candidates were produced. Nothing written to plan."
fi

exit 0
