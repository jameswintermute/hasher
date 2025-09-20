#!/usr/bin/env bash
# run-find-duplicates.sh — Menu Option 3 helper (progress-bar aware + next steps)
# Calls find-duplicates.sh in-foreground so its progress bar is visible,
# then prints a clear "what to do next" with the path to the canonical report.
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
HASHES_DIR="$APP_HOME/hashes"
LOGS_DIR="$APP_HOME/logs"

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_cyan='\033[0;36m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }
next() { printf "${c_cyan}[NEXT]${c_reset} %b\n" "$*"; }

latest_hasher_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
latest_duplicate_report() {
  if [[ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]]; then printf "%s" "$LOGS_DIR/duplicate-hashes-latest.txt"; return 0; fi
  local newest; newest="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$newest" && -s "$newest" ]]; then printf "%s" "$newest"; return 0; fi
  return 1
}

csv="$(latest_hasher_csv || true)"
if [[ -z "${csv:-}" || ! -f "$csv" ]]; then
  err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."
  exit 1
fi

info "Using hashes file: $csv"

# Run in-foreground so progress bar is visible
"$BIN_DIR/find-duplicates.sh" --input "$csv"
rc=$?

if (( rc != 0 )); then
  err "find-duplicates.sh exited with $rc"
  exit $rc
fi

report="$(latest_duplicate_report || true)"
if [[ -n "${report:-}" && -s "$report" ]]; then
  groups="$(grep -c '^HASH ' -- "$report" 2>/dev/null || echo 0)"
  if (( groups > 0 )); then
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

exit 0
