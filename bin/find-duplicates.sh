#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ── Layout discovery ───────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCRIPT_DIR/lib_paths.sh" 2>/dev/null || true
APP_HOME="${APP_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
LOG_DIR="${LOG_DIR:-$APP_HOME/logs}"
HASHES_DIR="${HASHES_DIR:-$APP_HOME/hashes}"

# ── Run context ────────────────────────────────────────────
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
if [ -r /proc/sys/kernel/random/uuid ]; then RUN_ID="$(cat /proc/sys/kernel/random/uuid)"; else RUN_ID="$(date +%s)-$$-$RANDOM"; fi
log(){ printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log INFO "$*"; }; log_error(){ log ERROR "$*"; }

CSV_FILE=""; REPORT_FILE=""; SUMMARY_TSV=""
MIN_SIZE_BYTES=0      # Only include files >= this size in duplicate analysis
GROUP_DEPTH=2         # How many path components to show in "Top folders" (stdout summary)

usage(){ cat <<'EOF'
Usage: find-duplicates.sh [--csv FILE] [--min-size-bytes N] [--min-size-mb N] [--report FILE] [--group-depth N]

If --csv is omitted, the most recent hashes/hasher-*.csv is used.
Writes:
  - report: logs/YYYY-MM-DD-duplicate-hashes.txt
  - summary: logs/duplicate-summary-<DATE>-<RUN_ID>.tsv
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV_FILE="${2:-}"; shift ;;
    --report) REPORT_FILE="${2:-}"; shift ;;
    --min-size-bytes) MIN_SIZE_BYTES="${2:-0}"; shift ;;
    --min-size-mb) MIN_SIZE_BYTES=$(( ${2:-0} * 1024 * 1024 )); shift ;;
    --group-depth) GROUP_DEPTH="${2:-2}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown arg: $1"; usage; exit 2 ;;
  esac; shift || true
done

mkdir -p "$LOG_DIR"

# Auto-pick latest CSV
if [ -z "$CSV_FILE" ]; then
  CSV_FILE="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
fi
[ -n "$CSV_FILE" ] && [ -r "$CSV_FILE" ] || { log_error "No readable CSV found (looked in $HASHES_DIR)."; exit 2; }

# Defaults for outputs
DATE_TAG="$(date +%F)"
[ -n "$REPORT_FILE" ] || REPORT_FILE="$LOG_DIR/$DATE_TAG-duplicate-hashes.txt"
SUMMARY_TSV="$LOG_DIR/duplicate-summary-$DATE_TAG-$RUN_ID.tsv"

log_info "Using CSV: $CSV_FILE"
log_info "Report will be written to: $REPORT_FILE"
log_info "Summary TSV will be written to: $SUMMARY_TSV"
log_info "Filters: min_size=${MIN_SIZE_BYTES}B, group_depth=${GROUP_DEPTH}"

# Build report + summary via awk (CSV with header; basic CSV handling)
awk -v minsz="$MIN_SIZE_BYTES" -v OFS="," -F',' '
  function trim(s){ sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s); return s }
  NR==1 {
    for (i=1;i<=NF;i++){ low=tolower($i); h[low]=i }
    sizecol = (h["size_bytes"] ? h["size_bytes"] : (h["size"] ? h["size"] : 0))
    pathcol = (h["path"] ? h["path"] : (h["filepath"] ? h["filepath"] : 1))
    hashcol = (h["hash"] ? h["hash"] :
              (h["sha256"] ? h["sha256"] :
              (h["sha1"] ? h["sha1"] :
              (h["sha512"] ? h["sha512"] :
              (h["md5"] ? h["md5"] : 0)))))
    next
  }
  {
    # naive CSV split; okay for most NAS paths; adjust if paths contain commas extensively
    sz = (sizecol ? $sizecol+0 : $(NF-2)+0)
    if (sz < minsz) next
    p  = trim(pathcol ? $pathcol : $1)
    hval = trim(hashcol ? $hashcol : $(NF))
    if (hval == "" || p == "") next
    cnt[hval]++; if (!(hval in f1sz)) f1sz[hval]=sz; files[hval]=(hval in files? files[hval] "\n" p : p)
  }
  END{
    for (k in cnt) if (cnt[k]>1) {
      print "HASH " k " (" cnt[k] " files):"
      n=split(files[k], arr, "\n")
      for (i=1;i<=n;i++) print "  " arr[i]
      print ""
      printf "%s\t%d\t%d\n", k, cnt[k], (cnt[k]-1)*f1sz[k] >> "'"$SUMMARY_TSV"'"
    }
  }
' "$CSV_FILE" > "$REPORT_FILE"

log_info "Duplicate analysis complete."
log_info "  • Report:           $REPORT_FILE"
log_info "  • Summary TSV:      $SUMMARY_TSV"

# Print quick top 10 groups by potential reclaim (tsv: hash, count, reclaim_bytes)
if [ -s "$SUMMARY_TSV" ]; then
  echo
  echo "Top 10 groups (by potential reclaim):"
  sort -k3,3nr "$SUMMARY_TSV" | head -n 10 | awk -F'\t' '{printf "  %2d files  ~%s bytes reclaim  hash=%s\n", $2, $3, $1}'
fi
