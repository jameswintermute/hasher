#!/usr/bin/env bash
# find-duplicates.sh — group duplicate files by hash using hasher CSV output
# Produces the canonical duplicate-hashes report expected by review-duplicates.sh
# and (optionally) a bulk auto-delete plan.
# License: GPLv3
#
# Outputs (always):
#   logs/YYYY-MM-DD-duplicate-hashes.txt            # canonical groups (paths, blank line between groups)
#   logs/duplicate-groups-YYYY-MM-DD-HHMMSS.txt     # human summary
#   logs/duplicates-YYYY-MM-DD-HHMMSS.csv           # flat CSV (hash,path,size)
# Outputs (bulk mode):
#   logs/review-dedupe-plan-YYYY-MM-DD-HHMMSS.txt   # paths to delete (one per line)
#
# Notes:
#  - The canonical report contains ONLY absolute paths, with a blank line between groups.
#  - review-duplicates.sh reads that format directly.
#  - We also drop a convenience copy: logs/duplicate-hashes-latest.txt

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"

HASHES_DIR="$APP_HOME/hashes"
LOGS_DIR="$APP_HOME/logs"
VAR_DIR="$APP_HOME/var/duplicates"

mkdir -p "$LOGS_DIR" "$VAR_DIR"

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

usage() {
  cat <<'EOF'
Usage: find-duplicates.sh [--input CSV] [--mode standard|bulk]
                          [--min-group-size N] [--keep-strategy shortest-path|oldest|newest|first]

Reads the latest hasher CSV (or --input) and groups files by HASH.

Outputs:
  - Canonical report: logs/YYYY-MM-DD-duplicate-hashes.txt       (paths only; blank line between groups)
  - Group summary:    logs/duplicate-groups-YYYY-MM-DD-HHMMSS.txt
  - Flat CSV:         logs/duplicates-YYYY-MM-DD-HHMMSS.csv

If --mode bulk, also writes a delete plan:
  - Plan file:        logs/review-dedupe-plan-YYYY-MM-DD-HHMMSS.txt  (one path per line to delete)

Keep strategies (bulk mode only):
  shortest-path : keep the file whose path string length is shortest (often the canonical/original)
  oldest        : keep the oldest by mtime
  newest        : keep the newest by mtime
  first         : keep the lexicographically first path

Notes:
 - CSV header detection supports common layouts; must include at least 'hash' and 'path' columns.
 - Files with unique hashes are ignored.
 - The canonical report is what review-duplicates.sh expects via --from-report.
EOF
}

# Defaults
INPUT=""
MODE="standard"        # standard | bulk
MIN_GROUP=2
KEEP_STRATEGY="shortest-path"

# Parse args
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

# Detect header to find columns (hash/path/size optional).
header="$(head -n1 "$INPUT" || true)"
lchead="$(printf "%s" "$header" | tr 'A-Z' 'a-z')"

find_col() {
  local name="$1"
  local idx=0
  local IFS=,
  for col in $lchead; do
    idx=$((idx+1))
    col="${col//\"/}"
    col="$(echo "$col" | xargs)"
    if [[ "$col" == "$name" ]]; then
      echo "$idx"; return 0
    fi
  done
  echo ""
}

COL_HASH="$(find_col hash)"
COL_PATH="$(find_col path)"
COL_SIZE="$(find_col size)"

# If no header match, assume two-column CSV: hash,path (no header)
if [[ -z "$COL_HASH" || -z "$COL_PATH" ]]; then
  warn "Header-based detection failed; assuming two-column CSV: hash,path (no header)."
  COL_HASH=1; COL_PATH=2
  SKIP_HEADER=0
else
  SKIP_HEADER=1
fi

# Build a tmp working file of "hash,path,size"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
awk -v ch="$COL_HASH" -v cp="$COL_PATH" -v cs="${COL_SIZE:-0}" -v skip="$SKIP_HEADER" -F',' '
  NR==1 && skip==1 { next }
  {
    h=$ch; p=$cp; s=(cs>0 ? $cs : "")
    gsub(/"/,"",h); gsub(/"/,"",p); gsub(/"/,"",s)
    sub(/^[ \t\r\n]+/,"",h); sub(/[ \t\r\n]+$/,"",h)
    sub(/^[ \t\r\n]+/,"",p); sub(/[ \t\r\n]+$/,"",p)
    sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s)
    if (h!="" && p!="") {
      print h "," p "," s
    }
  }
' "$INPUT" > "$TMP"

# Make list of hashes meeting threshold
HASHES_TMP="$(mktemp)"; trap 'rm -f "$TMP" "$HASHES_TMP"' EXIT
cut -d',' -f1 "$TMP" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$HASHES_TMP"

if [[ ! -s "$HASHES_TMP" ]]; then
  warn "No duplicate groups found (>= $MIN_GROUP)."
  : > "$OUT_CANON"
  : > "$OUT_LATEST"
  exit 0
fi

# Write duplicates flat CSV
grep -F -f "$HASHES_TMP" "$TMP" > "$OUT_CSV"

# Prepare outputs
{
  echo "Duplicate Groups — generated $timestamp"
  echo "Source CSV: $INPUT"
  echo
} > "$OUT_GROUPS"

: > "$OUT_CANON"   # truncate/create
: > "$OUT_LATEST"  # latest pointer copy

group_count=0
total_dupe_files=0

get_mtime() { stat -c '%Y' -- "$1" 2>/dev/null || echo 0; }   # GNU stat preferred; busybox fallback -> 0
path_len() { printf "%s" "$1" | wc -c; }

while IFS= read -r h; do
  mapfile -t rows < <(grep "^${h}," "$OUT_CSV" || true)
  (( ${#rows[@]} < MIN_GROUP )) && continue
  ((group_count++))
  echo "─ Group #$group_count — hash: $h" >> "$OUT_GROUPS"
  declare -a paths=()
  idx=0
  for r in "${rows[@]}"; do
    ((idx++))
    p="${r#*,}"; p="${p%,*}"   # extract middle column (path)
    s="${r##*,}"               # size (may be empty)
    paths+=("$p")
    printf "   %2d) %s%s\n" "$idx" "$p" "${s:+  (size: $s)}" >> "$OUT_GROUPS"
    ((total_dupe_files++))
  done
  echo >> "$OUT_GROUPS"

  # Canonical report block: just the paths, then a blank line
  for p in "${paths[@]}"; do
    printf "%s\n" "$p" >> "$OUT_CANON"
    printf "%s\n" "$p" >> "$OUT_LATEST"
  done
  printf "\n" >> "$OUT_CANON"
  printf "\n" >> "$OUT_LATEST"

  if [[ "$MODE" == "bulk" ]]; then
    # choose keeper
    keep=""
    case "$KEEP_STRATEGY" in
      shortest-path)
        shortest=999999
        for p in "${paths[@]}"; do
          plen="$(path_len "$p")"
          if (( plen < shortest )); then shortest=$plen; keep="$p"; fi
        done
        ;;
      oldest)
        best=9999999999
        for p in "${paths[@]}"; do
          mt="$(get_mtime "$p")"
          if (( mt < best )); then best=$mt; keep="$p"; fi
        done
        ;;
      newest)
        best=0
        for p in "${paths[@]}"; do
          mt="$(get_mtime "$p")"
          if (( mt > best )); then best=$mt; keep="$p"; fi
        done
        ;;
      first|*)
        keep="${paths[0]}"
        ;;
    esac
    # others -> plan
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
  info "Next: run 'review-duplicates.sh --from-report \"$OUT_CANON\"' to interactively refine a plan."
fi
