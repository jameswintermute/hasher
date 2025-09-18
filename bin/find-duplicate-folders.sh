#!/usr/bin/env bash
# find-duplicate-folders.sh — detect duplicate folder trees by content (from hasher CSV)
# Generates a review plan; can optionally apply it (delete or quarantine).
# GPLv3

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"

HASHES_DIR="$APP_HOME/hashes"
LOGS_DIR="$APP_HOME/logs"
VAR_DIR="$APP_HOME/var/duplicates"

mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$VAR_DIR"

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

usage() {
  cat <<'EOF'
Usage: find-duplicate-folders.sh [--input CSV] [--mode plan|apply]
                                 [--min-group-size N]
                                 [--keep-strategy shortest-path|oldest|newest|first]
                                 [--scope recursive|leaf]
                                 [--quarantine DIR] [--force]
EOF
}

# Defaults
INPUT=""
MODE="plan"
MIN_GROUP=2
KEEP_STRATEGY="shortest-path"
SCOPE="recursive"
QUARANTINE=""
FORCE=false

# Args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --min-group-size) MIN_GROUP="${2:-}"; shift 2 ;;
    --keep-strategy) KEEP_STRATEGY="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --quarantine) QUARANTINE="${2:-}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

timestamp="$(date +'%Y-%m-%d-%H%M%S')"
OUT_SUM="$LOGS_DIR/duplicate-folders-$timestamp.txt"
OUT_CSV="$LOGS_DIR/duplicate-folders-$timestamp.csv"
OUT_PLAN="$LOGS_DIR/review-folder-dedupe-plan-$timestamp.txt"

pick_latest_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
INPUT="${INPUT:-$(pick_latest_csv)}"
[[ -z "$INPUT" ]] && { err "No input CSV found in $HASHES_DIR and none provided."; exit 1; }
[[ ! -f "$INPUT" ]] && { err "Input CSV not found: $INPUT"; exit 1; }

info "Input: $INPUT"
info "Mode: $MODE  | Min group size: $MIN_GROUP  | Scope: $SCOPE  | Keep: $KEEP_STRATEGY"

# Header detection
header="$(head -n1 "$INPUT")"
lchead="$(printf "%s" "$header" | tr 'A-Z' 'a-z')"

find_col() {
  local name="$1"; local idx=0; local IFS=,
  for col in $lchead; do
    idx=$((idx+1))
    col=${col//"/}
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
if [[ -z "$COL_HASH" || -z "$COL_PATH" ]]; then
  warn "Header detection failed; assuming two-column CSV: hash,path (no header)."
  COL_HASH=1; COL_PATH=2; SKIP_HEADER=0
else
  SKIP_HEADER=1
fi

# Tools
have() { command -v "$1" >/dev/null 2>&1; }
hash_string() {
  if have sha256sum; then sha256sum | awk '{print $1}'
  elif have shasum; then shasum -a 256 | awk '{print $1}'
  elif have openssl; then openssl dgst -sha256 | awk '{print $2}'
  elif have md5sum; then md5sum | awk '{print $1}'
  else err "No hashing tool (sha256sum/shasum/openssl/md5sum) available"; exit 1; fi
}
get_mtime() {
  if stat -c '%Y' -- "$1" >/dev/null 2>&1; then stat -c '%Y' -- "$1"
  elif stat -f '%m' -- "$1" >/dev/null 2>&1; then stat -f '%m' -- "$1"
  else echo 0; fi
}
path_len() { printf "%s" "$1" | wc -c; }

# Extract normalized rows hash,path,size? -> TMP_FILES
TMP_FILES="$(mktemp)"; trap 'rm -f "$TMP_FILES" "$TMP_DIR_ENT" "$TMP_SORT" "$DIR_SIGS" "$DUP_SIGS" "$BUF_FILE" 2>/dev/null || true' EXIT
awk -v ch="$COL_HASH" -v cp="$COL_PATH" -v cs="${COL_SIZE:-0}" -v skip="$SKIP_HEADER" -F',' '
  NR==1 && skip==1 { next }
  {
    h=$ch; p=$cp; s=(cs>0?$cs:"")
    gsub(/"/,"",h); gsub(/"/,"",p); gsub(/"/,"",s)
    sub(/^[ 	
]+/,"",h); sub(/[ 	
]+$/,"",h)
    sub(/^[ 	
]+/,"",p); sub(/[ 	
]+$/,"",p)
    sub(/^[ 	
]+/,"",s); sub(/[ 	
]+$/,"",s)
    if (h!="" && p!="") print h "," p "," s
  }
' "$INPUT" > "$TMP_FILES"

# Build (dir, relpath, hash) entries for each ancestor (or just leaf) — POSIX awk friendly
TMP_DIR_ENT="$(mktemp)"
awk -F',' -v scope="$SCOPE" '
  {
    h=$1; p=$2
    n=split(p, comp, "/")
    start=1; if (comp[1]=="") start=2
    end=n-1
    if (end<start) next
    if (scope=="leaf") {
      i=end
      dir=""; for (k=start; k<=i; k++) { if (comp[k]=="") continue; dir = dir "/" comp[k] }
      rel=""; for (k=i+1; k<=n; k++) { if (comp[k]=="") continue; rel = (rel=="" ? comp[k] : rel "/" comp[k]) }
      print dir "," rel "," h
    } else {
      for (i=start; i<=end; i++) {
        dir=""; for (k=start; k<=i; k++) { if (comp[k]=="") continue; dir = dir "/" comp[k] }
        rel=""; for (k=i+1; k<=n; k++) { if (comp[k]=="") continue; rel = (rel=="" ? comp[k] : rel "/" comp[k]) }
        print dir "," rel "," h
      }
    }
  }
' "$TMP_FILES" > "$TMP_DIR_ENT"

# Empty?
if [[ ! -s "$TMP_DIR_ENT" ]]; then
  warn "No directory entries derived from input. Nothing to do."
  exit 0
fi

# Sort: dir, then relpath
TMP_SORT="$(mktemp)"
sort -t, -k1,1 -k2,2 "$TMP_DIR_ENT" > "$TMP_SORT"

# Compute per-dir signature from sorted rel|hash lines
DIR_SIGS="$(mktemp)"
BUF_FILE="$(mktemp)"
: > "$BUF_FILE"
current=""; count=0
while IFS=, read -r dir rel h; do
  if [[ -n "$current" && "$dir" != "$current" ]]; then
    sig="$(cat "$BUF_FILE" | hash_string)"
    printf "%s,%s,%d\n" "$sig" "$current" "$count" >> "$DIR_SIGS"
    : > "$BUF_FILE"; count=0
  fi
  current="$dir"
  printf "%s|%s\n" "$rel" "$h" >> "$BUF_FILE"
  count=$((count+1))
done < "$TMP_SORT"
if [[ -n "$current" ]]; then
  sig="$(cat "$BUF_FILE" | hash_string)"
  printf "%s,%s,%d\n" "$sig" "$current" "$count" >> "$DIR_SIGS"
fi

# Find duplicate signatures (groups >= MIN_GROUP)
DUP_SIGS="$(mktemp)"
cut -d, -f1 "$DIR_SIGS" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$DUP_SIGS"
if [[ ! -s "$DUP_SIGS" ]]; then
  info "No duplicate folder groups found (>= '"$MIN_GROUP"')."
  exit 0
fi

# Outputs
echo "signature,dir,file_count" > "$OUT_CSV"
grep -F -f "$DUP_SIGS" "$DIR_SIGS" >> "$OUT_CSV"

{
  echo "Duplicate Folders — generated $timestamp"
  echo "Source CSV: $INPUT"
  echo "Scope: $SCOPE"
  echo
} > "$OUT_SUM"

group_no=0
: > "$OUT_PLAN"
while IFS= read -r sig; do
  mapfile -t lines < <(grep "^$sig," "$DIR_SIGS" | sort -t, -k2,2)
  (( ${#lines[@]} < MIN_GROUP )) && continue
  ((group_no++))
  echo "─ Group #$group_no — signature: $sig" >> "$OUT_SUM"
  declare -a dirs=()
  for line in "${lines[@]}"; do
    dir="${line#*,}"; dir="${dir%,*}"
    cnt="${line##*,}"
    printf "   - %s  (files: %s)\n" "$dir" "$cnt" >> "$OUT_SUM"
    dirs+=("$dir")
  done
  keep=""
  case "$KEEP_STRATEGY" in
    shortest-path)
      shortest=999999
      for d in "${dirs[@]}"; do
        plen=$(path_len "$d")
        if (( plen < shortest )); then shortest=$plen; keep="$d"; fi
      done
      ;;
    oldest)
      best=9999999999
      for d in "${dirs[@]}"; do
        mt=$(get_mtime "$d")
        if (( mt < best )); then best=$mt; keep="$d"; fi
      done
      ;;
    newest)
      best=0
      for d in "${dirs[@]}"; do
        mt=$(get_mtime "$d")
        if (( mt > best )); then best=$mt; keep="$d"; fi
      done
      ;;
    first|*)
      keep="${dirs[0]}"
      ;;
  esac
  echo "   → keep: $keep" >> "$OUT_SUM"
  for d in "${dirs[@]}"; do
    [[ "$d" == "$keep" ]] && continue
    printf "%s\n" "$d" >> "$OUT_PLAN"
  done
  echo >> "$OUT_SUM"
done < "$DUP_SIGS"

info "Groups: $group_no"
info "Group summary: $OUT_SUM"
info "CSV:           $OUT_CSV"

if [[ -s "$OUT_PLAN" ]]; then
  info "Plan:          $OUT_PLAN"
  cp -f "$OUT_PLAN" "$VAR_DIR/latest-folder-plan.txt" || true
  info "Latest plan copied to: $VAR_DIR/latest-folder-plan.txt"
else
  warn "Plan is empty (no deletable duplicates after keep-policy)."
fi

# Apply mode
if [[ "$MODE" == "apply" ]]; then
  [[ "$FORCE" == true ]] || { err "--mode apply requires --force"; exit 1; }
  [[ -s "$OUT_PLAN" ]] || { warn "No entries to act on."; exit 0; }
  if [[ -n "$QUARANTINE" ]]; then
    info "Applying plan: MOVE to quarantine: $QUARANTINE"
    mkdir -p "$QUARANTINE"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      [[ -d "$d" ]] || { warn "Missing dir: $d"; continue; }
      stamp="$(date +%Y%m%d-%H%M%S)"
      base="$(basename "$d")"
      dest="$QUARANTINE/${base}-${stamp}"
      info "[MOVE] $d -> $dest"
      mv -- "$d" "$dest" || warn "Failed to move: $d"
    done < "$OUT_PLAN"
  else
    info "Applying plan: DELETE (no quarantine)"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      [[ -d "$d" ]] || { warn "Missing dir: $d"; continue; }
      info "[DEL] $d"
      rm -rf -- "$d" || warn "Failed to delete: $d"
    done < "$OUT_PLAN"
  fi
  info "Done."
else
  info "Review the plan above. To apply: --mode apply --force [--quarantine DIR]"
fi
