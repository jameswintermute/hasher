#!/bin/sh
# launch-review.sh — Menu Option 4 helper (POSIX/BusyBox-safe)
set -eu

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
mkdir -p "$LOGS_DIR"

# Colours
COK="$(printf '\033[0;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[0;31m')"; CRESET="$(printf '\033[0m')"
info(){ printf "%s[INFO]%s %s\n" "$COK" "$CRESET" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR" "$CRESET" "$*"; }

# Spinner (BusyBox-safe)
spinner_start() {
  (
    while :; do
      for c in '|' '/' '-' '\\'; do
        printf "\r[%s] Generating duplicate groups…" "$c" >&2
        sleep 0.2
      done
    done
  ) &
  echo "$!"
}
spinner_stop() {
  pid="$1"
  [ -n "${pid:-}" ] && kill "$pid" >/dev/null 2>&1 || true
  printf "\r%*s\r" 60 "" >&2
}

latest_duplicate_report() {
  if [ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]; then
    printf "%s" "$LOGS_DIR/duplicate-hashes-latest.txt"; return 0
  fi
  # shellcheck disable=SC2012
  newest="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [ -n "${newest:-}" ] && [ -s "$newest" ]; then printf "%s" "$newest"; return 0; fi
  return 1
}
latest_hasher_csv() {
  # shellcheck disable=SC2012
  ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true
}
report_has_groups() {
  r="$1"
  grep -q '^HASH ' -- "$r" 2>/dev/null
}

prompt_yn() {
  msg="$1"; def="${2:-Y}"
  case "$def" in Y|y) prompt=" [Y/n] " ;; *) prompt=" [y/N] " ;; esac
  printf "%s%s" "$msg" "$prompt"; read -r ans || ans=""
  [ -z "${ans:-}" ] && ans="$def"
  case "$ans" in Y|y|yes|YES) return 0 ;; *) return 1 ;; esac
}

info "Preparing interactive review…"

report="$(latest_duplicate_report || true)"
if [ -z "${report:-}" ] || [ ! -s "$report" ] || ! report_has_groups "$report"; then
  warn "No usable duplicate-hashes report found."
  csv="$(latest_hasher_csv || true)"
  if [ -n "${csv:-}" ] && [ -f "$csv" ]; then
    info "Found latest hasher CSV: $csv"
    if prompt_yn "Run 'find-duplicates.sh' now to generate the report?" "Y"; then
      info "Generating duplicates report…"
      spid="$(spinner_start)"
      set +e
      "$BIN_DIR/find-duplicates.sh" >/tmp/find-duplicates.out 2>&1
      rc=$?
      set -e
      spinner_stop "$spid"
      if [ "$rc" -ne 0 ]; then
        err "find-duplicates.sh failed (exit $rc). See /tmp/find-duplicates.out"
        exit "$rc"
      fi
      report="$(latest_duplicate_report || true)"
    else
      warn "Skipped generating duplicates. Use menu option 3 first."
      exit 0
    fi
  else
    err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."
    exit 1
  fi
fi

if [ -z "${report:-}" ] || [ ! -s "$report" ]; then
  err "Failed to locate a duplicates report after generation."
  exit 1
fi

info "Using report: $report"
exec "$BIN_DIR/review-duplicates.sh" --from-report "$report"
