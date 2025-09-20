#!/bin/sh
# run-find-duplicates.sh — Menu Option 3 helper (POSIX/BusyBox-safe)
# Runs find-duplicates.sh in-foreground so its progress is visible,
# then prints a clear next step and groups count.
set -eu
IFS=$(printf '\n\t')

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
HASHES_DIR="$APP_HOME/hashes"
LOGS_DIR="$APP_HOME/logs"

CINFO="$(printf '\033[0;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[0;31m')"; CNEXT="$(printf '\033[0;36m')"; CRESET="$(printf '\033[0m')"
info(){ printf "%s[INFO]%s %s\n" "$CINFO" "$CRESET" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR" "$CRESET" "$*"; }
next(){ printf "%s[NEXT]%s %s\n" "$CNEXT" "$CRESET" "$*"; }

latest_hasher_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
latest_duplicate_report() {
  if [ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]; then printf "%s" "$LOGS_DIR/duplicate-hashes-latest.txt"; return 0; fi
  # shellcheck disable=SC2012
  newest="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [ -n "${newest:-}" ] && [ -s "$newest" ]; then printf "%s" "$newest"; return 0; fi
  return 1
}

csv="$(latest_hasher_csv || true)"
if [ -z "${csv:-}" ] || [ ! -f "$csv" ]; then
  err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."
  exit 1
fi

info "Using hashes file: $csv"
"$BIN_DIR/find-duplicates.sh" --input "$csv" || rc=$?

# shellcheck disable=SC2181
if [ "${rc:-0}" -ne 0 ]; then
  err "find-duplicates.sh exited with ${rc:-$?}"
  exit "${rc:-1}"
fi

report="$(latest_duplicate_report || true)"
if [ -n "${report:-}" ] && [ -s "$report" ]; then
  groups="$(grep -c '^HASH ' -- "$report" 2>/dev/null || echo 0)"
  if [ "$groups" -gt 0 ]; then
    info "Canonical report ready: $report  (groups: $groups)"
    next "Choose '4) Review duplicates (interactive)' to select keepers and build a delete plan."
  else
    warn "Report generated but contains 0 duplicate groups."
    next "You can still open '4) Review duplicates' — it will exit quickly with no actions."
  fi
else
  warn "Did not locate a canonical report after processing."
  next "Run option 3 again or check logs; then use option 4 to review if a report exists."
fi
