#!/usr/bin/env bash
# launch-review.sh — Menu Option 4 helper
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

spinner_start() { { i=0; frames='|/-\\'; while :; do i=$(( (i+1) % 4 )); printf "\r[%c] Generating duplicate groups…" "${frames:$i:1}" >&2; sleep 0.2; done; } & echo $!; }
spinner_stop() { local pid="$1"; [[ -n "${pid:-}" ]] && kill "$pid" >/dev/null 2>&1 || true; printf "\r%*s\r" 60 "" >&2; }

latest_duplicate_report() {
  if [[ -s "$LOGS_DIR/duplicate-hashes-latest.txt" ]]; then printf "%s" "$LOGS_DIR/duplicate-hashes-latest.txt"; return 0; fi
  local newest; newest="$(ls -1t "$LOGS_DIR"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$newest" && -s "$newest" ]]; then printf "%s" "$newest"; return 0; fi
  return 1
}

latest_hasher_csv() { ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
report_has_groups() { local r="$1"; grep -qE '^HASH[[:space:]]+[a-fA-F0-9]+[[:space:]]+\(N=[0-9]+\)' -- "$r" 2>/dev/null; }

prompt_yn() {
  local msg="$1" def="${2:-Y}" prompt=" [Y/n] "
  [[ "$def" == "N" || "$def" == "n" ]] && prompt=" [y/N] "
  read -rp "$msg$prompt" ans || true
  ans="${ans:-$def}"; case "$ans" in Y|y|yes|YES) return 0 ;; *) return 1 ;; esac
}

info "Preparing interactive review…"
report="$(latest_duplicate_report || true)"
if [[ -z "${report:-}" || ! -s "$report" || ! report_has_groups "$report" ]]; then
  warn "No usable duplicate-hashes report found."
  csv="$(latest_hasher_csv || true)"
  if [[ -n "${csv:-}" && -f "$csv" ]]; then
    info "Found latest hasher CSV: $csv"
    if prompt_yn "Run 'find-duplicates.sh' now to generate the report?" "Y"; then
      info "Generating duplicates report…"
      spid="$(spinner_start)"; set +e
      "$BIN_DIR/find-duplicates.sh" >/tmp/find-duplicates.out 2>&1
      rc=$?; set -e
      spinner_stop "$spid"
      if (( rc != 0 )); then err "find-duplicates.sh failed (exit $rc). See /tmp/find-duplicates.out"; exit $rc; fi
      report="$(latest_duplicate_report || true)"
    else
      warn "Skipped generating duplicates. Use menu option 3 first."; exit 0
    fi
  else
    err "No hasher CSV found in $HASHES_DIR. Run hashing first (menu option 1)."; exit 1
  fi
fi

if [[ -z "${report:-}" || ! -s "$report" ]]; then err "Failed to locate a duplicates report after generation."; exit 1; fi
info "Using report: $report"
exec "$BIN_DIR/review-duplicates.sh" --from-report "$report"
