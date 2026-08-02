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
                          [--allow-malformed-rows]
                          [--build-review-index|--no-review-index]
Outputs:
  - Canonical: logs/duplicate-hashes-YYYY-MM-DD-HHMMSS-PID.txt   (per-run)
  - Latest:    logs/duplicate-hashes-latest.txt                  (symlink to newest)
  - Summary:   logs/duplicate-groups-YYYY-MM-DD-HHMMSS-PID.txt
  - Flat TSV:  logs/duplicates-YYYY-MM-DD-HHMMSS-PID.csv
  - Review index: logs/duplicate-review-index-YYYY-MM-DD-HHMMSS-PID.tsv
                  (sorted by potential reclaim; built by default)
Bulk mode also writes:
  - Plan:      logs/review-dedupe-plan-YYYY-MM-DD-HHMMSS-PID.txt
EOF
}

# Defaults
INPUT=""
MODE="standard"        # standard | bulk
MIN_GROUP=2
KEEP_STRATEGY="shortest-path"
ALLOW_MALFORMED=0
BUILD_REVIEW_INDEX=1

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --min-group-size) MIN_GROUP="${2:-}"; shift 2 ;;
    --keep-strategy) KEEP_STRATEGY="${2:-}"; shift 2 ;;
    --allow-malformed-rows) ALLOW_MALFORMED=1; shift ;;
    --build-review-index) BUILD_REVIEW_INDEX=1; shift ;;
    --no-review-index) BUILD_REVIEW_INDEX=0; shift ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

date_tag="$(date +'%Y-%m-%d')"
# v1.3.23 (peer-review recheck finding #5): include $$ in the timestamp
# so two runs within the same second cannot overwrite each other's
# artefacts. Matches the CSV_TAG convention hasher.sh has used since
# v1.3.16 (F-HMS-PID).
timestamp="$(date +'%Y-%m-%d-%H%M%S')-$$"

# v1.3.23 (peer-review recheck finding #5): the canonical file used to be
# `${date_tag}-duplicate-hashes.txt` — date only, so a second same-day run
# overwrote the first, potentially breaking next-step commands from earlier
# runs. Now every derived file uses the full run tag; the -latest.txt
# symlink is what next-step commands point at, so they remain stable while
# per-run history accumulates. Mirrors the pattern hasher.sh post_run_reports
# has used since v1.3.19.
OUT_CANON="$LOGS_DIR/duplicate-hashes-$timestamp.txt"
OUT_GROUPS="$LOGS_DIR/duplicate-groups-$timestamp.txt"
OUT_CSV="$LOGS_DIR/duplicates-$timestamp.csv"
OUT_PLAN="$LOGS_DIR/review-dedupe-plan-$timestamp.txt"  # only when bulk
OUT_INDEX="$LOGS_DIR/duplicate-review-index-$timestamp.tsv"
OUT_INDEX_LATEST="$LOGS_DIR/duplicate-review-index-latest.tsv"
OUT_LATEST="$LOGS_DIR/duplicate-hashes-latest.txt"

# Publish the completed run-specific report without ever opening the existing
# latest pointer for writing.  v1.3.25 truncated the previous historical report
# because `: > "$OUT_LATEST"` followed the symlink, then AWK wrote new content
# through the same link.  Build a replacement beside it and atomically rename.
publish_latest_report() {
  local tmp_latest="$OUT_LATEST.tmp.$$"
  rm -f -- "$tmp_latest" 2>/dev/null || true
  if ln -s -- "$(basename "$OUT_CANON")" "$tmp_latest" 2>/dev/null; then
    mv -f -- "$tmp_latest" "$OUT_LATEST"
  else
    cp -f -- "$OUT_CANON" "$tmp_latest" || return 1
    mv -f -- "$tmp_latest" "$OUT_LATEST"
  fi
}

publish_latest_index() {
  local tmp_latest="$OUT_INDEX_LATEST.tmp.$$"
  rm -f -- "$tmp_latest" 2>/dev/null || true
  if ln -s -- "$(basename "$OUT_INDEX")" "$tmp_latest" 2>/dev/null; then
    mv -f -- "$tmp_latest" "$OUT_INDEX_LATEST"
  else
    cp -f -- "$OUT_INDEX" "$tmp_latest" || return 1
    mv -f -- "$tmp_latest" "$OUT_INDEX_LATEST"
  fi
}

write_review_index_header() {
  {
    printf '# HASHER_DUPLICATE_REVIEW_INDEX v1\n'
    printf '# source-report: %s\n' "$(basename "$OUT_CANON")"
    printf '# source-csv: %s\n' "$INPUT"
    printf '# columns: group_no\tpotential_bytes\tmember_count\tfirst_path\thash\tbase_size\n'
  } > "$OUT_INDEX"
}

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

# v1.3.19 (peer-review finding #4): dedupe workflows only speak SHA-256
# since v1.3.16. The hash column name must be one that could plausibly
# carry SHA-256 (`hash`, `digest`, `checksum`, `sha256`). Explicitly named
# non-SHA-256 columns (md5, sha1, sha512, blake2*) are rejected up front
# rather than accepted and then generating unusable plans that fail at
# delete-duplicates.sh apply-time.
COL_HASH="$(find_hdr_idx 'hash|digest|checksum|sha256')"
COL_PATH="$(find_hdr_idx 'path|filepath|file|fullpath')"
COL_SIZE="$(find_hdr_idx 'size|size_bytes|bytes|filesize|size_mb')"
# v1.3.23 (peer-review recheck observation B): also locate the algo column
# if the CSV has one. hasher.sh writes 'algo' as column 4 in its default
# layout. When present, every row's algo value must equal 'sha256' — an
# external manifest that says algo=md5 but has 64-char values would
# otherwise pass the hex/length preflight and enter dedupe with misleading
# reports.
COL_ALGO="$(find_hdr_idx 'algo|algorithm')"
# If no SHA-256-capable column was found, check whether the CSV explicitly
# names a non-SHA-256 hash algorithm — that's a clearer error message than
# "no hash column found".
if [[ -z "$COL_HASH" ]]; then
  _wrong="$(find_hdr_idx 'md5|sha1|sha512|blake2|blake2b|blake2s')"
  if [[ -n "$_wrong" ]]; then
    printf '[ERROR] Manifest column is non-SHA-256 (md5/sha1/sha512/blake2*).\n' >&2
    printf '[ERROR] This release only supports SHA-256 for dedupe workflows.\n' >&2
    printf '[ERROR] Re-run bin/hasher.sh (which enforces sha256) to regenerate the CSV.\n' >&2
    exit 2
  fi
fi

if [[ -n "$COL_HASH" && -n "$COL_PATH" ]]; then
  SKIP_HEADER=1
else
  SKIP_HEADER=0
  COL_HASH="${COL_HASH:-5}"   # for hasher CSV: path,size_bytes,mtime_epoch,algo,hash
  COL_PATH="${COL_PATH:-1}"
  COL_SIZE="${COL_SIZE:-2}"
fi

# v1.3.19 (peer-review finding #4): the hash column NAME can look right
# while values inside it are non-SHA-256 (MD5=32 hex, SHA1=40, SHA512=128).
# v1.3.20 (recheck finding #1): validate the hash column of EVERY data row
# using the same quote-aware CSV parser the main script uses. Previous
# implementation had two bugs — used naïve `awk -F,` which mis-splits paths
# containing commas (e.g. "a,b.txt") and only checked the FIRST row (so a
# mixed manifest with a valid SHA-256 first row and later MD5 rows passed).
if [[ -f "$INPUT" ]]; then
  # v1.3.27: malformed rows are fatal by default. A partially written or
  # damaged manifest must not produce an actionable deletion plan while silently
  # omitting records. `--allow-malformed-rows` is available only for explicit
  # forensic/recovery use and never changes the SHA-256 validation policy.
  #
  # awk block prints reason to stderr and exits non-zero if any actionable
  # row has a wrong-length or non-hex hash, or (when COL_ALGO is present)
  # an algorithm that isn't sha256.
  awk -v skip="$SKIP_HEADER" -v ch="$COL_HASH" -v ca="${COL_ALGO:-0}" \
      -v cp="$COL_PATH" -v DELIM="$DELIM" -v allow="$ALLOW_MALFORMED" '
    function csv_split(s, sep,    i, c, nf, cur, inq, n) {
      n = length(s); nf = 0; cur = ""; inq = 0
      if (sep != ",") { nf = split(s, A, sep); for (i=1;i<=nf;i++) F[i]=A[i]; return nf }
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr(s, i+1, 1) == "\"") { cur = cur "\""; i++ }
            else { inq = 0 }
          } else { cur = cur c }
        } else {
          if (c == "\"") { inq = 1 }
          else if (c == sep) { F[++nf] = cur; cur = "" }
          else { cur = cur c }
        }
      }
      F[++nf] = cur
      return nf
    }
    function lc(s,    r) { r = tolower(s); return r }
    NR <= skip { next }
    {
      nf = csv_split($0, DELIM)
      # Detect malformed rows: fewer fields than the maximum column index
      # we need to read (hash, path, size, algo).
      maxcol = ch
      if (cp+0 > maxcol) maxcol = cp+0
      if (ca+0 > maxcol) maxcol = ca+0
      if (nf < maxcol) {
        malformed++
        if (malformed == 1) first_malformed_line = NR
        next
      }
      h = F[ch+0]
      gsub(/^"|"$/, "", h)
      if (h == "") next  # blank rows are ignored, matching the main parser
      if (length(h) != 64) {
        printf "[ERROR] Row %d: hash column has length %d (expected 64 hex): %s\n", NR, length(h), h > "/dev/stderr"
        bad = 1; exit 2
      }
      if (h !~ /^[0-9a-fA-F]+$/) {
        printf "[ERROR] Row %d: hash column contains non-hex characters: %s\n", NR, h > "/dev/stderr"
        bad = 1; exit 2
      }
      # Algo validation — only when the CSV explicitly names the column.
      # A missing algo column (older manifests) is fine.
      if (ca+0 > 0) {
        a = F[ca+0]
        gsub(/^"|"$/, "", a)
        if (a != "" && lc(a) != "sha256") {
          printf "[ERROR] Row %d: algo column is %s (expected sha256).\n", NR, a > "/dev/stderr"
          bad = 1; exit 2
        }
      }
      valid++
    }
    END {
      if (bad) exit 2
      if (malformed > 0) {
        if (allow == "0") {
          printf "[ERROR] Malformed rows: %d (first malformed at line %d). Refusing to generate a plan.\n", malformed, first_malformed_line > "/dev/stderr"
          exit 3
        }
        printf "[WARN] Malformed rows: %d (first malformed at line %d) — explicitly allowed.\n", malformed, first_malformed_line > "/dev/stderr"
        printf "[WARN] Valid rows retained: %d.\n", valid > "/dev/stderr"
      }
    }
  ' "$INPUT" || _rc=$?
  _rc=${_rc:-0}
  if [[ "$_rc" -eq 2 ]]; then
    printf '[ERROR] Manifest failed SHA-256 preflight. Regenerate with bin/hasher.sh.\n' >&2
    exit 2
  elif [[ "$_rc" -eq 3 ]]; then
    printf '[ERROR] Manifest contains malformed rows. Regenerate it, or use --allow-malformed-rows only for forensic recovery.\n' >&2
    exit 2
  fi
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
HASHES_TMP="$(mktemp)"
OUT_INDEX_RAW="$(mktemp "$VAR_DIR/review-index-raw.XXXXXX")"
trap 'rm -f "$TMP" "$HASHES_TMP" "$OUT_INDEX_RAW" "${_hl_csv:-}" "${_hl_paths0:-}" "${_hl_stats:-}"' EXIT
cut -d"$(printf '\t')" -f1 "$TMP" | sort | uniq -c | awk -v m="$MIN_GROUP" '$1>=m {print $2}' > "$HASHES_TMP"

# v1.3.28: embed provenance in the canonical report. Review and auto-dedup
# refuse reports that were not produced by this finder, preventing the raw
# post-hash duplicate summary from bypassing hard-link filtering.
printf '# HASHER_VERIFIED_DUPLICATE_REPORT v1\n# source-csv: %s\n' "$INPUT" > "$OUT_CANON"
: > "$OUT_GROUPS"
: > "$OUT_CSV"

if [[ ! -s "$HASHES_TMP" ]]; then
  warn "No duplicate groups found (>= $MIN_GROUP)."
  info "Canonical report (empty): $OUT_CANON"
  info "Group summary:           $OUT_GROUPS"
  : > "$OUT_CSV"
  printf '# hardlink-filter: not-required\n' >> "$OUT_CANON"
  publish_latest_report || warn "Could not update latest report pointer: $OUT_LATEST"
  if [[ "$BUILD_REVIEW_INDEX" -eq 1 ]]; then
    write_review_index_header
    publish_latest_index || warn "Could not update latest review-index pointer: $OUT_INDEX_LATEST"
    info "Review index (empty):    $OUT_INDEX"
  fi
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

# Before OUT_CSV is consumed by the canonical-report awk or the bulk-mode
# planner, collapse paths that are hard links to the same physical inode.
# Moving a second directory entry for the same inode reclaims no data and can
# consume additional space if quarantine is on another filesystem.
#
# Performance note: stat flavour is detected ONCE and paths are passed to stat
# in batches.  The previous implementation called a shell function through a
# command substitution for every duplicate path, spawning stat + tr processes
# one file at a time.  On a NAS with tens of thousands of duplicate candidates
# that could take many minutes with no output.
_hardlinks_log="$LOGS_DIR/hardlinks-excluded-$timestamp.log"
_hl_csv="$OUT_CSV.hlfilt.$$"
_hl_paths0="$(mktemp)"
_hl_stats="$(mktemp)"
trap 'rm -f "$TMP" "$HASHES_TMP" "$OUT_INDEX_RAW" "${_hl_csv:-}" "${_hl_paths0:-}" "${_hl_stats:-}"' EXIT
: > "$_hardlinks_log"
: > "$_hl_csv"
: > "$_hl_paths0"
: > "$_hl_stats"

_hl_candidates=$(wc -l < "$OUT_CSV" 2>/dev/null | tr -d ' ' || echo 0)
[[ -z "$_hl_candidates" ]] && _hl_candidates=0

# The hash manifest rejects TAB/LF/CR in paths, so a tab-separated stat map is
# safe here.  The original paths are still fed to stat as NUL-delimited input.
while IFS=$'\t' read -r _h _p _s; do
  [[ -n "$_p" ]] && printf '%s\0' "$_p"
done < "$OUT_CSV" > "$_hl_paths0"

_stat_style=""
_stat_fmt=""
if stat -c $'%d\t%i\t%n' /dev/null >/dev/null 2>&1; then
  _stat_style="gnu"
  _stat_fmt=$'%d\t%i\t%n'
elif stat -f $'%d\t%i\t%N' /dev/null >/dev/null 2>&1; then
  _stat_style="bsd"
  _stat_fmt=$'%d\t%i\t%N'
fi

_hl_filter_status="not-required"
if [[ "$_hl_candidates" -gt 0 && -n "$_stat_style" ]]; then
  _hl_filter_status="applied"
  info "Checking $_hl_candidates duplicate candidate path(s) for hard links..."

  # xargs batches paths so stat is invoked once per block rather than once per
  # file.  A missing file makes stat/xargs non-zero; those paths simply have no
  # map entry and are passed through as unique below.
  if [[ "$_stat_style" == "gnu" ]]; then
    if ! xargs -0 -n 256 stat -c "$_stat_fmt" -- < "$_hl_paths0" > "$_hl_stats" 2>/dev/null; then
      warn "Some duplicate candidate paths could not be stat'ed; treating them as unique."
    fi
  else
    if ! xargs -0 -n 256 stat -f "$_stat_fmt" < "$_hl_paths0" > "$_hl_stats" 2>/dev/null; then
      warn "Some duplicate candidate paths could not be stat'ed; treating them as unique."
    fi
  fi

  # First file builds path -> device|inode.  Second file is the duplicate CSV.
  # Within each hash group, keep only the first path for each physical inode.
  awk -F'\t' -v OFS='\t' -v logf="$_hardlinks_log" '
    NR==FNR {
      if (NF >= 3) {
        path=$3
        # Defensive: if a stat implementation ever places tabs in the final
        # name field, reconstruct it.  Hasher normally rejects such paths.
        for (i=4; i<=NF; i++) path=path FS $i
        devino[path]=$1 "|" $2
      }
      next
    }
    {
      h=$1; p=$2; s=$3
      di=devino[p]
      if (di == "") { print h,p,s; next }
      k=h SUBSEP di
      if (k in first) {
        printf "HARDLINK\t%s\tsame-inode-as\t%s\n", p, first[k] >> logf
      } else {
        first[k]=p
        print h,p,s
      }
    }
  ' "$_hl_stats" "$OUT_CSV" > "$_hl_csv"
else
  if [[ "$_hl_candidates" -gt 0 ]]; then
    _hl_filter_status="skipped"
    warn "Could not detect a compatible stat format; hard-link filtering skipped."
  fi
  cp -f -- "$OUT_CSV" "$_hl_csv"
fi

_hl_lines=$(wc -l < "$_hardlinks_log" 2>/dev/null | tr -d ' ' || echo 0)
[[ -z "$_hl_lines" ]] && _hl_lines=0
if [[ "$_hl_lines" -gt 0 ]]; then
  warn "$_hl_lines path(s) excluded: hard links to a kept file."
  warn "  Details: $_hardlinks_log"
  warn "  (Moving these would NOT reclaim space; they share an inode with the KEEP path.)"
else
  rm -f -- "$_hardlinks_log" 2>/dev/null || true
fi
mv -f -- "$_hl_csv" "$OUT_CSV"
rm -f -- "$_hl_paths0" "$_hl_stats" 2>/dev/null || true
printf '# hardlink-filter: %s\n' "$_hl_filter_status" >> "$OUT_CANON"

# Single-pass AWK to render canonical + groups; avoids bash loops under set -e
# (intermediate is TAB-separated since v1.3.1)
awk -F'\t' -v min="$MIN_GROUP" \
  -v canon="$OUT_CANON" -v groups="$OUT_GROUPS" \
  -v buildindex="$BUILD_REVIEW_INDEX" -v indexraw="$OUT_INDEX_RAW" '
  function flush(h,   n,i,p,s,base,pot) {
    n = cnt[h]; if (n < min) return
    group++
    printf "HASH %s (N=%d)\n", h, n >> canon
    printf "─ Group #%d — hash: %s\n", group, h >> groups
    base=0
    for (i=1;i<=idx[h];i++) {
      p = order[h,i]; s = size[h,p]
      if (i == 1 && s ~ /^[0-9]+$/) base=s+0
      printf "  %s\n", p >> canon
      if (s != "") printf "   %2d) %s  (size: %s)\n", i, p, s >> groups
      else         printf "   %2d) %s\n", i, p >> groups
    }
    pot=(n-1)*base
    if (buildindex == 1)
      printf "%d\t%.0f\t%d\t%s\t%s\t%.0f\n", group, pot, n, order[h,1], h, base >> indexraw
    printf "\n" >> canon; printf "\n" >> groups
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

# v1.3.30: the finder already has each group hash, count and manifest size,
# so create the reusable savings index here instead of making interactive
# review stat one live file for every group. The group number is emitted by
# the same AWK flush that writes the canonical report, keeping both artefacts
# structurally tied to this exact finder run.
if [[ "$BUILD_REVIEW_INDEX" -eq 1 ]]; then
  write_review_index_header
  if [[ -s "$OUT_INDEX_RAW" ]]; then
    LC_ALL=C sort -t $'\t' -nr -k2,2 -k1,1 "$OUT_INDEX_RAW" >> "$OUT_INDEX"
  fi
  info "Review index:     $OUT_INDEX"
fi

# Footer
groups_count="$(grep -c '^HASH ' "$OUT_CANON" || true)"
info "Groups: $groups_count"
info "Canonical report: $OUT_CANON"
info "Flat CSV:         $OUT_CSV"
info "Group summary:    $OUT_GROUPS"

if [[ "$MODE" == "bulk" ]]; then
  # Build a naive plan honouring KEEP_STRATEGY.
  # FIX (v1.1.9): emit KEEP/DEL plan lines so delete-duplicates.sh
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
          # v1.3.28: KEEP and DEL lines carry the group hash so apply can
          # re-verify both the surviving keeper and each quarantined file.
          printf "KEEP|%s|%s\n", k, h
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
fi

# Standard and bulk modes both publish the immutable run-specific canonical
# report only after all rendering/planning work has completed.
if publish_latest_report; then
  info "Canonical report ready: $OUT_LATEST"
else
  warn "Could not update latest report pointer: $OUT_LATEST"
fi
if [[ "$BUILD_REVIEW_INDEX" -eq 1 ]]; then
  if publish_latest_index; then
    info "Prepared review index ready: $OUT_INDEX_LATEST"
  else
    warn "Could not update latest review-index pointer: $OUT_INDEX_LATEST"
  fi
fi
