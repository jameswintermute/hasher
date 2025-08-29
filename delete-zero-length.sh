#!/bin/bash
# Delete (or move) zero-length files from a list
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage: $0 <paths_list.txt> [--force] [--trash-dir DIR]

  <paths_list.txt>   One file path per line (absolute or relative).
  --force            Execute changes (default is dry-run).
  --trash-dir DIR    Move files to DIR instead of deleting (safer).

Examples:
  $0 logs/zero-length-2025-08-29.txt                 # dry-run
  $0 logs/zero-length-2025-08-29.txt --force         # delete
  $0 logs/zero-length-2025-08-29.txt --force --trash-dir trash-2025-08-29  # move
EOF
}

[[ $# -lt 1 ]] && usage && exit 1

LIST="$1"; shift || true
FORCE=false
TRASH_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --trash-dir) TRASH_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift || true
done

if [[ ! -s "$LIST" ]]; then
  echo "[ERROR] List not found or empty: $LIST" >&2
  exit 1
fi

if [[ -n "$TRASH_DIR" ]]; then
  mkdir -p "$TRASH_DIR"
fi

COUNT=0
DEL=0
while IFS= read -r -d '' line || [[ -n "$line" ]]; do :; done < <(printf '%s\0' "$(cat "$LIST")") 2>/dev/null || true

# Read robustly (preserve spaces)
while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -z "$path" ]] && continue
  COUNT=$((COUNT+1))
  if [[ ! -e "$path" ]]; then
    echo "[WARN] Missing: $path"
    continue
  fi
  size=$(stat -c%s -- "$path" 2>/dev/null || echo -1)
  if [[ "$size" -ne 0 ]]; then
    echo "[SKIP] Not zero-length: $path (size=$size)"
    continue
  fi

  if [[ -n "$TRASH_DIR" ]]; then
    dest="$TRASH_DIR/$(basename "$path")"
    # avoid collisions
    idx=1
    base="$dest"
    while [[ -e "$dest" ]]; do
      dest="${base}.$idx"
      idx=$((idx+1))
    done
    if [[ "$FORCE" == true ]]; then
      mv -- "$path" "$dest"
      echo "[MOVE] $path -> $dest"
    else
      echo "[DRY]  mv -- '$path' '$dest'"
    fi
  else
    if [[ "$FORCE" == true ]]; then
      rm -f -- "$path"
      echo "[DEL]  $path"
    else
      echo "[DRY]  rm -f -- '$path'"
    fi
  fi
  DEL=$((DEL+1))
done < "$LIST"

echo
echo "[INFO] Examined: $COUNT | Zero-length processed: $DEL | Mode: $([[ "$FORCE" == true ]] && echo EXECUTE || echo DRY-RUN)"
