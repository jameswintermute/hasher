#!/usr/bin/env bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ────────────────────────────── Globals ──────────────────────────────
ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT_DIR"

LOGS_DIR="$ROOT_DIR/logs"
HASHES_DIR="$ROOT_DIR/hashes"
BIN_DIR="$ROOT_DIR/bin"
VAR_DIR="$ROOT_DIR/var"
LOCAL_DIR="$ROOT_DIR/local"

mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$BIN_DIR" "$VAR_DIR" "$LOCAL_DIR"

BACKGROUND_LOG="$LOGS_DIR/background.log"

# ────────────────────────────── Helpers ──────────────────────────────
c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }

press_any() { printf "\nPress ENTER to continue..."; read -r _; }

paths_file_default() {
  # Prefer user override in local/paths.txt if present; else fall back to paths.txt
  if [[ -f "$LOCAL_DIR/paths.txt" ]]; then
    printf "%s\n" "$LOCAL_DIR/paths.txt"
  elif [[ -f "$ROOT_DIR/paths.txt" ]]; then
    printf "%s\n" "$ROOT_DIR/paths.txt"
  else
    printf "%s\n" ""
  fi
}

latest_hashes_csv() {
  # Pick the newest hasher CSV
  local f
  f="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
  printf "%s" "${f:-}"
}

require() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    err "Missing or not executable: $path"
    exit 1
  fi
}

run_tail_background() {
  if [[ -f "$BACKGROUND_LOG" ]]; then
    info "Tailing $BACKGROUND_LOG (Ctrl+C to stop)…"
    tail -f "$BACKGROUND_LOG"
  else
    warn "No $BACKGROUND_LOG yet."
  fi
}

# ────────────────────────────── Menu Actions ─────────────────────────
act_check_status() {
  run_tail_background
}

act_start_hashing_defaults() {
  require "$ROOT_DIR/hasher.sh"
  local pf; pf="$(paths_file_default)"
  if [[ -z "$pf" ]]; then
    warn "No paths file found. Create $LOCAL_DIR/paths.txt or ./paths.txt"
    press_any; return
  fi
  info "Starting hashing with NAS-safe defaults…"
  info "Paths file: $pf"
  # Defaults: sha256, nohup in background
  "$ROOT_DIR/hasher.sh" --pathfile "$pf" --algo sha256 --nohup | tee -a "$BACKGROUND_LOG"
  press_any
}

act_start_hashing_advanced() {
  require "$ROOT_DIR/hasher.sh"
  local pf; pf="$(paths_file_default)"
  printf "Paths file [%s]: " "${pf:-<none>}"; read -r in_pf; pf="${in_pf:-$pf}"
  [[ -z "$pf" ]] && { err "No paths file provided."; press_any; return; }

  printf "Algo [sha256|sha1|sha512|md5|blake2] (default sha256): "; read -r algo; algo="${algo:-sha256}"
  printf "Run in background? [y/N]: "; read -r yn
  if [[ "${yn,,}" == "y" ]]; then
    "$ROOT_DIR/hasher.sh" --pathfile "$pf" --algo "$algo" --nohup | tee -a "$BACKGROUND_LOG"
  else
    "$ROOT_DIR/hasher.sh" --pathfile "$pf" --algo "$algo" | tee -a "$BACKGROUND_LOG"
  fi
  press_any
}

act_find_duplicate_folders() {
  local script="$BIN_DIR/find-duplicate-folders.sh"
  require "$script"
  local base="$(latest_hashes_csv)"
  if [[ -z "$base" ]]; then
    warn "No hasher CSV found in $HASHES_DIR. Run Stage 1 first."
    press_any; return
  fi
  info "Using hashes file: $base"
  "$script" --input "$base" | tee -a "$LOGS_DIR/find-duplicate-folders.log"
  press_any
}

act_find_duplicate_files() {
  local script="$BIN_DIR/find-duplicates.sh"
  require "$script"
  local base="$(latest_hashes_csv)"
  if [[ -z "$base" ]]; then
    warn "No hasher CSV found in $HASHES_DIR. Run Stage 1 first."
    press_any; return
  fi
  info "Using hashes file: $base"
  printf "Mode: 1) Standard (interactive)  2) Bulk (auto) [1/2]: "; read -r mode_pick
  if [[ "$mode_pick" == "2" ]]; then
    "$script" --input "$base" --mode bulk | tee -a "$LOGS_DIR/find-duplicates.log"
  else
    "$script" --input "$base" --mode standard | tee -a "$LOGS_DIR/find-duplicates.log"
  fi
  press_any
}

act_review_duplicates() {
  local script="$BIN_DIR/review-duplicates.sh"
  require "$script"
  "$script"
  press_any
}

act_delete_zero_length() {
  local script="$BIN_DIR/delete-zero-length.sh"
  require "$script"
  printf "Dry run first? [Y/n]: "; read -r yn; yn="${yn:-Y}"
  if [[ "${yn,,}" == "n" ]]; then
    "$script"
  else
    "$script" --dry-run
  fi
  press_any
}

act_delete_duplicates_apply_plan() {
  local script="$BIN_DIR/delete-duplicates.sh"
  require "$script"
  printf "Plan file to apply [leave blank for latest generated plan]: "
  read -r plan
  if [[ -z "$plan" ]]; then
    # Find most recent plan
    plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$plan" || ! -f "$plan" ]]; then
    warn "No plan file found. Generate one via 'Find duplicate files' (Bulk) or 'Review duplicates'."
    press_any; return
  fi
  info "Applying plan: $plan"
  printf "Final confirmation — permanently delete listed files? [type YES]: "
  read -r confirm
  if [[ "$confirm" == "YES" ]]; then
    "$script" --plan "$plan"
  else
    warn "Aborted."
  fi
  press_any
}

act_system_check() {
  local script="$BIN_DIR/system-check.sh"
  if [[ -x "$script" ]]; then
    "$script" | tee -a "$LOGS_DIR/system-check.log"
  else
    warn "No system-check.sh found. Skipping."
  fi
  press_any
}

act_tail_logs() {
  run_tail_background
}

# ────────────────────────────── Menu UI ──────────────────────────────
print_header() {
  cat <<'ASCII'
 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe
ASCII
}

print_menu() {
  print_header
  cat <<EOF

### Stage 1 - Hash ###
  0) Check hashing status
  1) Start Hashing (NAS-safe defaults)
  8) Advanced / Custom hashing

### Stage 2 - Identify ###
  2) Find duplicate folders
  3) Find duplicate files

### Stage 3 - Clean up ###
  4) Review duplicates (interactive)
  5) Delete zero-length files
  6) Delete duplicates (apply plan)

### Other ###
  7) System check (deps & readiness)
  9) View logs (tail background.log)

  q) Quit
EOF
}

dispatch() {
  case "${1:-}" in
    0) act_check_status ;;
    1) act_start_hashing_defaults ;;
    2) act_find_duplicate_folders ;;
    3) act_find_duplicate_files ;;
    4) act_review_duplicates ;;
    5) act_delete_zero_length ;;
    6) act_delete_duplicates_apply_plan ;;
    7) act_system_check ;;
    8) act_start_hashing_advanced ;;
    9) act_tail_logs ;;
    q|Q) exit 0 ;;
    *) warn "Unknown option: $1"; press_any ;;
  esac
}

# ────────────────────────────── Main Loop ────────────────────────────
while true; do
  clear || true
  print_menu
  printf "\nChoose an option: "
  read -r choice
  dispatch "$choice"
done
