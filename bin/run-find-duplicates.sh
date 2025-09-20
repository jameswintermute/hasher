#!/usr/bin/env bash
# run-find-duplicates.sh — Menu Option 3 helper
# Shows a simple spinner while find-duplicates.sh runs, then prints clear next steps.
# BusyBox-friendly. License: GPLv3
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
mkdir -p "$LOGS_DIR"

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

latest_hasher_csv() {
  ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true
}

latest_duplicate_report() {
  if [[ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]]; then
    printf "%s" "$LOGS_DIR/duplicate-hashes-latest.txt"; return 0
  fi
  local newest
  newest="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$newest" && -s "$newest" ]]; then
    printf "%s" "$newest"; return 0
  fi
  return 1
}

report_has_groups() {
  local r="$1"
  grep -qE '^HASH[[:space:]]+[a-fA-F0-9]+[[:space:]]+\(N=[0-9]+\)' -- "$r" 2>/dev/null
}

spinner_start() {
  { i=0; frames='|/-\\'; while :; do i=$(( (i+1) % 4 )); printf "\r[%c] Generating duplicate groups…" "${frames:$i:1}" >&2; sleep 0.2; done; } &
  echo $!
}
spinner_stop() { local pid="$1"; [[ -n "${pid:-}" ]] && kill "$pid" >/dev/null 2>&1 || true; printf "\r%*s\r" 60 "" >&2; }

csv="$(latest_hasher_csv || true)"
if [[ -z "${csv:-}" || ! -f "$csv" ]]; then
  err "No hasher CSV found in $HASHES_DIR."
  info "Run hashing first (menu option 1), then re-run 'Find duplicate files' (option 3)."
  exit 1
fi

info "Using hashes file: $csv"
info "Building duplicate groups (this is usually fast on NAS)…"
spid="$(spinner_start)"
set +e
"$BIN_DIR/find-duplicates.sh" >/tmp/find-duplicates.out 2>&1
rc=$?
set -e
spinner_stop "$spid"

if (( rc != 0 )); then
  err "find-duplicates.sh failed (exit $rc)."
  warn "See: /tmp/find-duplicates.out"
  exit $rc
fi

report="$(latest_duplicate_report || true)"
if [[ -n "${report:-}" && -s "$report" ]]; then
  if report_has_groups "$report"; then
    groups="$(grep -c '^HASH ' -- "$report" 2>/dev/null || echo 0)"
    info "Canonical report: $report  (groups: ${groups})"
    info "Next: choose 'Review duplicates (interactive)' — menu option 4."
  else
    warn "Report generated but contains 0 duplicate groups."
    info "You can still run option 4, but it will exit quickly with no actions."
  fi
else
  err "Failed to generate duplicate-hashes report."
  warn "Check /tmp/find-duplicates.out for details."
  exit 2
fi

exit 0
