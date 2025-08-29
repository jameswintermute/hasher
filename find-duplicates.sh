#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder (Find Duplicates - Summary)
# Copyright (C) 2025 James Wintermute <jameswinter@protonmail.ch>
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Defaults ─────────────────────────
HASH_DIR="hashes"
DUP_DIR="duplicate-hashes"
LOGS_DIR="logs"
CONFIG_FILE=""

# [logging] defaults (overridden by config)
PROGRESS_INTERVAL=15
LOG_LEVEL="info"    # debug|info|warn|error
XTRACE=false

# [review] defaults (overridden by config) — shared semantics with review-duplicates.sh
RV_INPUT="latest"             # latest|prompt|<filename>
RV_SORT="count_desc"          # count_desc|size_desc|hash_asc
RV_SKIP_ZERO=true             # skip_zero_size
RV_MIN_MB="0.00"              # min_size_mb
RV_INCLUDE_REGEX=""           # include_regex (POSIX ERE)
RV_EXCLUDE_REGEX=""           # exclude_regex (POSIX ERE)
RV_REPORT_DIR="$DUP_DIR"      # report_dir
RV_REPORT_PREFIX_DATE=true    # report_prefix_date
RV_SUMMARY_LIMIT=0            # summary_limit_groups (0 = all)

# runtime
RUN_ID=""
LOG_FILE=""
BACKGROUND_LOG=""
INPUT_FILE=""

# ───────────────────────── Utilities ─────────────────────────
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
gen_run_id(){
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}
lvl_rank(){ case "$1" in debug)echo 10;;info)echo 20;;warn)echo 30;;error)echo 40;;*)echo 20;;esac; }
LOG_RANK="$(lvl_rank "$LOG_LEVEL")"
_log_core(){
  local level="$1"; shift
  local line; line=$(printf '[%s] [RUN %s] [%s] %s\n' "$(ts)" "$RUN_ID" "$level" "$*")
  printf '%s\n' "$line"
  { printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}
log(){ local level="$1"; shift||true; local want; want=$(lvl_rank "$level"); (( want >= LOG_RANK )) && _log_core "$level" "$@"; }
die(){ _log_core ERROR "$*"; exit 1; }

usage(){
  cat <<EOF
Usage:
  $(basename "$0") [--input hashes/hasher-YYYY-MM-DD.csv] [--config hasher.conf]

Produces a quick duplicate summary:
- Counts duplicate hash groups and files
- Sums total duplicate storage (MB)
- Lists groups sorted by configured strategy

Honours [logging] and [review] (filters/sort) from hasher.conf.
EOF
}

# ───────────────────────── INI parser ─────────────────────────
parse_ini(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  local section="" line raw key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    raw="${line%%[#;]*}"
    raw="$(echo -n "$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$raw" ]] && continue
    if [[ "$raw" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1],,}"; continue; fi
    case "$section" in
      logging)
        if [[ "$raw" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
          key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
          case "$key" in
            background-interval|progress-interval) [[ "$val" =~ ^[0-9]+$ ]] && PROGRESS_INTERVAL="$val" ;;
            level) LOG_LEVEL="${val,,}"; LOG_RANK="$(lvl_rank "$LOG_LEVEL")" ;;
            xtrace) case "${val,,}" in true|1|yes) XTRACE=true ;; *) XTRACE=false ;; esac ;;
          esac
        fi
        ;;
      review)
        if [[ "$raw" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
          key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
          case "$key" in
            input) RV_INPUT="$val" ;;
            sort) RV_SORT="${val,,}" ;;
            skip_zero_size) case "${val,,}" in true|1|yes) RV_SKIP_ZERO=true ;; *) RV_SKIP_ZERO=false ;; esac ;;
            min_size_mb) RV_MIN_MB="$val" ;;
            include_regex) RV_INCLUDE_REGEX="$val" ;;
            exclude_regex) RV_EXCLUDE_REGEX="$val" ;;
            report_dir) RV_REPORT_DIR="$val" ;;
            report_prefix_date) case "${val,,}" in true|1|yes) RV_REPORT_PREFIX_DATE=true ;; *) RV_REPORT_PREFIX_DATE=false ;; esac ;;
            summary_limit_groups) RV_SUMMARY_LIMIT="${val:-0}"; [[ -z "$RV_SUMMARY_LIMIT" ]] && RV_SUMMARY_LIMIT=0 ;;
          esac
        fi
        ;;
    esac
  done <"$file"
}

# ───────────── CSV → TSV (robust to quotes/commas in path) ─────────────
# Emits: ts \t path \t algo \t hash \t size_mb
csv_to_tsv(){
  awk -v RS='' '
  function push_field() { f[++fc]=field }
  function flush_row() { if (fc){ for(i=1;i<=fc;i++){ printf "%s%s", f[i], (i<fc?"\t":"\n") } fc=0 } }
  {
    gsub(/\r/,"")
    n=split($0,lines,"\n")
    for (li=1; li<=n; li++){
      line=lines[li]; field=""; fc=0; inq=0
      for (i=1;i<=length(line);i++){
        c=substr(line,i,1); nc=(i<length(line)?substr(line,i+1,1):"")
        if (inq){
          if (c=="\"" && nc=="\""){ field=field "\""; i++ }
          else if (c=="\""){ inq=0 }
          else { field=field c }
        } else {
          if (c=="\""){ inq=1 }
          else if (c==","){ push_field(); field="" }
          else { field=field c }
        }
      }
      push_field()
      flush_row()
    }
  }'
}

# ───────────────────────── Arg parsing ─────────────────────────
while (($#)); do
  case "${1:-}" in
    --input)  INPUT_FILE="${2:-}"; shift 2;;
    --config) CONFIG_FILE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    --*) log WARN "Ignoring unknown flag: $1"; shift;;
    *)   log WARN "Ignoring unexpected argument: $1"; shift;;
  esac
done

# ───────────────────────── Setup ─────────────────────────
mkdir -p "$HASH_DIR" "$DUP_DIR" "$LOGS_DIR"
RUN_ID="$(gen_run_id)"
LOG_FILE="$LOGS_DIR/find-duplicates-$RUN_ID.log"
BACKGROUND_LOG="$LOGS_DIR/find-duplicates.log"
: >"$LOG_FILE"
ln -sfn "$(basename "$LOG_FILE")" "$BACKGROUND_LOG" || true

# config
if [[ -n "$CONFIG_FILE" ]]; then parse_ini "$CONFIG_FILE"; fi

# optional xtrace
if $XTRACE 2>/dev/null; then
  exec {__xtrace_fd}>>"$LOG_FILE" || true
  if [[ -n "${__xtrace_fd:-}" ]]; then export BASH_XTRACEFD="$__xtrace_fd"; set -x; fi
fi

log INFO "Run-ID: $RUN_ID"
log INFO "Config: ${CONFIG_FILE:-<none>} | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"
log INFO "Filters: skip_zero=$RV_SKIP_ZERO min_mb=$RV_MIN_MB | Sort: $RV_SORT | Limit: $RV_SUMMARY_LIMIT"

# ───────────────────────── Choose input CSV ─────────────────────────
if [[ -z "$INPUT_FILE" ]]; then
  case "$RV_INPUT" in
    latest)
      INPUT_FILE="$(ls -t "$HASH_DIR"/hasher-*.csv 2>/dev/null | head -n 1 || true)"
      [[ -n "$INPUT_FILE" ]] || die "No hasher-*.csv files found in '$HASH_DIR'"
      log INFO "Selected latest CSV: $(basename "$INPUT_FILE")"
      ;;
    prompt)
      mapfile -t FILES < <(ls -t "$HASH_DIR"/hasher-*.csv 2>/dev/null | head -n 10 || true)
      (( ${#FILES[@]} )) || die "No hasher-*.csv files found in '$HASH_DIR'"
      echo ""
      echo "Select a CSV hash file to summarise:"
      for i in "${!FILES[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "$(basename "${FILES[$i]}")"
      done
      echo ""
      read -r -p "Enter file number or filename: " selection
      if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection>=1 && selection<=${#FILES[@]} )); then
        INPUT_FILE="${FILES[$((selection-1))]}"
      elif [[ -f "$HASH_DIR/$selection" ]]; then
        INPUT_FILE="$HASH_DIR/$selection"
      else
        die "Invalid selection."
      fi
      log INFO "Selected CSV: $(basename "$INPUT_FILE")"
      ;;
    *)
      if [[ -f "$HASH_DIR/$RV_INPUT" ]]; then
        INPUT_FILE="$HASH_DIR/$RV_INPUT"
      elif [[ -f "$RV_INPUT" ]]; then
        INPUT_FILE="$RV_INPUT"
      else
        die "Configured input not found: $RV_INPUT"
      fi
      log INFO "Selected configured CSV: $(basename "$INPUT_FILE")"
      ;;
  esac
else
  [[ -f "$INPUT_FILE" ]] || die "Input CSV not found: $INPUT_FILE"
  log INFO "Selected CLI CSV: $(basename "$INPUT_FILE")"
fi

BASENAME="$(basename "$INPUT_FILE")"
DATE_TAG="$(echo "$BASENAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
[[ -n "$DATE_TAG" ]] || DATE_TAG="$(date +'%Y-%m-%d')"

mkdir -p "$RV_REPORT_DIR"
REPORT="$RV_REPORT_DIR/${RV_REPORT_PREFIX_DATE:+$DATE_TAG-}duplicate-summary.txt"
: >"$REPORT"

# ───────────────────────── CSV → TSV ─────────────────────────
TSV="$(mktemp)"; trap 'rm -f "$TSV"' EXIT
csv_to_tsv <"$INPUT_FILE" >"$TSV"

# Validate header (optional)
read -r HDR <"$TSV" || true
if ! echo "$HDR" | awk -F'\t' '{exit !($1=="timestamp" && $2=="path" && $3=="algo" && $4=="hash" && $5=="size_mb")}'; then
  log WARN "CSV header unexpected; proceeding anyway."
fi

# Build working rows: hash \t size_mb \t path
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
awk -F'\t' -v skip_zero="$RV_SKIP_ZERO" -v minmb="$RV_MIN_MB" '
NR>1 {
  size=$5+0
  if (skip_zero && size<=0) next
  if (size < minmb) next
  printf "%s\t%.6f\t%s\n", $4, size, $2
}' "$TSV" >"$TMP"

# Apply include/exclude regex filters on path
if [[ -n "$RV_INCLUDE_REGEX" ]]; then
  grep -E "$RV_INCLUDE_REGEX" "$TMP" >"${TMP}.inc" || true
  mv "${TMP}.inc" "$TMP"
fi
if [[ -n "$RV_EXCLUDE_REGEX" ]]; then
  grep -Ev "$RV_EXCLUDE_REGEX" "$TMP" >"${TMP}.exc" || true
  mv "${TMP}.exc" "$TMP"
fi

# Identify duplicate hash groups (2+ occurrences)
mapfile -t DUP_HASHES < <(cut -f1 "$TMP" | sort | uniq -d || true)
(( ${#DUP_HASHES[@]} > 0 )) || { log INFO "No duplicate hashes found after filters."; echo "No duplicates found." >>"$REPORT"; exit 0; }

# Compute per-group counts and total sizes for sorting + totals
META="$(mktemp)"; trap 'rm -f "$META"' EXIT
awk -F'\t' '
{ c[$1]++; s[$1]+=$2 }
END { for (h in c) printf "%s\t%d\t%.6f\n", h, c[h], s[h] }
' "$TMP" >"$META"

TOTAL_GROUPS=$(wc -l <"$META" | tr -d ' ')
TOTAL_FILES=$(awk -F'\t' '{t+=$2} END{print t+0}' "$META")
TOTAL_MB=$(awk -F'\t' '{t+=$3} END{printf "%.2f", t+0}' "$META")

# Sort groups
case "$RV_SORT" in
  count_desc) SORTED="$(sort -t$'\t' -k2,2nr -k3,3nr "$META")";;
  size_desc)  SORTED="$(sort -t$'\t' -k3,3nr -k2,2nr "$META")";;
  hash_asc)   SORTED="$(sort -t$'\t' -k1,1 "$META")";;
  *)          SORTED="$(cat "$META")";;
esac

# OPTIONAL LIMIT
if (( RV_SUMMARY_LIMIT > 0 )); then
  SORTED="$(echo "$SORTED" | head -n "$RV_SUMMARY_LIMIT")"
fi

# ───────────────────────── Write summary report ─────────────────────────
{
  echo "# Duplicate Summary"
  echo "# Source file           : $BASENAME"
  echo "# Date of run           : $(ts)"
  echo "# Filters               : skip_zero=$RV_SKIP_ZERO min_mb=$RV_MIN_MB"
  if [[ -n "$RV_INCLUDE_REGEX" ]]; then echo "# Include regex         : $RV_INCLUDE_REGEX"; fi
  if [[ -n "$RV_EXCLUDE_REGEX" ]]; then echo "# Exclude regex         : $RV_EXCLUDE_REGEX"; fi
  echo "# Groups (>=2)          : $TOTAL_GROUPS"
  echo "# Files in groups       : $TOTAL_FILES"
  echo "# Total duplicated size : ${TOTAL_MB} MB"
  echo "# Sort                  : $RV_SORT"
  if (( RV_SUMMARY_LIMIT > 0 )); then
    echo "# Showing top           : $RV_SUMMARY_LIMIT groups"
  fi
  echo
  printf "%-14s %-10s %-s\n" "COUNT" "SIZE(MB)" "HASH"
  printf "%-14s %-10s %-s\n" "-----" "--------" "----"
  echo "$SORTED" | awk -F'\t' '{printf "%-14d %-10.2f %s\n", $2, $3, $1}'
  echo
  echo "# Tip: For interactive review & safe delete plan, run:"
  echo "#   ./review-duplicates.sh --config hasher.conf"
} >>"$REPORT"

log INFO "Summary written to: $REPORT"
echo "Summary written to: $REPORT"
