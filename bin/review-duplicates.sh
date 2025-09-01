\
#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ───────────────────────── Layout discovery ─────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Assume this file lives in .../bin/
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOG_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
VAR_DIR="$APP_HOME/var"
LOW_DIR="$VAR_DIR/low-value"

mkdir -p "$LOG_DIR" "$HASHES_DIR" "$VAR_DIR" "$LOW_DIR"

# Optional shared path helpers
if [ -r "$BIN_DIR/lib_paths.sh" ]; then
  . "$BIN_DIR/lib_paths.sh" 2>/dev/null || true
fi

# ───────────────────────── Defaults & args ─────────────────────────
ORDER="size"             # size|count
LIMIT=100                # number of groups to review (interactive)
KEEP_POLICY="newest"     # newest|oldest|largest|smallest|first|last
NON_INTERACTIVE=false
REPORT=""                # logs/YYYY-MM-DD-duplicate-hashes.txt
CONFIG_FILE=""
LOW_VALUE_THRESHOLD_BYTES=0

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
say(){ printf "[%s] %s\n" "$(ts)" "$*"; }

usage(){
  cat <<EOF
Usage: $0 --from-report FILE [options]

Options:
  --from-report FILE     Path to canonical duplicate report (logs/YYYY-MM-DD-duplicate-hashes.txt)
  --order size|count     Sort groups by total size (default) or by file count
  --limit N              Max groups to review interactively (default: 100). Ignored in --non-interactive
  --keep POLICY          Keep policy in non-interactive mode or default selection (newest|oldest|largest|smallest|first|last)
  --non-interactive      Do not prompt; apply --keep POLICY across all groups
  --config FILE          Load thresholds (LOW_VALUE_THRESHOLD_BYTES=...)

Examples:
  $0 --from-report "logs/2025-09-01-duplicate-hashes.txt" --keep newest
  $0 --from-report "logs/2025-09-01-duplicate-hashes.txt" --non-interactive --keep newest
EOF
}

while [[ $# -gt 0 ]]; do
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

# ───────────────────────── Load config (simple k=v) ─────────────────
load_conf(){
  local f="$1"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
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
# Prefer local override then default
[ -z "$CONFIG_FILE" ] && [ -r "$APP_HOME/local/hasher.conf" ] && CONFIG_FILE="$APP_HOME/local/hasher.conf"
[ -z "$CONFIG_FILE" ] && [ -r "$APP_HOME/default/hasher.conf" ] && CONFIG_FILE="$APP_HOME/default/hasher.conf"
[ -n "$CONFIG_FILE" ] && load_conf "$CONFIG_FILE"

# ───────────────────────── Canonical report guard ───────────────────
# Expect lines like:  HASH <digest> (<N> files):
if ! grep -Eq '^HASH[[:space:]][^[:space:]]+[[:space:]]+\([0-9]+[[:space:]]+files\):' "$REPORT"; then
  echo "[ERROR] '$REPORT' doesn't look like a canonical duplicate-hashes report."
  case "$REPORT" in
    *-nonlow-*.txt|*-low-*.txt)
      echo "[HINT] This appears to be a filtered summary (nonlow/low). Use the full report named like:"
      echo "       logs/YYYY-MM-DD-duplicate-hashes.txt"
      ;;
  esac
  _cand="$(ls -1t "$(dirname "$REPORT")"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [ -n "$_cand" ]; then
    echo "[SUGGEST] Try: $0 --from-report \"$_cand\""
  fi
  exit 2
fi

# ───────────────────────── Utilities ────────────────────────────────
human(){
  # bytes → human
  awk -v b="${1:-0}" 'BEGIN{
    split("B,KB,MB,GB,TB,PB",u,","); s=0;
    while (b>=1024 && s<5){b/=1024;s++}
    printf (s? "%.1f %s":"%d %s"), b, u[s+1];
  }'
}

mtime_of(){
  stat -c %Y -- "$1" 2>/dev/null || echo 0
}

size_of(){
  stat -c %s -- "$1" 2>/dev/null || echo 0
}

basename_safe(){
  # prints base path (without quotes issues)
  local p="$1"; p="${p%\"}"; p="${p#\"}"; printf '%s\n' "$p"
}

# ───────────────────────── Parse report into groups ─────────────────
# We need: groups[]=hash, files for each; compute size (from filesystem) and mtimes
declare -a GROUP_HASHES=()
declare -a GROUP_FILES_COUNTS=()
declare -a GROUP_TOTAL_SIZES=()
declare -A GROUP_FILES_MAP=()   # key = index, value = NUL-separated files
declare -a GROUP_FILE_SIZE=()   # per-group representative file size (assume duplicates same size)

current_hash=""
current_files=()

flush_group(){
  if [ -n "$current_hash" ] && [ "${#current_files[@]}" -gt 1 ]; then
    local idx="${#GROUP_HASHES[@]}"
    GROUP_HASHES+=("$current_hash")
    # Compute representative size as size of first file
    local first="${current_files[0]}"
    first="$(basename_safe "$first")"
    local rep_size; rep_size="$(size_of "$first")"
    local total_size=$(( rep_size * ${#current_files[@]} ))
    GROUP_FILES_COUNTS+=("${#current_files[@]}")
    GROUP_TOTAL_SIZES+=("$total_size")
    GROUP_FILE_SIZE+=("$rep_size")
    # Store NUL-separated paths
    local joined=""
    for f in "${current_files[@]}"; do
      f="$(basename_safe "$f")"
      joined+="$f"$'\0'
    done
    GROUP_FILES_MAP["$idx"]="$joined"
  fi
  current_hash=""
  current_files=()
}

# Read report
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^HASH[[:space:]]+([0-9A-Fa-f]+)[[:space:]]+\(([0-9]+)[[:space:]]+files\): ]]; then
    flush_group
    current_hash="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^[[:space:]]{2}(.+) ]]; then
    # indented file path line
    current_files+=("${BASH_REMATCH[1]}")
  else
    # empty separator lines ignored
    :
  fi
done < "$REPORT"
flush_group

TOTAL_GROUPS="${#GROUP_HASHES[@]}"
[ "$TOTAL_GROUPS" -gt 0 ] || { echo "[INFO] No duplicate groups found in: $REPORT"; exit 0; }

# ───────────────────────── Sort groups per ORDER ────────────────────
# We'll build an index ORDER_IDX[] of group indices in desired order
declare -a ORDER_IDX=()
for ((i=0;i<TOTAL_GROUPS;i++)); do ORDER_IDX+=("$i"); done

if [ "$ORDER" = "count" ]; then
  # sort by files count desc
  IFS=$'\n' ORDER_IDX=($(for i in "${ORDER_IDX[@]}"; do echo "$i ${GROUP_FILES_COUNTS[$i]}"; done | sort -k2,2nr | awk '{print $1}'))
else
  # default: sort by total size desc
  IFS=$'\n' ORDER_IDX=($(for i in "${ORDER_IDX[@]}"; do echo "$i ${GROUP_TOTAL_SIZES[$i]}"; done | sort -k2,2nr | awk '{print $1}'))
fi
unset IFS

# ───────────────────────── Low-value diversion ──────────────────────
RUN_ID="$(date +%s)-$$"
DATE_TAG="$(date +%F)"
PLAN_FILE="$LOG_DIR/review-dedupe-plan-$DATE_TAG-$RUN_ID.txt"
LOW_LIST="$LOW_DIR/low-value-candidates-$DATE_TAG-$RUN_ID.txt"
: > "$PLAN_FILE"
: > "$LOW_LIST"

say "[RUN $RUN_ID] [INFO] Index ready. Starting review…"
say "[RUN $RUN_ID] [INFO]   • Ordering:     $ORDER desc"
say "[RUN $RUN_ID] [INFO]   • Limit:        $LIMIT"
say "[RUN $RUN_ID] [INFO]   • Groups:       $TOTAL_GROUPS total"
say "[RUN $RUN_ID] [INFO]   • Plan:         $PLAN_FILE"

diverted_low=0
kept_count=0
skipped_count=0

prompt_keep(){
  local group_idx="$1"
  local files_joined="${GROUP_FILES_MAP[$group_idx]}"
  IFS=$'\0' read -r -d '' -a files <<< "${files_joined}"$'\0'

  local n="${#files[@]}"
  local rep_size="${GROUP_FILE_SIZE[$group_idx]}"
  local size_human; size_human="$(human "$rep_size")"
  local reclaim=$(( (n-1) * rep_size ))
  local reclaim_h; reclaim_h="$(human "$reclaim")"

  echo "[${REVIEW_POS}/${REVIEW_MAX}] Size: ${size_human}  |  Files: ${n}  |  Potential reclaim: ${reclaim_h}"

  # Compute mtimes for policy decisions
  declare -a mtimes=()
  for ((k=0;k<n;k++)); do
    mtimes+=("$(mtime_of "${files[$k]}")")
  done

  # Decide default keep candidate based on policy
  local def_keep=0
  case "$KEEP_POLICY" in
    newest)   # keep highest mtime
      local max=0 idx=0
      for ((k=0;k<n;k++)); do if [ "${mtimes[$k]}" -gt "$max" ]; then max="${mtimes[$k]}"; idx="$k"; fi; done
      def_keep="$idx" ;;
    oldest)   # keep lowest mtime
      local min=9999999999 idx=0
      for ((k=0;k<n;k++)); do if [ "${mtimes[$k]}" -lt "$min" ]; then min="${mtimes[$k]}"; idx="$k"; fi; done
      def_keep="$idx" ;;
    largest)  # same size by definition; fallback to newest
      local max=0 idx=0
      for ((k=0;k<n;k++)); do if [ "${mtimes[$k]}" -gt "$max" ]; then max="${mtimes[$k]}"; idx="$k"; fi; done
      def_keep="$idx" ;;
    smallest) # same size; fallback to oldest
      local min=9999999999 idx=0
      for ((k=0;k<n;k++)); do if [ "${mtimes[$k]}" -lt "$min" ]; then min="${mtimes[$k]}"; idx="$k"; fi; done
      def_keep="$idx" ;;
    last) def_keep=$((n-1)) ;;
    first|*) def_keep=0 ;;
  esac

  # Show choices (up to 12 paths to avoid massive spam)
  local show=12
  for ((k=0;k<n && k<show;k++)); do
    local ts="${mtimes[$k]}"
    [ "$ts" -gt 0 ] && ts_fmt="$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ts")" || ts_fmt="unknown"
    printf "    %2d) %-10s  \"%s\"\n" "$(($k+1))" "$size_human" "${files[$k]}"
    printf "        modified: %s\n" "$ts_fmt"
  done
  if [ "$n" -gt "$show" ]; then
    echo "        … and $((n-show)) more not shown"
  fi

  if $NON_INTERACTIVE; then
    keep="$((def_keep+1))"
  else
    read -rp "Select the file ID to KEEP [1-$n], 's' to skip, 'q' to quit (default: $((def_keep+1))): " ans
    case "${ans:-$((def_keep+1))}" in
      q|Q) echo "Quitting."; exit 0 ;;
      s|S) echo "  → Skipped."; return 2 ;;
      ''|*[!0-9]*) keep="$((def_keep+1))" ;;
      *) keep="$ans" ;;
    esac
  fi

  # Validate keep
  if [ "$keep" -lt 1 ] || [ "$keep" -gt "$n" ]; then
    echo "Invalid selection. Skipping group."
    return 2
  fi

  # Emit plan (delete all except the kept one)
  local kept_path="${files[$((keep-1))]}"
  for ((k=0;k<n;k++)); do
    if [ "$k" -ne $((keep-1)) ]; then
      printf '%s\n' "${files[$k]}" >> "$PLAN_FILE"
    fi
  done
  echo "  → Keep: \"$kept_path\""
  return 0
}

# ───────────────────────── Review loop ──────────────────────────────
REVIEW_MAX="$LIMIT"
if $NON_INTERACTIVE; then REVIEW_MAX="$TOTAL_GROUPS"; fi

reviewed=0
for i in "${ORDER_IDX[@]}"; do
  # Enforce limit
  if [ "$reviewed" -ge "$REVIEW_MAX" ]; then break; fi

  files_joined="${GROUP_FILES_MAP[$i]}"
  IFS=$'\0' read -r -d '' -a files <<< "${files_joined}"$'\0'
  n="${#files[@]}"
  rep_size="${GROUP_FILE_SIZE[$i]}"

  # Divert low-value groups (all files <= threshold) to LOW_LIST
  lv_divert=true
  if [ "$LOW_VALUE_THRESHOLD_BYTES" -le 0 ]; then
    # threshold 0 => only zero-byte groups are "low"
    for f in "${files[@]}"; do
      sz="$(size_of "$f")"
      if [ "$sz" -gt 0 ]; then lv_divert=false; break; fi
    done
  else
    for f in "${files[@]}"; do
      sz="$(size_of "$f")"
      if [ "$sz" -gt "$LOW_VALUE_THRESHOLD_BYTES" ]; then lv_divert=false; break; fi
    done
  fi

  if $lv_divert; then
    for f in "${files[@]}"; do printf '%s\n' "$f" >> "$LOW_LIST"; done
    diverted_low=$((diverted_low+1))
    continue
  fi

  reviewed=$((reviewed+1))
  REVIEW_POS="$reviewed"
  prompt_keep "$i" || { skipped_count=$((skipped_count+1)); continue; }
  kept_count=$((kept_count+1))
done

# ───────────────────────── Summary & next steps ─────────────────────
say "[RUN $RUN_ID] [INFO] Plan written: $PLAN_FILE"
say "[RUN $RUN_ID] [INFO] Next steps:"
say "[RUN $RUN_ID] [INFO]   • Dry-run: ./bin/delete-duplicates.sh --from-plan \"$PLAN_FILE\""
say "[RUN $RUN_ID] [INFO]   • Execute: ./bin/delete-duplicates.sh --from-plan \"$PLAN_FILE\" --force [--quarantine DIR]"
say "[RUN $RUN_ID] [INFO]   • Low-value candidates, if any, saved to: $LOW_LIST"

exit 0
