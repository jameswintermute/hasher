#!/usr/bin/env bash
# find-duplicates.sh — group duplicate files by hash using hasher CSV output
# Now with a BusyBox-friendly progress bar while parsing the CSV.
# License: GPLv3
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"

HASHES_DIR="$APP_HOME/hashes"
LOGS_DIR="$APP_HOME/logs"
VAR_DIR="$APP_HOME/var/duplicates"
mkdir -p "$LOGS_DIR" "$VAR_DIR"

# Colours
c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

usage() {
  cat <<'EOF'
Usage: find-duplicates.sh [--input CSV] [--mode standard|bulk]
                          [--min-group-size N] [--keep-strategy shortest-path|oldest|newest|first]
Outputs:
  - Canonical: logs/YYYY-MM-DD-duplicate-hashes.txt   (for review-duplicates.sh --from-report)
  - Summary:   logs/duplicate-groups-YYYY-MM-DD-HHMMSS.txt
  - Flat CSV:  logs/duplicates-YYYY-MM-DD-HHMMSS.csv
Bulk mode also writes:
  - Plan:      logs/review-dedupe-plan-YYYY-MM-DD-HHMMSS.txt
EOF
}

INPUT=""
MODE="standard"        # standard | bulk
MIN_GROUP=2
KEEP_STRATEGY="shortest-path"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --min-group-size) MIN_GROUP="${2:-}"; shift 2 ;;
    --keep-strategy) KEEP_STRATEGY="${2:-}"; shift 2 ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

date_tag="$(date +'%Y-%m-%d')"
timestamp="$(date +'%Y-%m-%d-%H%M%S')"

OUT_CANON="$LOGS_DIR/${date_tag}-duplicate-hashes.txt"
OUT_GROUPS="$LOGS_DIR/duplicate-groups-$timestamp.txt"
OUT_CSV="$LOGS_DIR/duplicates-$timestamp.csv"
OUT_PLAN="$LOGS_DIR/review-dedupe-plan-$timestamp.txt"  # only when bulk
OUT_LATEST="$LOGS_DIR/duplicate-hashes-latest.txt"

pick_latest_csv() {
  ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true
}

INPUT="${INPUT:-$(pick_latest_csv)}"
[[ -z "$INPUT" ]] && { err "No input CSV found in $HASHES_DIR and none provided."; exit 1; }
[[ ! -f "$INPUT" ]] && { err "Input CSV not found: $INPUT"; exit 1; }

info "Input: $INPUT"
info "Mode: $MODE  | Min group size: $MIN_GROUP"

header="$(head -n1 "$INPUT" || true)"
second="$(sed -n '2p' "$INPUT" || true)"

detect_delim() {
  local line="$1"
  if [[ "$line" == *$'\t'* ]]; then echo $'\t'; return; fi
  if [[ "$line" == *","* ]]; then echo ","; return; fi
  if [[ "$line" == *"|"* ]]; then echo "|"; return; fi
  if [[ "$line" == *";"* ]]; then echo ";"; return; fi
  echo ","
}
DELIM="$(detect_delim "$header")"

lower_header="$(printf "%s" "$header" | tr 'A-Z' 'a-z')"

find_hdr_idx() {
  local patterns="$1"
  local idx=0 IFS="$DELIM"
  for col in $lower_header; do
    idx=$((idx+1))
    col="${col//\"/}"; col="$(echo "$col" | xargs)"
    IFS="|" read -r -a pats <<< "$patterns"
    for p in "${pats[@]}"; do
      if [[ "$col" == "$p" ]]; then echo "$idx"; return 0; fi
    done
  done
  echo ""
}

COL_HASH="$(find_hdr_idx 'hash|digest|checksum|sha256|sha1|sha512|md5|blake2|blake2b|blake2s')"
COL_PATH="$(find_hdr_idx 'path|filepath|file|fullpath')"
COL_SIZE="$(find_hdr_idx 'size|size_bytes|bytes|filesize|size_mb')"

if [[ -n "$COL_HASH" && -n "$COL_PATH" ]]; then
  SKIP_HEADER=1
else
  SKIP_HEADER=0
  COL_HASH="${COL_HASH:-5}"
  COL_PATH="${COL_PATH:-1}"
fi

# Progress plumbing -----------------------------------------------------
TOTAL_LINES="$(wc -l < "$INPUT" 2>/dev/null || echo 0)"
if [[ "$SKIP_HEADER" -eq 1 && "$TOTAL_LINES" -gt 0 ]]; then
  TOTAL_WORK=$(( TOTAL_LINES - 1 ))
else
  TOTAL_WORK="$TOTAL_LINES"
fi
PROG_FILE="$(mktemp)"; trap 'rm -f "$PROG_FILE"' EXIT

draw_bar() {
  # $1=current, $2=total
  local cur="$1" tot="$2" width=40 perc filled empty
  if [[ "$tot" -gt 0 ]]; then perc=$(( cur * 100 / tot )); else perc=0; fi
  (( perc > 100 )) && perc=100
  filled=$(( perc * width / 100 ))
  empty=$(( width - filled ))
  # build bar segments
  printf -v hashes "%${filled}s" ""; hashes="${hashes// /#}"
  printf -v spaces "%${empty}s" ""
  printf "\r[%s%s] %3d%%  (%s/%s lines)" "$hashes" "$spaces" "$perc" "$cur" "$tot" >&2
}

# Build a tmp working file of "hash,path,size"
TMP="$(mktemp)"; trap 'rm -f "$TMP" "$PROG_FILE"' EXIT

# Launch the parsing awk in background and monitor progress from $PROG_FILE
(
  awk -v ch="$COL_HASH" -v cp="$COL_PATH" -v cs="${COL_SIZE:-0}" -v skip="$SKIP_HEADER" -v FS="$DELIM" -v prog="$PROG_FILE" -v step=5000 '
    BEGIN{ OFS=","; n=0 }
    NR==1 && skip==1 { next }
    {
      h=$ch; p=$cp; s=(cs>0 ? $cs : "")
      gsub(/"/,"",h); gsub(/"/,"",p); gsub(/"/,"",s)
      sub(/^[ \t\r\n]+/,"",h); sub(/[ \t\r\n]+$/,"",h)
      sub(/^[ \t\r\n]+/,"",p); sub(/[ \t\r\n]+$/,"",p)
      sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s)
      if (h!="" && p!="") {
        print h, p, s
        n++
        if (n % step == 0) { print n >> prog; close(prog) }
      }
    }
    END{ print n >> prog; close(prog) }
  ' "$INPUT" > "$TMP"
) &
PID_AWK=$!

# Progress monitor loop (TTY only)
if [ -t 1 ] && [ "$TOTAL_WORK" -gt 0 ]; then
  while kill -0 "$PID_AWK" >/dev/null 2>&1; do
    cur="$(tail -n1 "$PROG_FILE" 2>/dev/null || echo 0)"
    # draw bar
    width=40
    cur=${cur:-0}
    tot="$TOTAL_WORK"
    if [ "$tot" -gt 0 ]; then perc=$(( cur * 100 / tot )); else perc=0; fi
    [ "$perc" -gt 100 ] && perc=100
    filled=$(( perc * width / 100 ))
    empty=$(( width - filled ))
    hashes="$(printf "%${filled}s" "")"; hashes="${hashes// /#}"
    spaces="$(printf "%${empty}s" "")"
    printf "\r[%s%s] %3d%%  (%s/%s lines)" "$hashes" "$spaces" "$perc" "$cur" "$tot"
    sleep 0.2
  done
  # final bar
  hashes="$(printf "%40s" "")"; hashes="${hashes// /#}"
  printf "\r[%s] 100%%  (%s/%s lines)\n" "$hashes" "$TOTAL_WORK" "$TOTAL_WORK"
fi

# Wait for awk to finish
wait "$PID_AWK"

if [[ ! -s "$TMP" ]]; then
  err "Parsed 0 rows from input. Detected delimiter: '$(printf "%q" "$DELIM")'. Header: '$header'"
  err "Sample line 2: '$second'"
  exit 2
fi

HASHES_TMP="$(mktemp)"; trap 'rm -f "$TMP" "$HASHES_TMP" "$PROG_FILE"' EXIT
cut -d',' -f1 "$TMP" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$HASHES_TMP"

: > "$OUT_CANON"
: > "$OUT_LATEST"
{
  echo "Duplicate Groups — generated $timestamp"
  echo "Source CSV: $INPUT"
  echo "Delimiter: $( [[ "$DELIM" == $'\t' ]] && echo 'TAB' || echo "$DELIM" )"
  echo
} > "$OUT_GROUPS"

if [[ ! -s "$HASHES_TMP" ]]; then
  warn "No duplicate groups found (>= $MIN_GROUP)."
  info "Canonical report (empty): $OUT_CANON"
  info "Group summary:           $OUT_GROUPS"
  : > "$OUT_CSV"
  exit 0
fi

grep -F -f "$HASHES_TMP" "$TMP" > "$OUT_CSV"

group_count=0
total_dupe_files=0

get_mtime() { stat -c '%Y' -- "$1" 2>/dev/null || echo 0; }
path_len() { printf "%s" "$1" | wc -c; }

while IFS= read -r h; do
  mapfile -t rows < <(grep "^${h}," "$OUT_CSV" || true)
  (( ${#rows[@]} < MIN_GROUP )) && continue
  ((group_count++))

  declare -a paths=()
  declare -a sizes=()
  for r in "${rows[@]}"; do
    p="${r#*,}"; p="${p%,*}"
    s="${r##*,}"
    paths+=("$p")
    sizes+=("$s")
  done

  printf "HASH %s (N=%d)\n" "$h" "${#paths[@]}" >> "$OUT_CANON"
  printf "HASH %s (N=%d)\n" "$h" "${#paths[@]}" >> "$OUT_LATEST"
  echo "─ Group #$group_count — hash: $h" >> "$OUT_GROUPS"

  for i in "${!paths[@]}"; do
    p="${paths[$i]}"; s="${sizes[$i]}"
    printf "  %s\n" "$p" >> "$OUT_CANON"
    printf "  %s\n" "$p" >> "$OUT_LATEST"
    if [[ -n "$s" ]]; then
      printf "   %2d) %s  (size: %s)\n" "$((i+1))" "$p" "$s" >> "$OUT_GROUPS"
    else
      printf "   %2d) %s\n" "$((i+1))" "$p" >> "$OUT_GROUPS"
    fi
    ((total_dupe_files++))
  done
  printf "\n" >> "$OUT_CANON"
  printf "\n" >> "$OUT_LATEST"
  echo >> "$OUT_GROUPS"

  if [[ "$MODE" == "bulk" ]]; then
    keep=""
    case "$KEEP_STRATEGY" in
      shortest-path)
        shortest=999999
        for p in "${paths[@]}"; do plen="$(printf "%s" "$p" | wc -c)"; if (( plen < shortest )); then shortest=$plen; keep="$p"; fi; done
        ;;
      oldest)
        best=9999999999
        for p in "${paths[@]}"; do mt="$(get_mtime "$p")"; if (( mt < best )); then best=$mt; keep="$p"; fi; done
        ;;
      newest)
        best=0
        for p in "${paths[@]}"; do mt="$(get_mtime "$p")"; if (( mt > best )); then best=$mt; keep="$p"; fi; done
        ;;
      first|*) keep="${paths[0]}" ;;
    esac
    for p in "${paths[@]}"; do
      [[ "$p" == "$keep" ]] && continue
      printf "%s\n" "$p" >> "$OUT_PLAN"
    done
  fi
done < "$HASHES_TMP"

info "Groups: $group_count  | Duplicate files (incl. keepers): $total_dupe_files"
info "Canonical report: $OUT_CANON"
info "Group summary:    $OUT_GROUPS"
info "Flat CSV:         $OUT_CSV"

if [[ "$MODE" == "bulk" ]]; then
  if [[ -s "$OUT_PLAN" ]]; then
    info "Auto delete plan: $OUT_PLAN"
    cp -f "$OUT_PLAN" "$VAR_DIR/latest-plan.txt"
    info "Latest plan copied to: $VAR_DIR/latest-plan.txt"
  else
    warn "Bulk mode produced no deletable items (unexpected)."
  fi
else
  info "Next: run 'review-duplicates.sh --from-report \"$OUT_CANON\"' (or menu option 4) to interactively refine a plan."
fi
