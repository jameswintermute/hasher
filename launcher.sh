#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# launcher.sh — friendly entrypoint from repo root
# Defaults: pathfile=local/paths.txt, algo=sha256, nohup mode

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# Resolve repo root (works regardless of CWD)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$SCRIPT_DIR"
BIN_DIR="$APP_HOME/bin"
LOG_DIR="$APP_HOME/logs"
DEFAULT_PATHFILE="$APP_HOME/local/paths.txt"
DEFAULT_ALGO="sha256"

# CLI (optional)
PATHFILE="$DEFAULT_PATHFILE"
ALGO="$DEFAULT_ALGO"
NOHUP=true
SHOW_ASCII=true

usage() {
  cat <<'EOF'
Usage: ./launcher.sh [--pathfile FILE] [--algo sha256] [--foreground] [--no-ascii]

Defaults:
  --pathfile local/paths.txt
  --algo     sha256
  --foreground (omit to run with --nohup)
EOF
}

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --pathfile) PATHFILE="${2:-}"; shift ;;
    --algo) ALGO="${2:-sha256}"; shift ;;
    --foreground) NOHUP=false ;;
    --no-ascii) SHOW_ASCII=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 2 ;;
  esac
  shift || true
done

# ASCII banner
if $SHOW_ASCII; then
  cat <<'BANNER'
 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe
BANNER
fi

# Pre-flight
mkdir -p "$LOG_DIR" "$APP_HOME/hashes" "$APP_HOME/var/zero-length" "$APP_HOME/var/low-value" "$APP_HOME/var/quarantine"

if [ ! -x "$BIN_DIR/hasher.sh" ]; then
  echo "[ERROR] $BIN_DIR/hasher.sh not found or not executable."
  exit 1
fi

if [ ! -f "$PATHFILE" ]; then
  echo "[ERROR] Path file not found: $PATHFILE"
  echo "Hints:"
  echo "  - Create it: $DEFAULT_PATHFILE (one directory per line)"
  echo "  - Or pass a custom file: --pathfile /path/to/paths.txt"
  exit 2
fi

# CRLF check
if grep -q $'\r' "$PATHFILE"; then
  echo "[WARN] Detected Windows (CRLF) line endings in: $PATHFILE"
  echo "       Auto-handled by scripts, but you can normalise with:"
  echo "         sed -i 's/\r$//' "$PATHFILE""
fi

echo "Starting Hasher now using defaults..."
echo "Command:"
if $NOHUP; then
  echo "  bin/hasher.sh --pathfile "$PATHFILE" --algo "$ALGO" --nohup"
  "$BIN_DIR/hasher.sh" --pathfile "$PATHFILE" --algo "$ALGO" --nohup
else
  echo "  bin/hasher.sh" --pathfile "$PATHFILE" --algo "$ALGO"
  "$BIN_DIR/hasher.sh" --pathfile "$PATHFILE" --algo "$ALGO"
fi

echo
echo "Tail logs with:"
echo "  tail -f "$LOG_DIR/background.log" "$LOG_DIR/hasher.log""
