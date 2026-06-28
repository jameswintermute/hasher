#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

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
#
# FIX (v1.3.1 — item 1, CRITICAL): the previous parser used FS="," with fixed
# field numbers. hasher.sh writes RFC4180-style CSV in which any path
# containing a comma (or quote) is double-quoted, e.g.
#     "/photos/Smith, John.jpg",1024,1700000000,sha256,abcd...
# A naive comma split shifts every field right, so the script grabbed the
# wrong columns — it would treat the literal string "sha256" as the hash and
# truncate the path at the first comma. That mis-grouped unrelated files AND
# emitted delete plans pointing at non-existent truncated paths: a real
# data-loss risk. We now parse CSV quote-aware (a proper RFC4180 field split
# that respects double-quoted fields and "" escapes), then index by the
# detected/declared column numbers against the CORRECTLY split fields. TSV
# inputs (DELIM='\t') are split on tab with no quote handling, which is
# correct for TSV.
awk -v ch="$COL_HASH" -v cp="$COL_PATH" -v cs="${COL_SIZE:-0}" -v skip="$SKIP_HEADER" -v DELIM="$DELIM" '
  # Quote-aware splitter: fills global array F[1..nf] from line s using sep.
  # Honours RFC4180 double-quoting only when sep is comma; for any other sep
  # (e.g. tab) it splits plainly. Returns nf.
  function csv_split(s, sep,    i, c, nf, cur, inq, n) {
    n = length(s); nf = 0; cur = ""; inq = 0;
    if (sep != ",") {            # plain split for TSV/other
      nf = split(s, A, sep);
      for (i=1;i<=nf;i++) F[i]=A[i];
      return nf;
    }
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1);
      if (inq) {
        if (c == "\"") {
          if (substr(s, i+1, 1) == "\"") { cur = cur "\""; i++; }  # "" -> literal "
          else { inq = 0; }                                        # closing quote
        } else { cur = cur c; }
      } else {
        if (c == "\"") { inq = 1; }
        else if (c == sep) { F[++nf] = cur; cur = ""; }
        else { cur = cur c; }
      }
    }
    F[++nf] = cur;
    return nf;
  }
  BEGIN{ OFS="\t" }   # FIX (v1.3.1): intermediate is TAB-separated so paths
                      # containing commas survive downstream awk -F parsing.
  NR==1 && skip==1 { next }
  {
    nf = csv_split($0, DELIM);
    h = (ch <= nf ? F[ch] : "");
    p = (cp <= nf ? F[cp] : "");
    s = (cs > 0 && cs <= nf ? F[cs] : "");
    # trim whitespace (quotes already consumed by the splitter)
    sub(/^[ \t\r\n]+/,"",h); sub(/[ \t\r\n]+$/,"",h);
    sub(/^[ \t\r\n]+/,"",p); sub(/[ \t\r\n]+$/,"",p);
    sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s);
    # guard: a literal tab in a path would corrupt the TSV; replace with space.
    gsub(/\t/," ",p);
    k = h SUBSEP p;
    if (h!="" && p!="" && !seen[k]++) print h, p, s;
  }
' "$INPUT" > "$TMP"

if [[ ! -s "$TMP" ]]; then
  err "Parsed 0 rows from input. Detected delimiter: '$(printf "%q" "$DELIM")'. Header: '$header'"
  err "Sample line 2: '$second'"
  exit 2
fi

# Pre-compute counts by hash (>= MIN_GROUP)
HASHES_TMP="$(mktemp)"; trap 'rm -f "$TMP" "$HASHES_TMP"' EXIT
cut -d"$(printf '\t')" -f1 "$TMP" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$HASHES_TMP"

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

# Keep only rows belonging to duplicate hashes.
# FIX (v1.2.0): match strictly on the hash column (field 1), not an unanchored
# substring of the whole line, so a hash embedded in a path can't pull in
# unrelated rows.
# FIX (v1.3.1): intermediate is now TAB-separated (see parser above), so the
# field separator here is a tab — this also means a comma in a path no longer
# breaks the column split.
awk -F'\t' '
  NR==FNR { want[$1]=1; next }       # first file: the wanted hashes
  ($1 in want)                       # second file: keep rows whose col-1 hash matches
' "$HASHES_TMP" "$TMP" > "$OUT_CSV" || true

# Single-pass AWK to render canonical + groups; avoids bash loops under set -e
# (intermediate is TAB-separated since v1.3.1)
awk -F'\t' -v min="$MIN_GROUP" \
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
  # Build a naive plan honouring KEEP_STRATEGY.
  # FIX (v1.1.9): emit KEEP|path / DEL|path lines so delete-duplicates.sh
  # actually consumes the plan. Previously this wrote bare paths and
  # delete-duplicates.sh silently ignored every entry (it only acts on
  # lines matching '^DEL|').
  : > "$OUT_PLAN"
  awk -F'\t' -v strategy="$KEEP_STRATEGY" '
    {
      h=$1; p=$2;
      paths[h,++idx[h]]=p
      len=length(p)
      if (!has_best[h]) {
        best[h]=p; bestlen[h]=len; has_best[h]=1
      } else if (strategy=="longest-path") {
        if (len > bestlen[h]) { best[h]=p; bestlen[h]=len }
      } else {
        # default: shortest-path (also covers any unrecognised value;
        # mtime-based strategies need stat() and live in auto-dedup.sh)
        if (len < bestlen[h]) { best[h]=p; bestlen[h]=len }
      }
    }
    END {
      for (h in idx) {
        if (idx[h] >= 2) {
          k=best[h]
          # Emit KEEP first, then DEL for every other path in the group.
          # v1.2.0: DEL lines carry the group hash (h) as a third field so
          # delete-duplicates.sh can re-verify content before quarantining.
          printf "KEEP|%s\n", k
          for (i=1;i<=idx[h];i++) { p=paths[h,i]; if (p!=k) printf "DEL|%s|%s\n", p, h }
        }
      }
    }
  ' "$OUT_CSV" >> "$OUT_PLAN"
  if [[ -s "$OUT_PLAN" ]]; then
    info "Auto delete plan: $OUT_PLAN"
    cp -f "$OUT_PLAN" "$VAR_DIR/latest-plan.txt"
    info "Latest plan copied to: $VAR_DIR/latest-plan.txt"
    info "Apply with: bin/delete-duplicates.sh \"$OUT_PLAN\""
  else
    warn "Bulk mode produced no deletable items (unexpected)."
  fi
else
  info "Next: run 'review-duplicates.sh --from-report \"$OUT_CANON\"' (or menu option 4)."
  cp -f "$OUT_CANON" "$OUT_LATEST" 2>/dev/null || true
  info "Canonical report ready: $OUT_LATEST"
fi
