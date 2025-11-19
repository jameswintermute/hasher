#!/bin/sh
# delete-junk.sh — find and delete junk files based on local/junk-extensions.txt
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs";   mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";     mkdir -p "$VAR_DIR"
LOCAL_DIR="$ROOT_DIR/local"; mkdir -p "$LOCAL_DIR"

JUNK_FILE="$LOCAL_DIR/junk-extensions.txt"
PATHS_FILE="$LOCAL_DIR/paths.txt"

is_tty() { [ -t 2 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; }

if is_tty; then
  C1="$(printf '\033[1;36m')"; C2="$(printf '\033[1;33m')"
  COK="$(printf '\033[1;32m')" ; CERR="$(printf '\033[1;31m')"
  CDIM="$(printf '\033[2m')"  ; C0="$(printf '\033[0m')"
else
  C1=""; C2=""; COK=""; CERR=""; CDIM=""; C0=""
fi

info()  { printf "%s[INFO]%s %s\n"  "$COK" "$C0" "$1" >&2; }
warn()  { printf "%s[WARN]%s %s\n"  "$C2" "$C0" "$1" >&2; }
error() { printf "%s[ERROR]%s %s\n" "$CERR" "$C0" "$1" >&2; }

human_size(){
  b="${1:-0}"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    printf "%.1fG" "$(awk "BEGIN{print $b/1073741824}")"
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    printf "%.1fM" "$(awk "BEGIN{print $b/1048576}")"
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    printf "%.1fK" "$(awk "BEGIN{print $b/1024}")"
  else
    printf "%dB" "$b"
  fi
}

file_size(){
  f="$1"
  stat -c %s "$f" 2>/dev/null && return 0 || true
  busybox stat -c %s "$f" 2>/dev/null && return 0 || true
  stat -f %z "$f" 2>/dev/null && return 0 || true
  wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0
}

[ -r "$JUNK_FILE" ]  || { error "Junk list not found or not readable: $JUNK_FILE"; exit 1; }
[ -r "$PATHS_FILE" ] || { error "Paths file not found or not readable: $PATHS_FILE"; exit 1; }

info "Using junk list: $JUNK_FILE"
info "Scanning paths from: $PATHS_FILE"

CANDIDATES="$(mktemp "$VAR_DIR/junk-candidates.XXXXXX")"
trap 'rm -f "$CANDIDATES" 2>/dev/null || true' EXIT INT TERM

# Build candidate list
while IFS= read -r root || [ -n "$root" ]; do
  case "$root" in
    ''|\#*) continue ;;
  esac
  if [ ! -d "$root" ]; then
    warn "Path does not exist or is not a directory: $root"
    continue
  fi

  # For each rule in junk-extensions.txt
  while IFS= read -r rule || [ -n "$rule" ]; do
    # Strip comments and whitespace
    cleaned="$(printf '%s\n' "$rule" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$cleaned" ] && continue

    case "$cleaned" in
      *.*)
        # Treat as BASENAME (e.g., Thumbs.db, .DS_Store, Desktop.ini)
        find "$root" -type f -iname "$cleaned" -print 2>/dev/null >>"$CANDIDATES" || true
        ;;
      *)
        # Treat as EXTENSION (no dot) → *.EXT
        find "$root" -type f -iname "*.$cleaned" -print 2>/dev/null >>"$CANDIDATES" || true
        ;;
    esac
  done <"$JUNK_FILE"

done <"$PATHS_FILE"

# Deduplicate
if [ -s "$CANDIDATES" ]; then
  SORTED="$(mktemp "$VAR_DIR/junk-candidates-sorted.XXXXXX")"
  sort -u "$CANDIDATES" >"$SORTED" 2>/dev/null || cp "$CANDIDATES" "$SORTED"
  mv "$SORTED" "$CANDIDATES"
fi

TOTAL_FILES=0
[ -s "$CANDIDATES" ] && TOTAL_FILES="$(wc -l <"$CANDIDATES" | tr -d ' ' || echo 0)"

if [ "$TOTAL_FILES" -eq 0 ]; then
  info "No junk files found based on $JUNK_FILE."
  exit 0
fi

# Compute total size
TOTAL_BYTES=0
while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  sz="$(file_size "$f" 2>/dev/null || echo 0)"
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  TOTAL_BYTES=$((TOTAL_BYTES + sz))
done <"$CANDIDATES"

TOTAL_HR="$(human_size "$TOTAL_BYTES")"

echo
info "Junk candidates found: $TOTAL_FILES files, total size ~ $TOTAL_HR."

# Preview output
if [ "$TOTAL_FILES" -le 25 ]; then
  echo
  echo "The following files are marked as junk and can be deleted:"
  echo "---------------------------------------------------------"
  cat "$CANDIDATES"
  echo "---------------------------------------------------------"
else
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
  LIST_FILE="$LOGS_DIR/junk-candidates-$RUN_ID.txt"
  cp "$CANDIDATES" "$LIST_FILE"
  echo
  info "The list is long ($TOTAL_FILES files)."
  info "Full candidate list saved to: $LIST_FILE"
  echo "For a quick preview, you can run:"
  echo "  head -n 50 \"$LIST_FILE\""
fi

echo
printf "Proceed to DELETE these %d junk files (~%s)? [y/N] " "$TOTAL_FILES" "$TOTAL_HR"
if [ -t 0 ]; then
  if ! IFS= read -r ans; then ans="n"; fi
else
  if ! IFS= read -r ans </dev/tty; then ans="n"; fi
fi

case "$ans" in
  y|Y|yes|YES)
    ;;
  *)
    echo
    info "Aborting. No files were deleted."
    exit 0
    ;;
esac

echo
info "Deleting junk files…"

DELETED=0
FAILED=0
while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  if rm -f -- "$f" 2>/dev/null; then
    DELETED=$((DELETED + 1))
  else
    FAILED=$((FAILED + 1))
    warn "Failed to delete: $f"
  fi
done <"$CANDIDATES"

echo
info "Junk deletion complete."
info "Deleted: $DELETED files."
[ "$FAILED" -gt 0 ] && warn "Failed to delete: $FAILED files (see messages above)."

exit 0
