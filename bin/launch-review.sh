#!/bin/sh
# launch-review.sh — Option 4 helper (POSIX/BusyBox-safe) for interactive review
# Updated for Hasher v1.0.9:
# - Uses logs/duplicates-*.csv (not duplicate-hashes-*.txt)
# - Orchestrates generating duplicates CSV if missing, then calls review-duplicates.sh

set -eu

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
mkdir -p "$LOGS_DIR"

COK="$(printf '\033[0;32m')"
CWARN="$(printf '\033[1;33m')"
CERR="$(printf '\033[0;31m')"
CCYAN="$(printf '\033[0;36m')"
CRESET="$(printf '\033[0m')"

info(){ printf "%s[INFO]%s %s\n"  "$COK"   "$CRESET" "$*"; }
warn(){ printf "%s[WARN]%s %s\n"  "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR"  "$CRESET" "$*"; }
next(){ printf "%s[NEXT]%s %s\n" "$CCYAN" "$CRESET" "$*"; }

latest_duplicates_csv() {
  ls -1t "$LOGS_DIR"/duplicates-*.csv 2>/dev/null | head -n1 || true
}

latest_hasher_csv() {
  ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true
}

prompt_yn() {
  msg="$1"
  def="${2:-Y}"
  case "$def" in
    Y|y) p=" [Y/n] " ;;
    *)   p=" [y/N] " ;;
  esac
  printf "%s%s" "$msg" "$p"
  read -r a || a=""
  [ -z "$a" ] && a="$def"
  case "$a" in
    Y|y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

info "Preparing interactive review…"

dups_csv="$(latest_duplicates_csv || true)"

if [ -z "${dups_csv:-}" ] || [ ! -s "$dups_csv" ]; then
  warn "No usable duplicates CSV found in $LOGS_DIR."
  csv="$(latest_hasher_csv || true)"
  if [ -n "${csv:-}" ] && [ -f "$csv" ]; then
    info "Found latest hasher CSV: $csv"
    if prompt_yn "Run 'find-duplicates' now to generate a duplicates CSV?" "Y"; then
      if [ -x "$BIN_DIR/run-find-duplicates.sh" ]; then
        info "Generating duplicates via run-find-duplicates.sh…"
        if ! "$BIN_DIR/run-find-duplicates.sh"; then
          err "run-find-duplicates.sh failed."
          exit 1
        fi
      elif [ -x "$BIN_DIR/find-duplicates.sh" ]; then
        info "Generating duplicates via find-duplicates.sh…"
        if ! "$BIN_DIR/find-duplicates.sh" --input "$csv"; then
          err "find-duplicates.sh failed."
          exit 1
        fi
      else
        err "No run-find-duplicates.sh or find-duplicates.sh found in $BIN_DIR."
        exit 1
      fi
      dups_csv="$(latest_duplicates_csv || true)"
    else
      next "Run menu option 3 first (Find duplicate files), then re-run option 4."
      exit 0
    fi
  else
    err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."
    exit 1
  fi
fi

if [ -z "${dups_csv:-}" ] || [ ! -s "$dups_csv" ]; then
  err "Failed to locate a duplicates CSV after generation."
  exit 1
fi

info "Using duplicates CSV: $dups_csv"
exec "$BIN_DIR/review-duplicates.sh" "$dups_csv"
