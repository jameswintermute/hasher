#!/usr/bin/env bash
# regen-zero-length.sh — rebuild zero-length file list without rerunning hasher
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

LOGS_DIR="logs"
ZERO_DIR="zero-length"
DATE_TAG="$(date +%F)"
OUT="$ZERO_DIR/zero-length-$DATE_TAG.txt"

mkdir -p "$ZERO_DIR"

pick_files_lst() { ls -1t "$LOGS_DIR"/files-*.lst 2>/dev/null | head -n1 || true; }

FILES_LST="${1:-$(pick_files_lst)}"

write_line() { printf '%s\n' "$1" >> "$OUT"; }

scan_from_files_lst() {
  local lst="$1"
  local count=0 zero=0 missing=0 notreg=0 nonzero=0
  : > "$OUT"

  if grep -q $'\0' "$lst"; then
    # NUL-delimited
    while IFS= read -r -d $'\0' f; do
      ((count++))
      if [[ ! -e "$f" ]]; then ((missing++))
      elif [[ ! -f "$f" ]]; then ((notreg++))
      elif [[ ! -s "$f" ]]; then ((zero++); write_line "$f")
      else ((nonzero++)); fi
    done < "$lst"
  else
    # Newline-delimited
    while IFS= read -r f || [[ -n "$f" ]]; do
      f="${f%$'\r'}"
      [[ -z "${f//[[:space:]]/}" ]] && continue
      ((count++))
      if [[ ! -e "$f" ]]; then ((missing++))
      elif [[ ! -f "$f" ]]; then ((notreg++))
      elif [[ ! -s "$f" ]]; then ((zero++); write_line "$f")
      else ((nonzero++)); fi
    done < "$lst"
  fi

  echo "Source: $lst"
  echo "Scanned entries: $count"
  echo " • Missing: $missing | Not regular: $notreg | Non-zero now: $nonzero"
  echo " • Zero-length (current): $zero"
  echo "Wrote: $OUT"
}

scan_from_paths_txt() {
  local pathfile="${1:-paths.txt}"
  : > "$OUT"
  local roots=0 found=0
  if [[ ! -r "$pathfile" ]]; then
    echo "No $pathfile and no files-*.lst; nothing to do." >&2
    exit 1
  fi
  while IFS= read -r root || [[ -n "$root" ]]; do
    root="${root%$'\r'}"
    [[ -z "${root//[[:space:]]/}" || "$root" =~ ^[[:space:]]*# ]] && continue
    ((roots++))
    # Respect common NAS junk/exclusions; adjust as you like
    find "$root" \
      -type d \( -name '#recycle' -o -name '@eaDir' -o -name '.snapshot' -o -name 'lost+found' -o -name '.Trash*' \) -prune -o \
      -type f -size 0 -print0 | xargs -0 -I{} printf '%s\n' "{}" >> "$OUT"
  done < "$pathfile"
  found="$(wc -l < "$OUT" | tr -d ' ')"
  echo "Scanned roots from $pathfile: $roots"
  echo "Zero-length files found: $found"
  echo "Wrote: $OUT"
}

if [[ -n "$FILES_LST" && -r "$FILES_LST" ]]; then
  scan_from_files_lst "$FILES_LST"
else
  scan_from_paths_txt "paths.txt"
fi
