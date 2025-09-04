#!/bin/sh
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# delete-junk.sh — BusyBox/POSIX; robust --paths-file handling without sed/awk in the read path
set -eu

ROOT="$(cd -- "$(dirname "$0")/.." && pwd -P)"
LOGS="$ROOT/logs"; mkdir -p "$LOGS"

PATHS_FILE=""
INCLUDE_RECYCLE=0
ACTION="verify"
QUAR=""
DATE_TAG="$(date +%F)"
OUTDIR="$ROOT/var/junk/quarantine-$DATE_TAG"

# parse args
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paths-file) PATHS_FILE="${2:-}"; shift ;;
    --include-recycle) INCLUDE_RECYCLE=1 ;;
    --verify-only) ACTION="verify" ;;
    --dry-run)     ACTION="dry" ;;
    --force)       ACTION="force" ;;
    --quarantine)  ACTION="quarantine"; QUAR="${2:-}"; shift ;;
    -h|--help)
      echo "Usage: $0 [--paths-file FILE] [--include-recycle] [--verify-only|--dry-run|--force|--quarantine DIR]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift || true
done

# resolve paths file
if [ -z "$PATHS_FILE" ]; then
  if [ -f "$ROOT/local/paths.txt" ]; then PATHS_FILE="$ROOT/local/paths.txt"
  elif [ -f "$ROOT/paths.txt" ]; then PATHS_FILE="$ROOT/paths.txt"
  else
    echo "[ERROR] No paths file found (local/paths.txt or ./paths.txt). Create one." >&2
    exit 1
  fi
fi
[ -r "$PATHS_FILE" ] || { echo "[ERROR] Cannot read paths file: $PATHS_FILE" >&2; exit 1; }

# read roots (pure sh): strip CR, trim spaces, drop comments/blanks
ROOTS_TMP="$(mktemp)"
# shellcheck disable=SC2162
while IFS= read -r line || [ -n "$line" ]; do
  # strip trailing CR
  case "$line" in *$'\r') line="${line%$'\r'}";; esac
  # trim leading spaces
  while [ "${line# }" != "$line" ]; do line="${line# }"; done
  # trim trailing spaces
  while [ "${line% }" != "$line" ]; do line="${line% }"; done
  # skip blanks/comments
  case "$line" in ""|'#'*) continue;; esac
  printf '%s\n' "$line" >> "$ROOTS_TMP"
done < "$PATHS_FILE"

FILES_NUL="$(mktemp)"
DIRS_NUL="$(mktemp)"
count_roots=0
warned=0

# read each root
# shellcheck disable=SC2162
while IFS= read -r root || [ -n "$root" ]; do
  [ -z "$root" ] && continue
  if [ -d "$root" ] || [ -f "$root" ]; then
    count_roots=$((count_roots+1))
    # files
    find "$root" -type f \( -name 'Thumbs.db' -o -name '.DS_Store' -o -name 'Desktop.ini' -o -name '._*' \) -print0 >> "$FILES_NUL" 2>/dev/null || true
    # dirs
    if [ "$INCLUDE_RECYCLE" -eq 1 ]; then
      find "$root" -type d \( -name '@eaDir' -o -name '.AppleDouble' -o -name '.Spotlight-V100' -o -name '.Trashes' -o -name '#recycle' \) -print0 >> "$DIRS_NUL" 2>/dev/null || true
    else
      find "$root" -type d \( -name '@eaDir' -o -name '.AppleDouble' -o -name '.Spotlight-V100' -o -name '.Trashes' \) -print0 >> "$DIRS_NUL" 2>/dev/null || true
    fi
  else
    echo "[WARN] Path not found (skipped): $root" >&2
    warned=1
  fi
done < "$ROOTS_TMP"

if [ "$count_roots" -eq 0 ]; then
  echo "[ERROR] No valid roots to scan." >&2
  rm -f "$ROOTS_TMP" "$FILES_NUL" "$DIRS_NUL"
  exit 1
fi

files_count="$(tr -cd '\0' < "$FILES_NUL" | wc -c | tr -d ' ' || echo 0)"
dirs_count="$(tr -cd '\0' < "$DIRS_NUL" | wc -c | tr -d ' ' || echo 0)"

echo "[INFO] Roots: $count_roots  | Junk files: $files_count  | Junk dirs: $dirs_count"
[ "$warned" -eq 1 ] && echo "[INFO] Some listed roots were missing (see warnings above)."

if [ "$ACTION" = "verify" ] || [ "$ACTION" = "dry" ]; then
  echo "[INFO] Dry-run / verify mode — no changes will be made."
  echo "Sample files:"
  tr '\0' '\n' < "$FILES_NUL" | head -n 20 || true
  echo "Sample dirs:"
  tr '\0' '\n' < "$DIRS_NUL" | head -n 20 || true
  rm -f "$ROOTS_TMP" "$FILES_NUL" "$DIRS_NUL"
  exit 0
fi

LOG_DEL="$LOGS/junk-deletions-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_DEL"

if [ "$ACTION" = "quarantine" ]; then
  [ -n "$QUAR" ] || QUAR="$OUTDIR"
  mkdir -p "$QUAR"
  echo "[INFO] Quarantine: $QUAR"
fi

deleted=0
moved=0

move_preserve() {
  src="$1"; base="$2"; dest="$3"
  case "$src" in "$base"/*) rel="${src#$base/}" ;; *) rel="$(basename "$src")" ;; esac
  dest_path="$dest/$rel"
  mkdir -p "$(dirname "$dest_path")" 2>/dev/null || true
  mv -f -- "$src" "$dest_path" && moved=$((moved+1)) && echo "$src -> $dest_path" >> "$LOG_DEL"
}

# files
while IFS= read -r -d '' f; do
  if [ "$ACTION" = "force" ]; then
    rm -f -- "$f" && deleted=$((deleted+1)) && echo "DEL $f" >> "$LOG_DEL"
  else
    base=""
    # find best base for relative path
    while IFS= read -r r || [ -n "$r" ]; do
      case "$f" in "$r"/*) base="$r"; break;; esac
    done < "$ROOTS_TMP"
    move_preserve "$f" "${base:-$ROOT}" "$QUAR"
  fi
done < "$FILES_NUL"

# dirs (after files)
while IFS= read -r -d '' d; do
  if [ "$ACTION" = "force" ]; then
    rm -rf -- "$d" && deleted=$((deleted+1)) && echo "RMDIR $d" >> "$LOG_DEL"
  else
    base=""
    while IFS= read -r r || [ -n "$r" ]; do
      case "$d" in "$r"/*) base="$r"; break;; esac
    done < "$ROOTS_TMP"
    move_preserve "$d" "${base:-$ROOT}" "$QUAR"
  fi
done < "$DIRS_NUL"

echo "[INFO] Completed. Deleted: $deleted  Moved: $moved"
echo "[INFO] Log: $LOG_DEL"

rm -f "$ROOTS_TMP" "$FILES_NUL" "$DIRS_NUL"
