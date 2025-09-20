#!/bin/sh
# launch-review.sh — Option 4 helper (POSIX/BusyBox-safe)
set -eu

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
mkdir -p "$LOGS_DIR"

COK="$(printf '\033[0;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[0;31m')"; CCYAN="$(printf '\033[0;36m')"; CRESET="$(printf '\033[0m')"
info(){ printf "%s[INFO]%s %s\n" "$COK" "$CRESET" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR" "$CRESET" "$*"; }
next(){ printf "%s[NEXT]%s %s\n" "$CCYAN" "$CRESET" "$*"; }

latest_duplicate_report() {
  if [ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]; then printf "%s" "$LOGS_DIR/duplicate-hashes-latest.txt"; return 0; fi
  newest="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [ -n "${newest:-}" ] && [ -s "$newest" ]; then printf "%s" "$newest"; return 0; fi
  return 1
}
latest_hasher_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
prompt_yn() { msg="$1"; def="${2:-Y}"; case "$def" in Y|y) p=" [Y/n] ";; *) p=" [y/N] ";; esac; printf "%s%s" "$msg" "$p"; read -r a || a=""; [ -z "$a" ] && a="$def"; case "$a" in Y|y|yes|YES) return 0;; *) return 1;; esac; }

info "Preparing interactive review…"

report="$(latest_duplicate_report || true)"
if [ -z "${report:-}" ] || [ ! -s "$report" ]; then
  warn "No usable duplicate-hashes report found."
  csv="$(latest_hasher_csv || true)"
  if [ -n "${csv:-}" ] && [ -f "$csv" ]; then
    info "Found latest hasher CSV: $csv"
    if prompt_yn "Run 'find-duplicates.sh' now to generate the report?" "Y"; then
      info "Generating duplicates report…"
      "$BIN_DIR/find-duplicates.sh" --input "$csv" || { err "find-duplicates.sh failed."; exit 1; }
      report="$(latest_duplicate_report || true)"
    else
      next "Run menu option 3 first, then re-run option 4."
      exit 0
    fi
  else
    err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."
    exit 1
  fi
fi

if [ -z "${report:-}" ] || [ ! -s "$report" ]; then
  err "Failed to locate a duplicates report after generation."
  exit 1
fi

info "Using report: $report"
exec "$BIN_DIR/review-duplicates.sh" --from-report "$report"
