#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ───── Layout ─────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOG_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
VAR_DIR="$APP_HOME/var"
LOW_DIR="$VAR_DIR/low-value"
IDX_ROOT="$LOG_DIR/dups-index"

mkdir -p "$LOG_DIR" "$HASHES_DIR" "$VAR_DIR" "$LOW_DIR" "$IDX_ROOT"

# ───── Defaults & args ─────
ORDER="size"             # size|count
LIMIT=100
KEEP_POLICY="newest"     # newest|oldest|largest|smallest|first|last
NON_INTERACTIVE=false
REPORT=""
CONFIG_FILE=""
LOW_VALUE_THRESHOLD_BYTES=0

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ printf "[%s] [RUN %s] %s\n" "$(ts)" "$RUN_ID" "$*"; }

usage(){
  cat <<EOF
Usage: $0 --from-report FILE [options]
  --from-report FILE     Path to canonical duplicate report (logs/YYYY-MM-DD-duplicate-hashes.txt)
  --order size|count     Sort groups by total size (default) or by file count
  --limit N              Max groups to review interactively (default: 100). Ignored in --non-interactive
  --keep POLICY          Keep policy in non-interactive mode or default selection (newest|oldest|largest|smallest|first|last)
  --non-interactive      Apply policy across all groups with no prompts
  --config FILE          Load LOW_VALUE_THRESHOLD_BYTES
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT="${2:-}"; shift ;;
    --order) ORDER="${2:-}"; shift ;;
    --limit) LIMIT="${2:-}"; shift ;;
    --keep) KEEP_POLICY="${2:-}"; shift ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    --config) CONFIG_FILE="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

[ -n "$REPORT" ] || { echo "[ERROR] Missing --from-report"; usage; exit 2; }
[ -r "$REPORT" ] || { echo "[ERROR] Cannot read report: $REPORT"; exit 2; }

# ───── Ensure real TTY for prompts ─────
if ! [ -t 0 ] || ! [ -t 1 ]; then
  if [ -r /dev/tty ]; then
    exec </dev/tty >/dev/tty 2>/dev/tty
  else
    NON_INTERACTIVE=true
  fi
fi

# ───── Load config (simple k=v) ─────
load_conf(){
  local f="$1"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      *=*)
        key="${line%%=*}"; val="${line#*=}"
        key="$(echo "$key" | tr -d '[:space:]')"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
          LOW_VALUE_THRESHOLD_BYTES) LOW_VALUE_THRESHOLD_BYTES="$val" ;;
        esac
        ;;
    esac
  done < "$f"
}
[ -z "$CONFIG_FILE" ] && [ -r "$APP_HOME/local/hasher.conf" ] && CONFIG_FILE="$APP_HOME/local/hasher.conf"
[ -z "$CONFIG_FILE" ] && [ -r "$APP_HOME/default/hasher.conf" ] && CONFIG_FILE="$APP_HOME/default/hasher.conf"
[ -n "$CONFIG_FILE" ] && load_conf "$CONFIG_FILE"

# ───── Canonical report guard ─────
if ! grep -Eq '^HASH[[:space:]][^[:space:]]+[[:space:]]+\([0-9]+[[:space:]]+files\):' "$REPORT"; then
  echo "[ERROR] '$REPORT' is not a canonical duplicate-hashes report (expects 'HASH <digest> (<n> files):')."
  cand="$(ls -1t "$(dirname "$REPORT")"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  [ -n "$cand" ] && echo "[SUGGEST] Try: $0 --from-report \"$cand\""
  exit 2
fi

# ───── Run ID ─────
if command -v uuidgen >/dev/null 2>&1; then
  RUN_ID="$(uuidgen)"
elif [ -r /proc/sys/kernel/random/uuid ]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$"
fi

# ───── Helpers ─────
human(){
  awk -v b="${1:-0}" 'BEGIN{ split("B,KB,MB,GB,TB,PB",u,","); s=0;
    while (b>=1024 && s<5){b/=1024;s++}
    printf (s? "%.1f %s":"%d %s"), b, u[s+1];
  }'
}
mtime_of(){ stat -c %Y -- "$1" 2>/dev/null || echo 0; }
size_of(){  stat -c %s -- "$1" 2>/dev/null || echo 0; }
strip_quotes(){ local p="$1"; p="${p%\"}"; p="${p#\"}"; printf '%s\n' "$p"; }

# ───── Parse report to temp index (progress printed) ─────
TOTAL_DECLARED_GROUPS="$(grep -c '^HASH ' "$REPORT" || echo 0)"
echo "[INFO] Parsing report… groups declared: $TOTAL_DECLARED_GROUPS"

IDX_DIR="$IDX_ROOT/$RUN_ID"
rm -rf "$IDX_DIR" && mkdir -p "$IDX_DIR"
GROUPS_FILE="$IDX_DIR/groups.tsv"   # idx \t hash \t count \t rep_size \t total_size \t files_list_path
: > "$GROUPS_FILE"

PARSED=0; FILES_SEEN=0; START=$(date +%s); STEP=200
cur_hash=""; cur_files_path="$IDX_DIR/tmp_files.txt"; : > "$cur_files_path"

progress(){
  now=$(date +%s); elapsed=$((now-START))
  if [ "$PARSED" -gt 0 ] && [ "$TOTAL_DECLARED_GROUPS" -gt 0 ]; then
    pct=$(( PARSED * 100 / TOTAL_DECLARED_GROUPS )); eta=$(( elapsed * (TOTAL_DECLARED_GROUPS - PARSED) / PARSED ))
  else
    pct=0; eta=0
  fi
  printf "... Report groups parsed: %d/%d (%d%%) (files seen: %d) | elapsed=%02d:%02d:%02d eta=%02d:%02d:%02d\n" \
    "$PARSED" "$TOTAL_DECLARED_GROUPS" "$pct" "$FILES_SEEN" \
    $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
    $((eta/3600)) $((eta%3600/60)) $((eta%60))
}

flush_group(){
  if [ -n "$cur_hash" ]; then
    sed -i '/^[[:space:]]*$/d' "$cur_files_path" || true
    local n; n=$(wc -l < "$cur_files_path" | tr -d ' ')
    if [ "$n" -gt 1 ]; then
      local first; first="$(strip_quotes "$(head -n1 "$cur_files_path")")"
      local rep_size; rep_size="$(size_of "$first")"
      local total_size=$(( rep_size * n ))
      local list_path="$IDX_DIR/g$(printf '%06d' "$PARSED").lst"
      awk '{gsub(/^ *"|" *$/,"",$0); print $0}' "$cur_files_path" > "$list_path"
      printf '%d\t%s\t%d\t%d\t%d\t%s\n' "$PARSED" "$cur_hash" "$n" "$rep_size" "$total_size" "$list_path" >> "$GROUPS_FILE"
      FILES_SEEN=$((FILES_SEEN+n))
    fi
    : > "$cur_files_path"
    PARSED=$((PARSED+1))
    if [ $(( PARSED % STEP )) -eq 0 ]; then progress; fi
  fi
  cur_hash=""
}

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^HASH[[:space:]]+([0-9A-Fa-f]+)[[:space:]]+\(([0-9]+)[[:space:]]+files\): ]]; then
    flush_group
    cur_hash="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^[[:space:]]{2}(.+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" >> "$cur_files_path"
  else
    :
  fi
done < "$REPORT"
flush_group
progress

TOTAL_GROUPS="$(wc -l < "$GROUPS_FILE" | tr -d ' ')"
if [ "$TOTAL_GROUPS" -le 0 ]; then
  echo "[INFO] No usable duplicate groups found in: $REPORT"
  exit 0
fi

# ───── Order groups ─────
ORDERED_IDX_FILE="$IDX_DIR/ordered.idx"
if [ "$ORDER" = "count" ]; then
  awk -F'\t' '{printf "%d\t%d\n",$1,$3}' "$GROUPS_FILE" | sort -k2,2nr | awk '{print $1}' > "$ORDERED_IDX_FILE"
else # size
  awk -F'\t' '{printf "%d\t%d\n",$1,$5}' "$GROUPS_FILE" | sort -k2,2nr | awk '{print $1}' > "$ORDERED_IDX_FILE"
fi

# Load indices robustly
readarray -t IDX_ARR < "$ORDERED_IDX_FILE" 2>/dev/null || IDX_ARR=()
if [ "${#IDX_ARR[@]}" -eq 0 ]; then
  echo "[ERROR] Failed to load ordered indices (empty list)."
  echo "[DEBUG] GROUPS_FILE lines: $(wc -l < "$GROUPS_FILE" | tr -d ' ')"
  echo "[DEBUG] ORDERED_IDX_FILE size: $(stat -c %s "$ORDERED_IDX_FILE" 2>/dev/null || echo 0)"
  exit 2
fi

# ───── Low-value diversion, plan path ─────
DATE_TAG="$(date +%F)"
PLAN_FILE="$LOG_DIR/review-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
LOW_LIST="$LOW_DIR/low-value-candidates-$DATE_TAG-$RUN_ID.txt"
: > "$PLAN_FILE"; : > "$LOW_LIST"

log "[INFO] Index ready. Starting review…"
log "[INFO]   • Ordering:     $ORDER desc"
log "[INFO]   • Limit:        $LIMIT"
log "[INFO]   • Groups:       $TOTAL_GROUPS total"
log "[INFO]   • Plan:         $PLAN_FILE"

# ───── Prompt keep (reads from per-group list path) ─────
prompt_keep(){
  local list="$1"
  local n; n=$(wc -l < "$list" | tr -d ' ')
  [ "$n" -ge 2 ] || return 2

  local rep; rep="$(head -n1 "$list")"; rep="$(strip_quotes "$rep")"
  local rep_size; rep_size="$(size_of "$rep")"
  local size_human; size_human="$(human "$rep_size")"
  local reclaim=$(( (n-1) * rep_size )); local reclaim_h; reclaim_h="$(human "$reclaim")"

  echo "[${REVIEW_POS}/${REVIEW_MAX}] Size: ${size_human}  |  Files: ${n}  |  Potential reclaim: ${reclaim_h}"

  # Show first 12 entries
  local k=0
  while IFS= read -r f; do
    f="$(strip_quotes "$f")"; k=$((k+1))
    if [ "$k" -le 12 ]; then
      local ts; ts="$(mtime_of "$f")"
      if date -d "@$ts" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then ts_fmt="$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S")"; else ts_fmt="$ts"; fi
      printf "    %2d) %-10s  \"%s\"\n" "$k" "$size_human" "$f"
      printf "        modified: %s\n" "$ts_fmt"
    fi
  done < "$list"
  if [ "$n" -gt 12 ]; then
    echo "        … and $((n-12)) more not shown"
  fi

  # Default keep per policy
  local def_keep=1
  case "$KEEP_POLICY" in
    newest)
      def_keep_line=$(awk '{print NR"\t"$0}' "$list" | while IFS=$'\t' read -r nr p; do ts=$(stat -c %Y -- "$p" 2>/dev/null || echo 0); echo -e "$ts\t$nr"; done | sort -k1,1nr | head -n1 | awk '{print $2}')
      [ -n "$def_keep_line" ] && def_keep="$def_keep_line"
      ;;
    oldest)
      def_keep_line=$(awk '{print NR"\t"$0}' "$list" | while IFS=$'\t' read -r nr p; do ts=$(stat -c %Y -- "$p" 2>/dev/null || echo 0); echo -e "$ts\t$nr"; done | sort -k1,1n | head -n1 | awk '{print $2}')
      [ -n "$def_keep_line" ] && def_keep="$def_keep_line"
      ;;
    largest)
      def_keep_line=$(awk '{print NR"\t"$0}' "$list" | while IFS=$'\t' read -r nr p; do sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0); echo -e "$sz\t$nr"; done | sort -k1,1nr | head -n1 | awk '{print $2}')
      [ -n "$def_keep_line" ] && def_keep="$def_keep_line"
      ;;
    smallest)
      def_keep_line=$(awk '{print NR"\t"$0}' "$list" | while IFS=$'\t' read -r nr p; do sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0); echo -e "$sz\t$nr"; done | sort -k1,1n | head -n1 | awk '{print $2}')
      [ -n "$def_keep_line" ] && def_keep="$def_keep_line"
      ;;
    last) def_keep="$n" ;;
    first|*) def_keep=1 ;;
  esac

  local ans
  if $NON_INTERACTIVE; then
    ans="$def_keep"
  else
    read -r -p "Select the file ID to KEEP [1-$n], 's' to skip, 'q' to quit (default: $def_keep): " ans || ans=""
  fi

  case "${ans:-$def_keep}" in
    q|Q) echo "Quitting."; exit 0 ;;
    s|S) echo "  → Skipped."; return 2 ;;
    ''|*[!0-9]*) keep="$def_keep" ;;
    *) keep="$ans" ;;
  esac

  if [ "$keep" -lt 1 ] || [ "$keep" -gt "$n" ]; then
    echo "Invalid selection. Skipping group."
    return 2
  fi

  awk -v keep="$keep" 'NR!=keep{print $0}' "$list" >> "$PLAN_FILE"
  echo "  → Keep: \"$(sed -n "${keep}p" "$list")\""
  return 0
}

# ───── Review loop ─────
REVIEW_MAX="$LIMIT"; $NON_INTERACTIVE && REVIEW_MAX="$TOTAL_GROUPS"
reviewed=0

for idx in "${IDX_ARR[@]}"; do
  [ "$reviewed" -ge "$REVIEW_MAX" ] && break
  meta=$(awk -F'\t' -v i="$idx" '($1==i){print $0}' "$GROUPS_FILE")
  [ -z "$meta" ] && continue
  list_path="$(echo "$meta" | awk -F'\t' '{print $6}')"

  # Low-value diversion (all files <= threshold)
  lv_divert=1
  if [ "$LOW_VALUE_THRESHOLD_BYTES" -le 0 ]; then
    while IFS= read -r f; do sz=$(stat -c %s -- "$f" 2>/dev/null || echo 0); if [ "$sz" -gt 0 ]; then lv_divert=0; break; fi; done < "$list_path"
  else
    while IFS= read -r f; do sz=$(stat -c %s -- "$f" 2>/dev/null || echo 0); if [ "$sz" -gt "$LOW_VALUE_THRESHOLD_BYTES" ]; then lv_divert=0; break; fi; done < "$list_path"
  fi
  if [ "$lv_divert" -eq 1 ]; then
    cat "$list_path" >> "$LOW_LIST"
    continue
  fi

  reviewed=$((reviewed+1)); REVIEW_POS="$reviewed"

  # ── spacing for readability (inserted) ──
  echo
  echo

  prompt_keep "$list_path" || true

  # ── spacing for readability (inserted) ──
  echo
  echo

done

log "[INFO] Plan written: $PLAN_FILE"
log "[INFO] Next steps:"
log "[INFO]   • Dry-run: ./bin/delete-duplicates.sh --from-plan \"$PLAN_FILE\""
log "[INFO]   • Execute: ./bin/delete-duplicates.sh --from-plan \"$PLAN_FILE\" --force [--quarantine DIR]"
log "[INFO]   • Low-value candidates, if any, saved to: $LOW_LIST"
