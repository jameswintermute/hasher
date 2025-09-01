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

# ───────────────────────── Ensure interactive stdin ─────────────────
# If called from a wrapper (e.g., launcher) where stdin isn't a TTY,
# reattach to /dev/tty so `read` prompts work. If not possible, fallback to non-interactive.
if ! [ -t 0 ]; then
  if [ -r /dev/tty ]; then
    exec </dev/tty || true
  else
    NON_INTERACTIVE=true
  fi
fi

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
[ -z "$CONFIG_FILE" ] && [ -r "$APP_HOME/local/hasher.conf" ] && CONFIG_FILE="$APP_HOME/local/hasher.conf"
[ -z "$CONFIG_FILE" ] && [ -r "$APP_HOME/default/hasher.conf" ] && CONFIG_FILE="$APP_HOME/default/hasher.conf"
[ -n "$CONFIG_FILE" ] && load_conf "$CONFIG_FILE"

# ───────────────────────── Canonical report guard ───────────────────
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
  awk -v b="${1:-0}" 'BEGIN{
    split("B,KB,MB,GB,TB,PB",u,","); s=0;
    while (b>=1024 && s<5){b/=1024;s++}
    printf (s? "%.1f %s":"%d %s"), b, u[s+1];
  }'
}

mtime_of(){ stat -c %Y -- "$1" 2>/dev/null || echo 0; }
size_of(){  stat -c %s -- "$1" 2>/dev/null || echo 0; }

strip_quotes(){ local p="$1"; p="${p%\"}"; p="${p#\"}"; printf '%s\n' "$p"; }

# ───────────────────────── Parse report into groups (with progress) ─
declare -a GROUP_HASHES=()
declare -a GROUP_FILES_COUNTS=()
declare -a GROUP_TOTAL_SIZES=()
declare -A GROUP_FILES_MAP=()
declare -a GROUP_FILE_SIZE=()

TOTAL_DECLARED_GROUPS="$(grep -c '^HASH ' "$REPORT" || echo 0)"
say "[INFO] Parsing report… groups declared: $TOTAL_DECLARED_GROUPS"
PARSED_GROUPS=0
FILES_SEEN=0
PARSE_START="$(date +%s)"
PROG_STEP=200   # print a progress line every N groups

current_hash=""
current_files=()

progress_line(){
  local now elapsed eta pct
  now="$(date +%s)"; elapsed=$(( now - PARSE_START ))
  if [ "$PARSED_GROUPS" -gt 0 ] && [ "$TOTAL_DECLARED_GROUPS" -gt 0 ]; then
    pct=$(( PARSED_GROUPS * 100 / TOTAL_DECLARED_GROUPS ))
    eta=$(( elapsed * (TOTAL_DECLARED_GROUPS - PARSED_GROUPS) / PARSED_GROUPS ))
  else
    pct=0; eta=0
  fi
  printf "... Report groups parsed: %d/%d (%d%%) (files seen: %d) | elapsed=%02d:%02d:%02d eta=%02d:%02d:%02d\n" \
    "$PARSED_GROUPS" "$TOTAL_DECLARED_GROUPS" "$pct" "$FILES_SEEN" \
    $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
    $((eta/3600)) $((eta%3600/60)) $((eta%60))
}

flush_group(){
  if [ -n "$current_hash" ] && [ "${#current_files[@]}" -gt 1 ]; then
    local idx="${#GROUP_HASHES[@]}"
    GROUP_HASHES+=("$current_hash")
    local first="$(strip_quotes "${current_files[0]}")"
    local rep_size; rep_size="$(size_of "$first")"
    local total_size=$(( rep_size * ${#current_files[@]} ))
    GROUP_FILES_COUNTS+=("${#current_files[@]}")
    GROUP_TOTAL_SIZES+=("$total_size")
    GROUP_FILE_SIZE+=("$rep_size")
    # store NUL-joined
    local joined=""
    for f in "${current_files[@]}"; do
      joined+="$(strip_quotes "$f")"$'\0'
    done
    GROUP_FILES_MAP["$idx"]="$joined"
  fi
  if [ -n "$current_hash" ]; then
    PARSED_GROUPS=$((PARSED_GROUPS+1))
    FILES_SEEN=$((FILES_SEEN + ${#current_files[@]}))
    if [ $(( PARSED_GROUPS % PROG_STEP )) -eq 0 ]; then
      progress_line
    fi
  fi
  current_hash=""
  current_files=()
}

# Read & parse
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^HASH[[:space:]]+([0-9A-Fa-f]+)[[:space:]]+\(([0-9]+)[[:space:]]+files\): ]]; then
    flush_group
    current_hash="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^[[:space:]]{2}(.+) ]]; then
    current_files+=("${BASH_REMATCH[1]}")
  else
    :
  fi
done < "$REPORT"
flush_group
progress_line

TOTAL_GROUPS="${#GROUP_HASHES[@]}"
if [ "$TOTAL_GROUPS" -le 0 ]; then
  echo "[INFO] No duplicate groups found in: $REPORT"
  exit 0
fi

# ───────────────────────── Sort groups per ORDER ────────────────────
declare -a ORDER_IDX=()
for ((i=0;i<TOTAL_GROUPS;i++)); do ORDER_IDX+=("$i"); done

if [ "$ORDER" = "count" ]; then
  IFS=$'\n' ORDER_IDX=($(for i in "${ORDER_IDX[@]}"; do echo "$i ${GROUP_FILES_COUNTS[$i]}"; done | sort -k2,2nr | awk '{print $1}'))
else
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

human_size_of_file(){
  local f="$1"; local sz; sz="$(size_of "$f")"; human "$sz"
}

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

  declare -a mtimes=()
  for ((k=0;k<n;k++)); do mtimes+=("$(mtime_of "${files[$k]}")"); done

  local def_keep=0
  case "$KEEP_POLICY" in
    newest)   local max=0 idx=0; for ((k=0;k<n;k++)); do [ "${mtimes[$k]}" -gt "$max" ] && { max="${mtimes[$k]}"; idx="$k"; }; done; def_keep="$idx" ;;
    oldest)   local min=9999999999 idx=0; for ((k=0;k<n;k++)); do [ "${mtimes[$k]}" -lt "$min" ] && { min="${mtimes[$k]}"; idx="$k"; }; done; def_keep="$idx" ;;
    largest)  local max=0 idx=0; for ((k=0;k<n;k++)); do sz="$(size_of "${files[$k]}")"; [ "$sz" -gt "$max" ] && { max="$sz"; idx="$k"; }; done; def_keep="$idx" ;;
    smallest) local min=999999999999 idx=0; for ((k=0;k<n;k++)); do sz="$(size_of "${files[$k]}")"; [ "$sz" -lt "$min" ] && { min="$sz"; idx="$k"; }; done; def_keep="$idx" ;;
    last) def_keep=$((n-1)) ;;
    first|*) def_keep=0 ;;
  esac

  local show=12
  for ((k=0;k<n && k<show;k++)); do
    local ts="${mtimes[$k]}"
    if date -d "@$ts" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
      ts_fmt="$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S")"
    else
      ts_fmt="$ts"
    fi
    printf "    %2d) %-10s  \"%s\"\n" "$(($k+1))" "$size_human" "${files[$k]}"
    printf "        modified: %s\n" "$ts_fmt"
  done
  if [ "$n" -gt "$show" ]; then
    echo "        … and $((n-show)) more not shown"
  fi

  if $NON_INTERACTIVE; then
    keep="$((def_keep+1))"
  else
    # Use read in a conditional to avoid 'set -e' exit on non-zero (e.g., no TTY)
    if ! read -rp "Select the file ID to KEEP [1-$n], 's' to skip, 'q' to quit (default: $((def_keep+1))): " ans; then
      ans=""
    fi
    case "${ans:-$((def_keep+1))}" in
      q|Q) echo "Quitting."; exit 0 ;;
      s|S) echo "  → Skipped."; return 2 ;;
      ''|*[!0-9]*) keep="$((def_keep+1))" ;;
      *) keep="$ans" ;;
    esac
  fi

  if [ "$keep" -lt 1 ] || [ "$keep" -gt "$n" ]; then
    echo "Invalid selection. Skipping group."
    return 2
  fi

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
$NON_INTERACTIVE && REVIEW_MAX="$TOTAL_GROUPS"

reviewed=0
for i in "${ORDER_IDX[@]}"; do
  [ "$reviewed" -ge "$REVIEW_MAX" ] && break
  files_joined="${GROUP_FILES_MAP[$i]}"
  IFS=$'\0' read -r -d '' -a files <<< "${files_joined}"$'\0'
  n="${#files[@]}"

  # Divert low-value groups (all files <= threshold) to LOW_LIST
  lv_divert=true
  if [ "$LOW_VALUE_THRESHOLD_BYTES" -le 0 ]; then
    for f in "${files[@]}"; do
      sz="$(size_of "$f")"; if [ "$sz" -gt 0 ]; then lv_divert=false; break; fi
    done
  else
    for f in "${files[@]}"; do
      sz="$(size_of "$f")"; if [ "$sz" -gt "$LOW_VALUE_THRESHOLD_BYTES" ]; then lv_divert=false; break; fi
    done
  fi
  if $lv_divert; then
    for f in "${files[@]}"; do printf '%s\n' "$f" >> "$LOW_LIST"; done
    continue
  fi

  reviewed=$((reviewed+1))
  REVIEW_POS="$reviewed"
  prompt_keep "$i" || { continue; }
done

# ───────────────────────── Summary & next steps ─────────────────────
say "[RUN $RUN_ID] [INFO] Plan written: $PLAN_FILE"
say "[RUN $RUN_ID] [INFO] Next steps:"
say "[RUN $RUN_ID] [INFO]   • Dry-run: ./bin/delete-duplicates.sh --from-plan \"$PLAN_FILE\""
say "[RUN $RUN_ID] [INFO]   • Execute: ./bin/delete-duplicates.sh --from-plan \"$PLAN_FILE\" --force [--quarantine DIR]"
say "[RUN $RUN_ID] [INFO]   • Low-value candidates, if any, saved to: $LOW_LIST"

exit 0
