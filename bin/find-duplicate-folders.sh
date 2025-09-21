#!/usr/bin/env bash
# find-duplicate-folders.sh — Hasher: detect duplicate folders
# Safe-by-default; no deletes. Emits a report grouping identical folders.
# Copyright (C) 2025 James
# License: GPLv3

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ────────────────────────────── Layout ───────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs"
HASHES_DIR="$ROOT_DIR/hashes"
VAR_DIR="$ROOT_DIR/var"
mkdir -p "$LOGS_DIR" "$VAR_DIR"

# ───────────────────────────── Defaults ──────────────────────────────
HASHES_FILE=""
SCOPE="recursive"            # recursive|shallow
SIGNATURE="name+content"     # name|name+size|name+content
MIN_GROUP_SIZE=2
KEEP="shortest-path"         # informational only in this step
RUN_ID="$(date +%s)"
REPORT="$LOGS_DIR/duplicate-folders-$(date +%F)-$RUN_ID.txt"
INDEX_TSV="$VAR_DIR/dupfolders-index-$RUN_ID.tsv"
SORTED_TSV="$VAR_DIR/dupfolders-sorted-$RUN_ID.tsv"

# ───────────────────────────── Logging ───────────────────────────────
log_info() { printf '[INFO] %s\n' "$*"; }
log_work() { printf '[WORK] %s\n' "$*"; }
log_ok()   { printf '[OK] %s\n'   "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_err()  { printf '[ERR ] %s\n' "$*" >&2; }

pause()    { read -r -p "Press Enter to continue..." _ || true; }

# ───────────────────────────── Args ──────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [--hashes-file FILE] [--scope recursive|shallow]
                         [--signature name|name+size|name+content]
                         [--min-group-size N] [--keep policy]

Find duplicate folders by comparing normalized file inventories.

Outputs: $REPORT
EOF
  exit 1
}

while (($#)); do
  case "$1" in
    --hashes-file) HASHES_FILE="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --signature) SIGNATURE="${2:-}"; shift 2 ;;
    --min-group-size|--min) MIN_GROUP_SIZE="${2:-}"; shift 2 ;;
    --keep) KEEP="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) log_warn "Unknown arg: $1"; shift ;;
  esac
done

if [[ -z "${HASHES_FILE:-}" ]]; then
  HASHES_FILE="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
fi
[[ -f "${HASHES_FILE:-/nope}" ]] || { log_err "Hashes file not found."; pause; exit 1; }

# ─────────────────────────── Prologue ────────────────────────────────
log_info "Using hashes file: $HASHES_FILE"
# Quarantine line mirrors launcher style (informational only)
if df_out=$(df -h "$ROOT_DIR" 2>/dev/null | awk 'NR==2{print $4" free on "$1" ("$6")"}'); then
  log_info "Quarantine: $ROOT_DIR/quarantine-$(date +%F) — $df_out"
fi
log_info "Input: $HASHES_FILE"
log_info "Mode: plan  | Min group size: $MIN_GROUP_SIZE | Scope: $SCOPE | Keep: $KEEP | Signature: $SIGNATURE"
log_info "Using size_bytes from CSV/TSV (fast path)."

# ───────────────── Step 1: Build a simple index ─────────────────────
# TSV columns: dir<TAB>relpath<TAB>size<TAB>hash
# We auto-detect header columns (path, size_bytes, hash). Paths are assumed
# to be comma-safe (Hasher default).
log_work "Indexing files (fast path)…"
awk -v OFS='\t' -v scope="$SCOPE" '
  BEGIN{FS=","; P=0; S=0; H=0}
  NR==1{
    for(i=1;i<=NF;i++){
      f=tolower($i)
      if(f ~ /(^|_)path($|_)/) P=i
      else if(f ~ /size(_?bytes)?/) S=i
      else if(f ~ /(^|_)hash($|_)/) H=i
    }
    if(!P){P=1} # fallbacks
    next
  }
  {
    p=$P
    gsub(/^"+|"+$/,"",p)
    # derive filename + parent directory
    name=p; sub(/.*\//,"",name)
    dir=p; sub(/\/[^/]+$/,"",dir); if(dir=="") dir="/"
    size=(S? $S : 0)
    hash=(H? $H : "")
    if(scope=="shallow"){
      print dir, name, size, hash
    } else {
      # emit for each ancestor so we can compare recursively
      n=split(dir, parts, "/")
      path_acc=""
      for(i=1;i<=n;i++){
        if(i==1 && parts[i]=="") { path_acc="/"; next }  # leading /
        path_acc=(path_acc=="/" ? "/" parts[i] : path_acc "/" parts[i])
        rel=p
        sub("^" path_acc "/?", "", rel)
        print path_acc, rel, size, hash
      }
      if(dir=="/"){ print "/", name, size, hash }
    }
  }
' "$HASHES_FILE" > "$INDEX_TSV"

total_lines=$(wc -l < "$INDEX_TSV" | tr -d ' ')
log_work "indexing files 100% ($total_lines/$total_lines)"
log_work "Sorting index..."
LC_ALL=C sort -t $'\t' -k1,1 -k2,2 "$INDEX_TSV" > "$SORTED_TSV"
log_ok  "Sorting complete."

# ────────── Step 2: Group by normalized folder inventory ────────────
# No process-substitution; pure pipes/redirections to avoid '>' parse faults.
# Progress heartbeat every 15s.
log_work "Scanning & grouping (this can take a while)…"
{
  echo "# duplicate-folders report"
  echo "# generated: $(date -Is)"
  echo "# source: $(basename "$HASHES_FILE")"
  echo "# scope=$SCOPE signature=$SIGNATURE min_group_size=$MIN_GROUP_SIZE keep=$KEEP"
  echo
} > "$REPORT"

awk -v FS='\t' -v OFS='\t' -v sig="$SIGNATURE" -v min="$MIN_GROUP_SIZE" -v total="$total_lines" '
  function heartbeat(force){
    now=systime()
    if(force || now-last>=15){
      pct = (processed>0 && total>0) ? int(processed*100/total) : 0
      printf("[PROGRESS] Grouping: %d%% (%d/%d)\n", pct, processed, total) > "/dev/stderr"
      last=now
    }
  }
  function flush_prev() {
    if(prev_dir=="") return
    # sort keys to normalize inventory (order-insensitive)
    n=asorti(keys, idx)
    blob=""
    for(i=1;i<=n;i++){ if(keys[idx[i]]!="") blob = blob keys[idx[i]] "\034" } # unit sep
    dir_sig[prev_dir]=blob
    delete keys
  }
  {
    dir=$1; rel=$2; size=$3; hash=$4
    k = (sig=="name") ? rel : (sig=="name+size" ? rel "|" size : rel "|" hash)
    if(dir!=prev_dir){
      flush_prev()
      prev_dir=dir
    }
    keys[k]=k
    processed++
    heartbeat(0)
  }
  END{
    flush_prev()
    # invert: signature -> list of dirs
    for(d in dir_sig){
      s=dir_sig[d]
      cnt[s]++
      list[s] = list[s] d "\n"
    }
    groups=0
    for(s in cnt){
      if(cnt[s] >= min){
        groups++
        printf("GROUP %d (dirs=%d)\n", groups, cnt[s]) >> report
        printf("%s\n", list[s]) >> report
      }
    }
    heartbeat(1)
  }
' report="$REPORT" "$SORTED_TSV"

log_ok  "Report written: $REPORT"
echo
pause
