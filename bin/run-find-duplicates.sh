#!/usr/bin/env bash
# run-find-duplicates.sh — Menu Option 3 helper (progress-bar aware)
# Calls find-duplicates.sh in-foreground so its progress bar is visible.
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
HASHES_DIR="$APP_HOME/hashes"

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

latest_hasher_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }

csv="$(latest_hasher_csv || true)"
if [[ -z "${csv:-}" || ! -f "$csv" ]]; then
  err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."
  exit 1
fi

info "Using hashes file: $csv"
exec "$BIN_DIR/find-duplicates.sh" --input "$csv"
