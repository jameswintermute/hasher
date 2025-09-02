#!/usr/bin/env bash
# launcher.sh — menu launcher for Hasher & Dedupe toolkit
# Copyright (C) 2025
# License: GPLv3
#
# Notes:
# - Restores "Delete junk files" (option 4) and adds "Delete zero-length files" (option 5).
# - Adds "System check (deps & readiness)" under the "Other" section.
# - Designed to be run from the repository root.
# - Calls: hasher.sh, find-duplicates.sh, delete-duplicates.sh, delete-junk.sh (if present), bin/check-deps.sh (if present).

set -Eeuo pipefail
IFS=$'\n\t'

# ────────────────────────────── Globals ──────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

LOGS_DIR="$ROOT_DIR/logs"
HASHES_DIR="$ROOT_DIR/hashes"
BACKGROUND_LOG="$LOGS_DIR/background.log"

mkdir -p "$LOGS_DIR" "$HASHES_DIR"

is_tty() { [[ -t 1 ]]; }
if is_tty; then
  C_GRN="\033[0;32m"; C_YLW="\033[1;33m"; C_RED="\033[0;31m"; C_CYN="\033[0;36m"; C_MGN="\033[0;35m"; C_BLU="\033[0;34m"; C_RST="\033[0m"
else
  C_GRN=""; C_YLW=""; C_RED=""; C_CYN=""; C_MGN=""; C_BLU=""; C_RST=""
fi

pause() { read -r -p "Press Enter to return to the menu..." _; }
exists() { [[ -f "$1" ]]; }
have() { command -v "$1" >/dev/null 2>&1; }

# ────────────────────────────── Banner ───────────────────────────────
banner() {
  clear 2>/dev/null || true
  cat <<'EOF'

 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe

EOF
}

# ─────────────────────────── Helper funcs ────────────────────────────
latest_csv() {
  # Prefer explicit latest.csv if present; else newest hasher-*.csv
  if [[ -f "$HASHES_DIR/latest.csv" ]]; then
    echo "$HASHES_DIR/latest.csv"
    return 0
  fi
  local newest
  newest="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
  if [[ -n "$newest" && -f "$newest" ]]; then
    echo "$newest"
    return 0
  fi
  return 1
}

status_summary() {
  echo -e "${C_CYN}### Hashing status ###${C_RST}"
  if [[ -f "$BACKGROUND_LOG" ]]; then
    echo "- Log: $BACKGROUND_LOG"
    echo "- Recent progress:"
    # Show the last 12 PROGRESS lines if available, else tail the log
    if grep -q "\[PROGRESS\]" "$BACKGROUND_LOG"; then
      grep "\[PROGRESS\]" "$BACKGROUND_LOG" | tail -n 12
    else
      tail -n 12 "$BACKGROUND_LOG"
    fi
  else
    echo "No background log found at $BACKGROUND_LOG"
  fi

  echo
  local csv; if csv="$(latest_csv)"; then
    local rows; rows="$(wc -l <"$csv" | tr -d ' ')" || rows="unknown"
    echo -e "${C_CYN}### Latest CSV ###${C_RST}"
    echo "File: $csv"
    echo "Rows (incl. header): $rows"
  else
    echo -e "${C_YLW}No CSV files found in $HASHES_DIR yet.${C_RST}"
  fi
}

start_hashing_defaults() {
  echo -e "${C_CYN}Starting hashing (NAS-safe defaults)…${C_RST}"
  local args=(--algo sha256 --nohup)
  # If a default pathfile exists, use it
  if [[ -f "$ROOT_DIR/paths.txt" ]]; then
    args+=(--pathfile "$ROOT_DIR/paths.txt")
    echo "Using pathfile: $ROOT_DIR/paths.txt"
  fi
  echo "Command: ./hasher.sh ${args[*]}"
  echo
  ./hasher.sh "${args[@]}" || {
    echo -e "${C_RED}hasher.sh failed. See logs for details.${C_RST}"
    return 1
  }
}

advanced_hashing() {
  echo -e "${C_CYN}Advanced / Custom hashing${C_RST}"
  echo "Enter additional flags for hasher.sh (example: --pathfile paths.txt --algo sha256 --nohup)"
  echo "Leave empty to cancel."
  printf "hasher.sh "
  read -r extra || true
  [[ -z "${extra:-}" ]] && { echo "Cancelled."; return 0; }
  # shellcheck disable=SC2086
  ./hasher.sh $extra
}

run_find_duplicates() {
  echo -e "${C_CYN}Running find-duplicates…${C_RST}"
  local in outdir ts
  ts="$(date +'%Y-%m-%d-%H%M%S')"
  outdir="$LOGS_DIR/du-$ts"
  mkdir -p "$outdir"

  if in="$(latest_csv)"; then
    echo "Input CSV: $in"
  else
    echo -e "${C_RED}No input CSV found. Run hashing first.${C_RST}"
    return 1
  fi

  local cmd=(./find-duplicates.sh --input "$in" --out "$outdir")
  if have ionice; then cmd=(ionice -c3 nice -n 19 "${cmd[@]}"); fi

  echo "Command: ${cmd[*]}"
  # shellcheck disable=SC2068
  ${cmd[@]} || {
    echo -e "${C_RED}find-duplicates.sh failed.${C_RST}"
    return 1
  }

  echo
  echo "Outputs (if script succeeded):"
  for f in "$outdir"/duplicates.csv "$outdir"/groups.summary.txt "$outdir"/top-groups.txt "$outdir"/reclaimable.txt; do
    [[ -f "$f" ]] && echo " - $f"
  done
}

run_delete_duplicates() {
  if ! [[ -f ./delete-duplicates.sh ]]; then
    echo -e "${C_YLW}delete-duplicates.sh not found. Skipping.${C_RST}"
    return 0
  fi
  echo -e "${C_RED}DANGER ZONE: This will delete files from duplicate groups.${C_RST}"
  read -r -p "Type 'DELETE' to proceed, anything else to cancel: " confirm
  [[ "$confirm" != "DELETE" ]] && { echo "Cancelled."; return 0; }

  local in
  if in="$(latest_csv)"; then
    echo "Using CSV: $in"
  else
    echo -e "${C_RED}No CSV found. Aborting.${C_RST}"
    return 1
  fi

  local cmd=(./delete-duplicates.sh --input "$in")
  if have ionice; then cmd=(ionice -c3 nice -n 19 "${cmd[@]}"); fi

  echo "Command: ${cmd[*]}"
  # shellcheck disable=SC2068
  ${cmd[@]} || {
    echo -e "${C_RED}delete-duplicates.sh failed.${C_RST}"
    return 1
  }
}

_supports_flag() {
  # $1 = script path, $2 = flag to probe
  # returns 0 if --help output mentions the flag
  local script="$1" flag="$2"
  "$script" --help >/dev/null 2>&1 || true
  "$script" --help 2>&1 | grep -qi -- "$flag"
}

run_delete_junk() {
  echo -e "${C_CYN}Delete junk files (safe flow)…${C_RST}"
  local script="./delete-junk.sh"
  if ! [[ -f "$script" ]]; then
    echo -e "${C_YLW}delete-junk.sh not found in repo root.${C_RST}"
    echo "If you have it elsewhere, place it here and make it executable: chmod +x delete-junk.sh"
    return 0
  fi
  if ! [[ -x "$script" ]]; then
    chmod +x "$script" || true
  fi

  # Build arguments based on supported flags
  local args=()
  if [[ -f "$ROOT_DIR/paths.txt" ]]; then
    if _supports_flag "$script" "--pathfile"; then
      args+=(--pathfile "$ROOT_DIR/paths.txt")
      echo "Using pathfile: $ROOT_DIR/paths.txt"
    elif _supports_flag "$script" "--paths"; then
      args+=(--paths "$ROOT_DIR/paths.txt")
      echo "Using paths: $ROOT_DIR/paths.txt"
    fi
  fi

  local dryrun_flag=""
  if _supports_flag "$script" "--dry-run"; then
    dryrun_flag="--dry-run"
  elif _supports_flag "$script" "-n"; then
    dryrun_flag="-n"
  fi

  local cmd_preview=("$script" "${args[@]}")
  if [[ -n "$dryrun_flag" ]]; then
    cmd_preview+=("$dryrun_flag")
  fi

  # Preview (dry-run if supported)
  echo
  echo -e "${C_BLU}Preview (no deletions will occur in this step)…${C_RST}"
  echo "Command: ${cmd_preview[*]}"
  echo
  if have ionice; then cmd_preview=(ionice -c3 nice -n 19 "${cmd_preview[@]}"); fi
  # shellcheck disable=SC2068
  ${cmd_preview[@]} || true

  echo
  echo -e "${C_RED}Proceed to ACTUAL deletion?${C_RST}"
  read -r -p "Type 'APPLY' to delete junk files, anything else to cancel: " go
  [[ "$go" != "APPLY" ]] && { echo "Cancelled."; return 0; }

  local cmd_apply=("$script" "${args[@]}")
  # Some scripts use --apply; if supported, prefer it.
  if _supports_flag "$script" "--apply"; then
    cmd_apply+=(--apply)
  fi
  echo "Command: ${cmd_apply[*]}"
  if have ionice; then cmd_apply=(ionice -c3 nice -n 19 "${cmd_apply[@]}"); fi
  # shellcheck disable=SC2068
  ${cmd_apply[@]}
}

# Delete zero-length files native flow (no external script required)
run_delete_zero_length() {
  echo -e "${C_CYN}Delete zero-length files (safe flow)…${C_RST}"

  local ts outdir nulfile listfile delog
  ts="$(date +'%Y-%m-%d-%H%M%S')"
  outdir="$LOGS_DIR/zlen-$ts"
  mkdir -p "$outdir"
  nulfile="$outdir/candidates.nul"
  listfile="$outdir/candidates.txt"
  delog="$outdir/deleted.txt"

  # Determine base paths
  local bases=()
  if [[ -f "$ROOT_DIR/paths.txt" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      bases+=("$line")
    done < "$ROOT_DIR/paths.txt"
  fi
  if [[ ${#bases[@]} -eq 0 ]]; then
    bases=("$ROOT_DIR")
    echo -e "${C_YLW}No paths.txt found or it was empty — scanning repo root: $ROOT_DIR${C_RST}"
    echo "Tip: create paths.txt to scope cleanups to specific directories."
  else
    echo "Scanning base paths from paths.txt:"
    printf ' - %s\n' "${bases[@]}"
  fi

  # Build find command per base and append to NUL list
  echo "Gathering zero-length candidates…"
  : > "$nulfile"
  for base in "${bases[@]}"; do
    # Use -prune to skip common NAS/OS special dirs
    # shellcheck disable=SC2016
    find "$base" \
      \( -type d \( -iname '#recycle' -o -name '@eaDir' -o -name '.Trash*' -o -name '.Spotlight-V100' -o -name '.fseventsd' \) -prune \) -o \
      -type f -size 0c -print0 >> "$nulfile" 2>/dev/null || true
  done

  # Count & write human list
  local count
  count="$(tr -cd '\0' < "$nulfile" | wc -c | tr -d ' ')" || count=0
  tr '\0' '\n' < "$nulfile" > "$listfile"

  if [[ "$count" -eq 0 ]]; then
    echo -e "${C_GRN}No zero-length files found. Nice and tidy!${C_RST}"
    echo "Report folder: $outdir"
    return 0
  fi

  echo -e "${C_YLW}Found $count zero-length files.${C_RST}"
  echo "List saved to: $listfile"
  echo
  echo "Sample:"
  head -n 20 "$listfile" || true
  if [[ "$count" -gt 20 ]]; then
    echo "… (see full list above)"
  fi
  echo
  echo -e "${C_RED}Proceed to delete ALL $count zero-length files listed?${C_RST}"
  read -r -p "Type 'APPLY' to delete them, anything else to cancel: " go
  [[ "$go" != "APPLY" ]] && { echo "Cancelled. No files were deleted."; return 0; }

  echo "Deleting…"
  : > "$delog"
  # Delete using a NUL-safe loop (portable even without xargs -0)
  # shellcheck disable=SC2162
  while IFS= read -r -d '' f; do
    if rm -f -- "$f"; then
      printf '%s\n' "$f" >> "$delog"
    fi
  done < "$nulfile"

  local dcount
  dcount="$(wc -l < "$delog" | tr -d ' ')" || dcount=0
  echo -e "${C_GRN}Deleted $dcount zero-length files.${C_RST}"
  echo "Deletion log: $delog"
}

run_system_check() {
  echo -e "${C_CYN}System check (deps & readiness)…${C_RST}"
  if [[ -x "$ROOT_DIR/bin/check-deps.sh" ]]; then
    "$ROOT_DIR/bin/check-deps.sh" --fix || true
  else
    echo -e "${C_YLW}bin/check-deps.sh not found or not executable.${C_RST}"
    echo "Create it from the template shared previously, then mark executable:"
    echo "  mkdir -p bin"
    echo "  chmod +x bin/check-deps.sh"
  fi
}

view_logs() {
  echo -e "${C_CYN}Tail logs/background.log (Ctrl+C to stop)…${C_RST}"
  if [[ -f "$BACKGROUND_LOG" ]]; then
    tail -n 50 -f "$BACKGROUND_LOG"
  else
    echo "No background log at $BACKGROUND_LOG"
  fi
}

# ────────────────────────────── Menu ────────────────────────────────
show_menu() {
  banner
  echo "### Stage 1 - Hash ###"
  echo "  0) Check hashing status"
  echo "  1) Start Hashing (NAS-safe defaults)"
  echo "  8) Advanced / Custom hashing"
  echo
  echo "### Stage 2 - Identify ###"
  echo "  2) Find duplicate hashes"
  echo "  3) Delete duplicates (DANGER)"
  echo
  echo "### Stage 3 - Clean up ###"
  echo "  4) Delete junk files"
  echo "  5) Delete zero-length files"
  echo
  echo "### Other ###"
  echo "  7) System check (deps & readiness)"
  echo "  9) View logs (tail background.log)"
  echo
  echo "  q) Quit"
  echo
}

main_loop() {
  while true; do
    show_menu
    read -r -p "Select an option: " choice
    case "${choice:-}" in
      0) clear 2>/dev/null || true; status_summary; echo; pause ;;
      1) clear 2>/dev/null || true; start_hashing_defaults; echo; pause ;;
      8) clear 2>/dev/null || true; advanced_hashing; echo; pause ;;
      2) clear 2>/dev/null || true; run_find_duplicates; echo; pause ;;
      3) clear 2>/dev/null || true; run_delete_duplicates; echo; pause ;;
      4) clear 2>/dev/null || true; run_delete_junk; echo; pause ;;
      5) clear 2>/dev/null || true; run_delete_zero_length; echo; pause ;;
      7) clear 2>/dev/null || true; run_system_check; echo; pause ;;
      9) clear 2>/dev/null || true; view_logs ;;
      q|Q) echo "Bye!"; exit 0 ;;
      *) echo -e "${C_YLW}Unknown option: ${choice}. Please try again.${C_RST}" ;;
    esac
  done
}

main_loop
