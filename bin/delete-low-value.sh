\
#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ───── Layout ─────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOG_DIR="$APP_HOME/logs"
VAR_DIR="$APP_HOME/var"
LOW_DIR="$VAR_DIR/low-value"
mkdir -p "$LOG_DIR" "$LOW_DIR"

# ───── Defaults & args ─────
LIST_FILE=""
MODE="verify"           # verify|dry|force|quarantine
QUAR_DIR=""

usage(){
  cat <<EOF
Usage: $0 --from-list FILE [--verify-only | --force | --quarantine DIR]
  --from-list FILE   Path list of low-value candidates (one per line)
  --verify-only      Recheck current file size and write verified list (default)
  --force            Delete files (DANGEROUS) after verification
  --quarantine DIR   Move files to DIR after verification (implies --force)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-list) LIST_FILE="${2:-}"; shift ;;
    --verify-only) MODE="verify" ;;
    --force) MODE="force" ;;
    --quarantine) MODE="quarantine"; QUAR_DIR="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

[ -n "$LIST_FILE" ] || { echo "[ERROR] Missing --from-list"; usage; exit 2; }
[ -r "$LIST_FILE" ] || { echo "[ERROR] Cannot read list: $LIST_FILE"; exit 2; }

DATE_TAG="$(date +%F)"
RUN_ID="$(date +%s)-$$"
VERIFIED="$LOW_DIR/verified-low-value-$DATE_TAG-$RUN_ID.txt"
: > "$VERIFIED"

# ───── Verify current state ─────
count_in=0; count_ok=0; count_missing=0; count_nonreg=0; count_excluded=0
while IFS= read -r p || [ -n "$p" ]; do
  p="${p%"${p##*[![:space:]]}"}"; p="${p#"${p%%[![:space:]]}"}"
  [ -z "$p" ] && continue
  count_in=$((count_in+1))
  if [ ! -e "$p" ]; then
    count_missing=$((count_missing+1)); continue
  fi
  if [ ! -f "$p" ]; then
    count_nonreg=$((count_nonreg+1)); continue
  fi
  # builtin excludes (case-insensitive)
  base="$(basename -- "$p")"
  case "${base,,}" in
    thumbs.db|.ds_store|desktop.ini) count_excluded=$((count_excluded+1)); continue ;;
  esac
  # verify zero / tiny (<= 0 bytes defaults since low-value threshold handled upstream)
  sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0)
  if [ "$sz" -le 0 ]; then
    printf '%s\n' "$p" >> "$VERIFIED"; count_ok=$((count_ok+1))
  fi
done < "$LIST_FILE"

echo "[VERIFY] Input entries: $count_in"
echo "[VERIFY]   • Verified low-value now: $count_ok"
echo "[VERIFY]   • Missing paths: $count_missing"
echo "[VERIFY]   • Not regular files: $count_nonreg"
echo "[VERIFY]   • Builtin-excluded basenames: $count_excluded"
echo "[VERIFY] Verified plan: $VERIFIED"

if [ "$MODE" = "verify" ]; then
  echo "[NEXT] Dry-run: $0 --from-list \"$VERIFIED\""
  echo "[NEXT] Delete:  $0 --from-list \"$VERIFIED\" --force"
  echo "[NEXT] Quar:    $0 --from-list \"$VERIFIED\" --quarantine \"$LOW_DIR/quarantine-$DATE_TAG\""
  exit 0
fi

# ───── Action (delete/quarantine) ─────
if [ "$MODE" = "quarantine" ]; then
  [ -n "$QUAR_DIR" ] || QUAR_DIR="$LOW_DIR/quarantine-$DATE_TAG"
  mkdir -p "$QUAR_DIR"
fi

acted=0; failed=0
while IFS= read -r p || [ -n "$p" ]; do
  [ -z "$p" ] && continue
  if [ "$MODE" = "quarantine" ]; then
    rel="$(echo "$p" | sed 's#^/##')"
    dst="$QUAR_DIR/$rel"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true
    if mv -n -- "$p" "$dst" 2>/dev/null; then acted=$((acted+1)); else failed=$((failed+1)); fi
  else # force delete
    if rm -f -- "$p" 2>/dev/null; then acted=$((acted+1)); else failed=$((failed+1)); fi
  fi
done < "$VERIFIED"

[ "$MODE" = "quarantine" ] && echo "[DONE] Moved $acted file(s) to: $QUAR_DIR (failures=$failed)"
[ "$MODE" = "force" ] && echo "[DONE] Deleted $acted file(s) (failures=$failed)"
