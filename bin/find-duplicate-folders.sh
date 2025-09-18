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

# Defaults
INPUT=""
MODE="plan"                           # plan | apply
MIN_GROUP=2
KEEP_STRATEGY="shortest-path"         # shortest-path|oldest|newest|first
SCOPE="recursive"                     # recursive | leaf
SIGNATURE_MODE="name+content"         # name+content | content-only
QUARANTINE=""
FORCE=false

usage() {
  cat <<'EOF'
Usage: find-duplicate-folders.sh [--input CSV]
                                 [--mode plan|apply]
                                 [--min-group-size N]
                                 [--keep-strategy shortest-path|oldest|newest|first]
                                 [--scope recursive|leaf]
                                 [--signature name+content|content-only]
                                 [--quarantine DIR]
                                 [--force]
EOF
}

# Args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --min-group-size) MIN_GROUP="${2:-}"; shift 2 ;;
    --keep-strategy) KEEP_STRATEGY="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --signature) SIGNATURE_MODE="${2:-}"; shift 2 ;;
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

# Header detection
header="$(head -n1 "$INPUT")"
lchead="$(printf "%s" "$header" | tr 'A-Z' 'a-z')"

find_col() {
  local name="$1"; local idx=0; local IFS=,
  for col in $lchead; do
    idx=$((idx+1))
    col=${col//\"/}
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
SIZE_SOURCE="csv"
SIZE_AVAILABLE=true
if [[ -z "$COL_SIZE" ]]; then
  SIZE_SOURCE="filesystem"
  SIZE_AVAILABLE=false
fi

if [[ -z "$COL_HASH" || -z "$COL_PATH" ]]; then
  warn "Header detection failed; assuming two-column CSV: hash,path (no header)."
  COL_HASH=1; COL_PATH=2; SKIP_HEADER=0
else
  SKIP_HEADER=1
fi

info "Input: $INPUT"
info "Mode: $MODE  | Min group size: $MIN_GROUP  | Scope: $SCOPE  | Keep: $KEEP_STRATEGY  | Signature: $SIGNATURE_MODE"

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
human_bytes() {
  local b=${1:-0}
  awk -v b="$b" 'function p(n,u){printf("%.1f%s", n,u); exit}
    BEGIN{
      if (b<1024) {printf("%dB", b); exit}
      kb=b/1024; if (kb<1024){p(kb,"KB")}
      mb=kb/1024; if (mb<1024){p(mb,"MB")}
      gb=mb/1024; if (gb<1024){p(gb,"GB")}
      tb=gb/1024; p(tb,"TB")
    }'
}

# Get file size from filesystem (metadata only). Returns 0 if missing or unsupported.
get_size() {
  local f="$1"
  if [[ -f "$f" ]]; then
    if stat -c '%s' -- "$f" >/dev/null 2>&1; then stat -c '%s' -- "$f"
    elif stat -f '%z' -- "$f" >/dev/null 2>&1; then stat -f '%z' -- "$f"
    else echo 0; fi
  else
    echo 0
  fi
}

# Temp AWK programs (BusyBox-safe)
AWK1="$(mktemp)"; AWK2="$(mktemp)"
trap 'rm -f "$AWK1" "$AWK2" "$TMP_FILES" "$TMP_FILES2" "$TMP_DIR_ENT" "$TMP_SORT" "$DIR_SIGS" "$DIR_SIZE" "$DUP_SIGS" "$BUF_FILE" "$TMP_GROUP" 2>/dev/null || true' EXIT

# AWK1: normalize CSV to h,p,s (size defaults to 0 if absent)
cat > "$AWK1" <<'AWK'
NR==1 && skip==1 { next }
{
  h=$ch; p=$cp; s=(cs>0?$cs:"0")
  gsub(/"/,"",h); gsub(/"/,"",p); gsub(/"/,"",s)
  sub(/^[[:space:]]+/,"",h); sub(/[[:space:]]+$/,"",h)
  sub(/^[[:space:]]+/,"",p); sub(/[[:space:]]+$/,"",p)
  sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s)
  if (s=="") s="0"
  if (h!="" && p!="") print h "," p "," s
}
AWK

# AWK2: explode each file row onto its ancestor dirs (or just leaf), emit dir,rel,h,size
cat > "$AWK2" <<'AWK'
{
  h=$1; p=$2; s=$3+0
  n=split(p, comp, "/")
  start=1; if (comp[1]=="") start=2
  end=n-1
  if (end<start) next
  if (scope=="leaf") {
    i=end
    dir=""; for (k=start; k<=i; k++) { if (comp[k]=="") continue; dir = dir "/" comp[k] }
    rel=""; for (k=i+1; k<=n; k++) { if (comp[k]=="") continue; rel = (rel=="" ? comp[k] : rel "/" comp[k]) }
    print dir "," rel "," h "," s
  } else {
    for (i=start; i<=end; i++) {
      dir=""; for (k=start; k<=i; k++) { if (comp[k]=="") continue; dir = dir "/" comp[k] }
      rel=""; for (k=i+1; k<=n; k++) { if (comp[k]=="") continue; rel = (rel=="" ? comp[k] : rel "/" comp[k]) }
      print dir "," rel "," h "," s
    }
  }
}
AWK

# Extract normalized rows
TMP_FILES="$(mktemp)"
awk -v ch="$COL_HASH" -v cp="$COL_PATH" -v cs="${COL_SIZE:-0}" -v skip="$SKIP_HEADER" -F',' -f "$AWK1" "$INPUT" > "$TMP_FILES"

# If CSV had no size, compute sizes from filesystem (metadata). This can be slow on first run.
if [[ "$SIZE_SOURCE" == "filesystem" ]]; then
  info "Computing file sizes from filesystem metadata (CSV had no size column)..."
  TMP_FILES2="$(mktemp)"
  while IFS=, read -r h p s; do
    sz="$(get_size "$p")"
    printf "%s,%s,%s\n" "$h" "$p" "${sz:-0}" >> "$TMP_FILES2"
  done < "$TMP_FILES"
  mv "$TMP_FILES2" "$TMP_FILES"
  SIZE_AVAILABLE=true
fi

# Build (dir,rel,hash,size)
TMP_DIR_ENT="$(mktemp)"
awk -F',' -v scope="$SCOPE" -f "$AWK2" "$TMP_FILES" > "$TMP_DIR_ENT"

# Empty?
if [[ ! -s "$TMP_DIR_ENT" ]]; then
  info "Verified hashes: no files mapped to directories from $INPUT."
  echo "signature,dir,file_count,total_bytes" > "$OUT_CSV"
  : > "$OUT_SUM"; : > "$OUT_PLAN"
  info "Summary: $OUT_SUM"
  info "CSV:     $OUT_CSV"
  info "Next: please proceed to the duplicate FILE checker."
  exit 0
fi

# Sort: dir, then relpath
TMP_SORT="$(mktemp)"
sort -t, -k1,1 -k2,2 "$TMP_DIR_ENT" > "$TMP_SORT"

# Compute per-dir signature and per-dir total size/files
DIR_SIGS="$(mktemp)"    # sig,dir,file_count
DIR_SIZE="$(mktemp)"    # dir,total_bytes,file_count
BUF_FILE="$(mktemp)"
: > "$BUF_FILE"
current=""; count=0; size_sum=0
while IFS=, read -r dir rel h sz; do
  if [[ -n "$current" && "$dir" != "$current" ]]; then
    sig="$(cat "$BUF_FILE" | hash_string)"
    printf "%s,%s,%d\n" "$sig" "$current" "$count" >> "$DIR_SIGS"
    printf "%s,%s,%d\n" "$current" "$size_sum" "$count" >> "$DIR_SIZE"
    : > "$BUF_FILE"; count=0; size_sum=0
  fi
  current="$dir"
  if [[ "$SIGNATURE_MODE" == "content-only" ]]; then
    printf "%s\n" "$h" >> "$BUF_FILE"
  else
    printf "%s|%s\n" "$rel" "$h" >> "$BUF_FILE"
  fi
  count=$((count+1))
  size_sum=$((size_sum + ${sz:-0}))
done < "$TMP_SORT"
if [[ -n "$current" ]]; then
  sig="$(cat "$BUF_FILE" | hash_string)"
  printf "%s,%s,%d\n" "$sig" "$current" "$count" >> "$DIR_SIGS"
  printf "%s,%s,%d\n" "$current" "$size_sum" "$count" >> "$DIR_SIZE"
fi

# Find duplicate signatures (groups >= MIN_GROUP)
DUP_SIGS="$(mktemp)"
cut -d, -f1 "$DIR_SIGS" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$DUP_SIGS"

# Write CSV header
echo "signature,dir,file_count,total_bytes" > "$OUT_CSV"

# Grouping, summary, and plan
: > "$OUT_SUM"; : > "$OUT_PLAN"
{
  echo "Duplicate Folders — generated $timestamp"
  echo "Source CSV: $INPUT"
  echo "Scope: $SCOPE"
  echo "Signature: $SIGNATURE_MODE"
  echo "Size source: $SIZE_SOURCE"
  echo
} >> "$OUT_SUM"

group_no=0
plan_dirs_bytes=0
plan_dirs_count=0

if [[ -s "$DUP_SIGS" ]]; then
  while IFS= read -r sig; do
    TMP_GROUP="$(mktemp)"
    grep "^$sig," "$DIR_SIGS" | sort -t, -k2,2 > "$TMP_GROUP"

    # Choose keeper
    keep=""; keep_metric=""
    while IFS=, read -r _ d c; do
      case "$KEEP_STRATEGY" in
        shortest-path)
          metric=$(path_len "$d")
          if [[ -z "$keep" || "$metric" -lt "$keep_metric" ]]; then keep="$d"; keep_metric="$metric"; fi ;;
        oldest)
          metric=$(get_mtime "$d")
          if [[ -z "$keep" || "$metric" -lt "$keep_metric" ]]; then keep="$d"; keep_metric="$metric"; fi ;;
        newest)
          metric=$(get_mtime "$d")
          if [[ -z "$keep" || "$metric" -gt "$keep_metric" ]]; then keep="$d"; keep_metric="$metric"; fi ;;
        first|*) keep="${keep:-$d}"; keep_metric=0 ;;
      esac
    done < "$TMP_GROUP"

    echo "─ Group #$((++group_no)) — signature: $sig" >> "$OUT_SUM"
    while IFS=, read -r _ d c; do
      size_line="$(awk -F, -v dd="$d" '$1==dd{print $2","$3; exit}' "$DIR_SIZE")"
      dir_bytes="${size_line%%,*}"; dir_files="${size_line##*,}"
      printf "   - %s  (files: %s, size: %s)\n" "$d" "${dir_files:-$c}" "$(human_bytes "${dir_bytes:-0}")" >> "$OUT_SUM"
      printf "%s,%s,%s,%s\n" "$sig" "$d" "${dir_files:-$c}" "${dir_bytes:-0}" >> "$OUT_CSV"
      if [[ "$d" != "$keep" ]]; then
        echo "$d" >> "$OUT_PLAN"
        plan_dirs_count=$((plan_dirs_count+1))
        plan_dirs_bytes=$((plan_dirs_bytes + ${dir_bytes:-0}))
      fi
    done < "$TMP_GROUP"
    echo "   → keep: $keep" >> "$OUT_SUM"
    echo >> "$OUT_SUM"
    rm -f "$TMP_GROUP"
  done < "$DUP_SIGS"
fi

# Copy "latest" convenience link if plan exists
if [[ -s "$OUT_PLAN" ]]; then
  mkdir -p "$VAR_DIR"
  cp -f "$OUT_PLAN" "$VAR_DIR/latest-folder-plan.txt" || true
fi

# Final UX
if [[ "$MODE" == "plan" ]]; then
  if [[ "$group_no" -gt 0 ]] ; then
    info "Verified hashes, you have duplicate folders:"
    info "- Duplicate groups: $group_no"
    info "- Folders slated for deletion (plan items): $plan_dirs_count"
    if [[ "$SIZE_AVAILABLE" == true ]]; then
      src_label="CSV"
      if [[ "$SIZE_SOURCE" == "filesystem" ]]; then src_label="filesystem metadata"; fi
      info "- Total potential duplicate disk space: $(human_bytes "$plan_dirs_bytes") (via $src_label)"
    else
      info "- Total potential duplicate disk space: unknown"
    fi
    info "Summary: $OUT_SUM"
    info "CSV:     $OUT_CSV"
    info "Plan:    ${VAR_DIR}/latest-folder-plan.txt"
    echo
    echo "Would you like to proceed to review and delete the duplicate folders?"
    echo "Note: do this BEFORE deleting individual files."
    echo
    echo "Apply safely (move to quarantine):"
    echo "  bin/find-duplicate-folders.sh --mode apply --force --quarantine \"var/quarantine/$(date +%F)\""
  else
    info "Verified hashes: zero duplicate folders found (>= $MIN_GROUP)."
    info "Next: please proceed to the duplicate FILE checker for cleanup."
    info "Summary: $OUT_SUM"
    info "CSV:     $OUT_CSV"
  fi
fi

# Apply mode
if [[ "$MODE" == "apply" ]]; then
  [[ "$FORCE" == true ]] || { err "--mode apply requires --force"; exit 1; }
  if [[ ! -s "$OUT_PLAN" ]]; then
    warn "No entries to act on."; exit 0
  fi
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
fi
