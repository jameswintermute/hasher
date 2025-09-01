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
JUNK_DIR="$VAR_DIR/junk"
LOCAL_DIR="$APP_HOME/local"
PATHS_FILE_DEFAULT="$LOCAL_DIR/paths.txt"

mkdir -p "$LOG_DIR" "$VAR_DIR" "$JUNK_DIR"

# ───── Args ─────
PATHS_FILE="$PATHS_FILE_DEFAULT"
INCLUDE_RECYCLE=false
MODE="verify"           # verify|dry|force|quarantine
QUAR_DIR=""

usage(){
  cat <<EOF
Usage: $0 [--paths-file FILE] [--include-recycle] [--verify-only|--dry-run|--force|--quarantine DIR]

Purpose: Remove OS/NAS junk like Thumbs.db, .DS_Store, Desktop.ini, AppleDouble, Synology @eaDir, etc.

Options:
  --paths-file FILE    Roots to scan (one path per line). Default: local/paths.txt
  --include-recycle    Also remove '#recycle' directories (OFF by default)
  --verify-only        Scan & write candidate lists (default)
  --dry-run            Show planned actions, do not modify anything
  --force              Delete matched junk files/dirs
  --quarantine DIR     Move matched items under DIR (implies action). Default: var/junk/quarantine-YYYY-MM-DD

Built-in file patterns:
  Files: Thumbs.db, .DS_Store, Desktop.ini, ._* (AppleDouble)
  Dirs : @eaDir, .AppleDouble, .Spotlight-V100, .Trashes [, #recycle if --include-recycle]

Examples:
  $0 --verify-only
  $0 --dry-run
  $0 --force
  $0 --quarantine var/junk/quarantine-\$(date +%F)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --paths-file) PATHS_FILE="${2:-}"; shift ;;
    --include-recycle) INCLUDE_RECYCLE=true ;;
    --verify-only) MODE="verify" ;;
    --dry-run) MODE="dry" ;;
    --force) MODE="force" ;;
    --quarantine) MODE="quarantine"; QUAR_DIR="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

[ -r "$PATHS_FILE" ] || { echo "[ERROR] Cannot read paths file: $PATHS_FILE"; exit 2; }

DATE_TAG="$(date +%F)"
RUN_ID="$(date +%s)-$$"

FILES_LIST="$JUNK_DIR/junk-files-$DATE_TAG-$RUN_ID.lst"
DIRS_LIST="$JUNK_DIR/junk-dirs-$DATE_TAG-$RUN_ID.lst"
: > "$FILES_LIST"
: > "$DIRS_LIST"

# ───── Normalize paths file (handles CRLF/UTF-16) ─────
norm="$JUNK_DIR/paths-normalized-$DATE_TAG-$RUN_ID.txt"
cp -f -- "$PATHS_FILE" "$norm" 2>/dev/null || { echo "[ERROR] Failed to read $PATHS_FILE"; exit 2; }

# If file contains NULs, try to iconv from UTF-16 (LE/BE) to UTF-8
if grep -qP '\x00' "$norm" 2>/dev/null; then
  if command -v iconv >/dev/null 2>&1; then
    # Try BOM autodetect first
    if iconv -f UTF-16 -t UTF-8 "$norm" -o "$norm.utf8" 2>/dev/null; then
      mv -f "$norm.utf8" "$norm"
      echo "[INFO] Converted paths file from UTF‑16 to UTF‑8."
    else
      # Fallback: try LE then BE
      if iconv -f UTF-16LE -t UTF-8 "$norm" -o "$norm.utf8" 2>/dev/null || iconv -f UTF-16BE -t UTF-8 "$norm" -o "$norm.utf8" 2>/dev/null; then
        mv -f "$norm.utf8" "$norm"
        echo "[INFO] Converted paths file (LE/BE) to UTF‑8."
      else
        echo "[WARN] Detected NULs in $PATHS_FILE but iconv conversion failed; results may be unreliable."
      fi
    end
  else
    echo "[WARN] Detected NULs in $PATHS_FILE (likely UTF‑16), but 'iconv' not available. Consider re-saving as UTF‑8."
  fi
fi

# Strip CRs and empty lines
sed -i 's/\r$//;/^[[:space:]]*$/d' "$norm" 2>/dev/null || true

# ───── Collect roots ─────
roots=()
while IFS= read -r p || [ -n "$p" ]; do
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  [ -z "$p" ] && continue
  if [ -e "$p" ]; then
    roots+=("$p")
  else
    echo "[WARN] Path not found (skipped): $p"
  fi
done < "$norm"

if [ "${#roots[@]}" -eq 0 ]; then
  echo "[ERROR] No valid roots to scan."
  exit 2
fi

# ───── Build find expressions ─────
file_name_args=( -iname 'Thumbs.db' -o -name '.DS_Store' -o -iname 'Desktop.ini' -o -name '._*' )
dir_name_args=( -name '@eaDir' -o -name '.AppleDouble' -o -name '.Spotlight-V100' -o -name '.Trashes' )
if $INCLUDE_RECYCLE; then
  dir_name_args+=( -o -name '#recycle' )
fi

# ───── Scan each root ─────
for root in "${roots[@]}"; do
  # Files
  find "$root" -type f \( "${file_name_args[@]}" \) -print0 2>/dev/null >> "$FILES_LIST".nul || true
  # Dirs
  find "$root" -type d \( "${dir_name_args[@]}" \) -print0 2>/dev/null >> "$DIRS_LIST".nul || true
done

# Convert NUL lists to newline lists for easier display/action loops
tr '\0' '\n' < "$FILES_LIST".nul 2>/dev/null | sed '/^[[:space:]]*$/d' >> "$FILES_LIST" || true
tr '\0' '\n' < "$DIRS_LIST".nul 2>/dev/null | sed '/^[[:space:]]*$/d' >> "$DIRS_LIST" || true
rm -f -- "$FILES_LIST".nul "$DIRS_LIST".nul 2>/dev/null || true

count_files=$( [ -s "$FILES_LIST" ] && wc -l < "$FILES_LIST" | tr -d ' ' || echo 0 )
count_dirs=$(  [ -s "$DIRS_LIST" ]  && wc -l < "$DIRS_LIST"  | tr -d ' ' || echo 0 )
echo "[SCAN] Candidates — files: $count_files, dirs: $count_dirs"
echo "[PLAN] Files list: $FILES_LIST"
echo "[PLAN] Dirs  list: $DIRS_LIST"

# ───── Actions ─────
if [ "$MODE" = "verify" ]; then
  echo "[NEXT] Dry-run: $0 --paths-file \"$PATHS_FILE\" --dry-run"
  echo "[NEXT] Delete:  $0 --paths-file \"$PATHS_FILE\" --force"
  echo "[NEXT] Quar:    $0 --paths-file \"$PATHS_FILE\" --quarantine \"$JUNK_DIR/quarantine-$DATE_TAG\""
  exit 0
fi

if [ "$MODE" = "dry" ]; then
  echo "[DRY-RUN] Would delete these files (first 20 shown):"
  head -n 20 "$FILES_LIST" 2>/dev/null || true
  echo "[DRY-RUN] Would delete these directories (first 10 shown):"
  head -n 10 "$DIRS_LIST" 2>/dev/null || true
  echo "[INFO] Totals — files: $count_files, dirs: $count_dirs"
  exit 0
fi

# force/quarantine
if [ "$MODE" = "quarantine" ]; then
  [ -n "$QUAR_DIR" ] || QUAR_DIR="$JUNK_DIR/quarantine-$DATE_TAG"
  mkdir -p "$QUAR_DIR"
fi

acted=0; failed=0

# Files
if [ -s "$FILES_LIST" ]; then
  while IFS= read -r f || [ -n "$f" ]; do
    [ -z "$f" ] && continue
    if [ "$MODE" = "quarantine" ]; then
      rel="${f#/}" ; dst="$QUAR_DIR/$rel"
      mkdir -p "$(dirname "$dst")" 2>/dev/null || true
      mv -n -- "$f" "$dst" 2>/dev/null && acted=$((acted+1)) || failed=$((failed+1))
    else
      rm -f -- "$f" 2>/dev/null && acted=$((acted+1)) || failed=$((failed+1))
    fi
  done < "$FILES_LIST"
fi

# Directories
if [ -s "$DIRS_LIST" ]; then
  while IFS= read -r d || [ -n "$d" ]; do
    [ -z "$d" ] && continue
    if [ "$MODE" = "quarantine" ]; then
      rel="${d#/}" ; dst="$QUAR_DIR/$rel"
      mkdir -p "$(dirname "$dst")" 2>/dev/null || true
      mv -n -- "$d" "$dst" 2>/dev/null && acted=$((acted+1)) || failed=$((failed+1))
    else
      rm -rf -- "$d" 2>/dev/null && acted=$((acted+1)) || failed=$((failed+1))
    fi
  done < "$DIRS_LIST"
fi

if [ "$MODE" = "quarantine" ]; then
  echo "[DONE] Moved $acted items to quarantine (failures=$failed)"
else
  echo "[DONE] Deleted $acted items (failures=$failed)"
fi
