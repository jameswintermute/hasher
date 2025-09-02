#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# review-latest.sh — convenience wrapper to auto-pick the most recent duplicate report
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCRIPT_DIR/lib_paths.sh" 2>/dev/null || true
APP_HOME="${APP_HOME:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
LOG_DIR="${LOG_DIR:-$APP_HOME/logs}"

LATEST="$(ls -1t "$LOG_DIR"/*duplicate-hashes*.txt 2>/dev/null | head -n1 || true)"
if [ -z "$LATEST" ]; then
  echo "[ERROR] No duplicate-hashes report found in $LOG_DIR"
  echo "Run: bin/find-duplicates.sh"
  exit 2
fi

echo "[INFO] Using latest report: $LATEST"
exec "$SCRIPT_DIR/review-duplicates.sh" --from-report "$LATEST" "$@"
