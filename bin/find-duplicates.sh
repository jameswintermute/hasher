#!/usr/bin/env bash
# find-duplicates.sh — robust (BusyBox-friendly) implementation
# - Parses hasher CSV
# - Builds flat duplicates CSV (hash,path,size?)
# - Builds canonical report using AWK (no bash arrays/mapfile)
# - Prints clear next steps
# License: GPLv3
set -Euo pipefail
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
                          [--min-group-size N]
Outputs:
  - Canonical: logs/YYYY-MM-DD-duplicate-hashes.txt
  - Summary:   logs/duplicate-groups-YYYY-MM-DD-HHMMSS.txt
  - Flat CSV:  logs/duplicates-YYYY-MM-DD-HHMMSS.csv
EOF
}

INPUT=""; MODE="standard"; MIN_GROUP=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --min-group-size) MIN_GROUP="${2:-}"; shift 2 ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

date_tag="$(date +'%Y-%m-%d')"
timestamp="$(date +'%Y-%m-%d-%H%M%S')"

OUT_CANON="$LOGS_DIR/${date_tag}-duplicate-hashes.txt"
OUT_GROUPS="$LOGS_DIR/duplicate-groups-$timestamp.txt"
OUT_CSV="$LOGS_DIR/duplicates-$timestamp.csv"
OUT_LATEST="$LOGS_DIR/duplicate-hashes-latest.txt"

pick_latest_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
INPUT="${INPUT:-$(pick_latest_csv)}"
[[ -z "$INPUT" ]] && { err "No input CSV found in $HASHES_DIR and none provided."; exit 1; }
[[ ! -f "$INPUT" ]] && { err "Input CSV not found: $INPUT"; exit 1; }

info "Input: $INPUT"
info "Mode: $MODE  | Min group size: $MIN_GROUP"

header="$(head -n1 "$INPUT" || true)"
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
if [[ -n "$COL_HASH" && -n "$COL_PATH" ]]; then SKIP_HEADER=1; else SKIP_HEADER=0; COL_HASH="${COL_HASH:-5}"; COL_PATH="${COL_PATH:-1}"; fi

# Progress bar while extracting "hash,path,size?"
TOTAL_LINES="$(wc -l < "$INPUT" 2>/dev/null || echo 0)"
if [[ "$SKIP_HEADER" -eq 1 && "$TOTAL_LINES" -gt 0 ]]; then TOTAL_WORK=$(( TOTAL_LINES - 1 )); else TOTAL_WORK="$TOTAL_LINES"; fi
PROG_FILE="$(mktemp)"; trap 'rm -f "$PROG_FILE" "$TMP" "$HASHES_TMP"' EXIT
draw_bar() {
  local cur="$1" tot="$2" width=40 perc filled empty
  if [[ "$tot" -gt 0 ]]; then perc=$(( cur * 100 / tot )); else perc=0; fi
  (( perc > 100 )) && perc=100
  filled=$(( perc * width / 100 ))
  empty=$(( width - filled ))
  printf -v hashes "%${filled}s" ""; hashes="${hashes// /#}"
  printf -v spaces "%${empty}s" ""
  printf "\r[%s%s] %3d%%  (%s/%s lines)" "$hashes" "$spaces" "$perc" "$cur" "$tot" >&2
}
TMP="$(mktemp)"
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
        if (n % step == 0) { print n > prog; close(prog) }
      }
    }
    END{ print n > prog; close(prog) }
  ' "$INPUT" > "$TMP"
) &
PID_AWK=$!

if [ -t 1 ] && [[ "$TOTAL_WORK" -gt 0 ]]; then
  while kill -0 "$PID_AWK" >/dev/null 2>&1; do
    cur="$(tail -n1 "$PROG_FILE" 2>/dev/null || echo 0)"
    draw_bar "${cur:-0}" "$TOTAL_WORK"
    sleep 0.2
  done
  draw_bar "$TOTAL_WORK" "$TOTAL_WORK"; echo
fi

wait "$PID_AWK" || { err "Parse step failed."; exit 1; }
[[ -s "$TMP" ]] || { err "Parsed 0 rows from input."; exit 2; }

# Build list of hashes with at least MIN_GROUP occurrences
HASHES_TMP="$(mktemp)"
cut -d',' -f1 "$TMP" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$HASHES_TMP" || true

# If none, write empty outputs and exit cleanly
if [[ ! -s "$HASHES_TMP" ]]; then
  : > "$OUT_CSV"; : > "$OUT_CANON"; : > "$OUT_LATEST"
  {
    echo "Duplicate Groups — generated $timestamp"
    echo "Source CSV: $INPUT"
    echo "Delimiter: $( [[ "$DELIM" == $'\t' ]] && echo 'TAB' || echo "$DELIM" )"
    echo
    echo "No duplicate groups found (>= $MIN_GROUP)."
  } > "$OUT_GROUPS"
  warn "No duplicate groups found (>= $MIN_GROUP)."
  info "Canonical report (empty): $OUT_CANON"
  info "Group summary:           $OUT_GROUPS"
  info "Flat CSV:                $OUT_CSV"
  exit 0
fi

# Create flat CSV of only duplicates
grep -F -f "$HASHES_TMP" "$TMP" > "$OUT_CSV" || true

# Canonical report using AWK grouping (sorted by hash for stable groups)
sort -t, -k1,1 "$OUT_CSV" | awk -F',' -v canon="$OUT_CANON" -v latest="$OUT_LATEST" '
  BEGIN{ prev=""; n=0 }
  {
    h=$1; p=$2
    if (h!=prev && prev!="") {
      print "HASH " prev " (N=" n ")" >> canon
      print "HASH " prev " (N=" n ")" >> latest
      for (i=1;i<=n;i++) { print "  " paths[i] >> canon; print "  " paths[i] >> latest }
      print "" >> canon; print "" >> latest
      delete paths; n=0
    }
    prev=h; n++; paths[n]=p
  }
  END{
    if (prev!="") {
      print "HASH " prev " (N=" n ")" >> canon
      print "HASH " prev " (N=" n ")" >> latest
      for (i=1;i<=n;i++) { print "  " paths[i] >> canon; print "  " paths[i] >> latest }
      print "" >> canon; print "" >> latest
    }
  }
'

groups="$(grep -c '^HASH ' "$OUT_CANON" 2>/dev/null || echo 0)"
: > "$OUT_GROUPS"
{
  echo "Duplicate Groups — generated $timestamp"
  echo "Source CSV: $INPUT"
  echo "Delimiter: $( [[ "$DELIM" == $'\t' ]] && echo 'TAB' || echo "$DELIM" )"
  echo "Groups: $groups"
  echo
} > "$OUT_GROUPS"

info "Groups: $groups"
info "Canonical report: $OUT_CANON"
info "Flat CSV:         $OUT_CSV"
info "Group summary:    $OUT_GROUPS"
info "Next: run 'review-duplicates.sh --from-report \"$OUT_CANON\"' (or menu option 4)."
exit 0
