#!/usr/bin/env bash
# find-duplicates.sh — robust duplicate grouper (BusyBox/GNU friendly)
# - De-duplicates identical (hash,path) rows from the hasher CSV
# - Groups by hash; emits canonical report + summary + flat CSV
# - Avoids bash arrays/mapfile pitfalls under `set -e` by using a single awk pass
# License: GPLv3
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
Outputs:
  - Canonical: logs/YYYY-MM-DD-duplicate-hashes.txt   (for review-duplicates.sh --from-report)
  - Summary:   logs/duplicate-groups-YYYY-MM-DD-HHMMSS.txt
  - Flat CSV:  logs/duplicates-YYYY-MM-DD-HHMMSS.csv
Bulk mode also writes:
  - Plan:      logs/review-dedupe-plan-YYYY-MM-DD-HHMMSS.txt
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

# Read header to detect delimiter
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
  COL_HASH="${COL_HASH:-5}"   # for hasher CSV: path,size_bytes,mtime_epoch,algo,hash
  COL_PATH="${COL_PATH:-1}"
  COL_SIZE="${COL_SIZE:-2}"
fi

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
# Build "hash,path,size" with de-duplication of (hash,path)
awk -v ch="$COL_HASH" -v cp="$COL_PATH" -v cs="${COL_SIZE:-0}" -v skip="$SKIP_HEADER" -v FS="$DELIM" '
  BEGIN{ OFS="," }
  NR==1 && skip==1 { next }
  {
    h=$ch; p=$cp; s=(cs>0 ? $cs : "")
    gsub(/"/,"",h); gsub(/"/,"",p); gsub(/"/,"",s)
    sub(/^[ \t\r\n]+/,"",h); sub(/[ \t\r\n]+$/,"",h)
    sub(/^[ \t\r\n]+/,"",p); sub(/[ \t\r\n]+$/,"",p)
    sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s)
    k=h SUBSEP p
    if (h!="" && p!="" && !seen[k]++) print h, p, s
  }
' "$INPUT" > "$TMP"

if [[ ! -s "$TMP" ]]; then
  err "Parsed 0 rows from input. Detected delimiter: '$(printf "%q" "$DELIM")'. Header: '$header'"
  err "Sample line 2: '$second'"
  exit 2
fi

# Pre-compute counts by hash (>= MIN_GROUP)
HASHES_TMP="$(mktemp)"; trap 'rm -f "$TMP" "$HASHES_TMP"' EXIT
cut -d',' -f1 "$TMP" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$HASHES_TMP"

: > "$OUT_CANON"
: > "$OUT_GROUPS"
: > "$OUT_LATEST"
: > "$OUT_CSV"

if [[ ! -s "$HASHES_TMP" ]]; then
  warn "No duplicate groups found (>= $MIN_GROUP)."
  info "Canonical report (empty): $OUT_CANON"
  info "Group summary:           $OUT_GROUPS"
  : > "$OUT_CSV"
  exit 0
fi

# Keep only rows belonging to duplicate hashes
grep -F -f "$HASHES_TMP" "$TMP" > "$OUT_CSV" || true

# Single-pass AWK to render canonical + groups; avoids bash loops under set -e
awk -F',' -v min="$MIN_GROUP" \
  -v canon="$OUT_CANON" -v latest="$OUT_LATEST" -v groups="$OUT_GROUPS" '
  function flush(h,   n,i,p,s) {
    n = cnt[h]; if (n < min) return
    group++
    printf "HASH %s (N=%d)\n", h, n >> canon
    printf "HASH %s (N=%d)\n", h, n >> latest
    printf "─ Group #%d — hash: %s\n", group, h >> groups
    for (i=1;i<=idx[h];i++) {
      p = order[h,i]; s = size[h,p]
      printf "  %s\n", p >> canon
      printf "  %s\n", p >> latest
      if (s != "") printf "   %2d) %s  (size: %s)\n", i, p, s >> groups
      else         printf "   %2d) %s\n", i, p >> groups
    }
    printf "\n" >> canon; printf "\n" >> latest; printf "\n" >> groups
  }
  {
    h=$1; p=$2; s=$3
    k=h SUBSEP p
    if (!seen[k]++) { cnt[h]++; size[h,p]=s; order[h, ++idx[h]] = p }
  }
  END {
    for (h in cnt) flush(h)
  }
' "$OUT_CSV"

# Footer
groups_count="$(grep -c '^HASH ' "$OUT_CANON" || true)"
info "Groups: $groups_count"
info "Canonical report: $OUT_CANON"
info "Flat CSV:         $OUT_CSV"
info "Group summary:    $OUT_GROUPS"

if [[ "$MODE" == "bulk" ]]; then
  # Optional: build a naive plan (keep shortest path)
  : > "$OUT_PLAN"
  awk -F',' '
    { h=$1; p=$2; len=length(p); paths[h,++idx[h]]=p; if (!best[h] || len<bestlen[h]) { best[h]=p; bestlen[h]=len } }
    END {
      for (h in idx) {
        if (idx[h] >= 2) {
          k=best[h]
          for (i=1;i<=idx[h];i++) { p=paths[h,i]; if (p!=k) print p }
        }
      }
    }
  ' "$OUT_CSV" >> "$OUT_PLAN"
  if [[ -s "$OUT_PLAN" ]]; then
    info "Auto delete plan: $OUT_PLAN"
    cp -f "$OUT_PLAN" "$VAR_DIR/latest-plan.txt"
    info "Latest plan copied to: $VAR_DIR/latest-plan.txt"
  else
    warn "Bulk mode produced no deletable items (unexpected)."
  fi
else
  info "Next: run 'review-duplicates.sh --from-report \"$OUT_CANON\"' (or menu option 4)."
  cp -f "$OUT_CANON" "$OUT_LATEST" 2>/dev/null || true
  info "Canonical report ready: $OUT_LATEST"
fi
