#!/usr/bin/env bash
# launcher.sh — NAS File Hasher & Dedupe menu
# Requires bash; calls into scripts under ./bin
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$SCRIPT_DIR"
BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
VAR_DIR="$APP_HOME/var"
mkdir -p "$BIN_DIR" "$LOGS_DIR" "$HASHES_DIR" "$VAR_DIR"

# Colors + ui
c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_reset='\033[0m'
info() { printf "${c_green}[INFO]${c_reset} %b\n" "$*"; }
warn() { printf "${c_yellow}[WARN]${c_reset} %b\n" "$*"; }
err()  { printf "${c_red}[ERROR]${c_reset} %b\n" "$*"; }
press_any() { read -r -p "Press ENTER to continue..." _ || true; }

require() {
  local p="$1"
  if [[ ! -x "$p" ]]; then
    if [[ -f "$p" ]]; then
      warn "Making executable: $p"; chmod +x "$p" || true
    fi
  fi
  [[ -x "$p" ]] || { err "Missing or not executable: $p"; return 1; }
}

latest_hashes_csv() {
  ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true
}

banner() {
cat <<'BANNER'
 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe
BANNER
}

show_menu() {
  banner
  cat <<'MENU'

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
MENU
  echo
}

# ---------- Actions ----------

act_check_status() {
  local f="$LOGS_DIR/background.log"
  if [[ -f "$f" ]]; then
    info "Tail: $f (Ctrl+C to exit)"
    tail -n 100 -f "$f"
  else
    warn "No background.log yet. Hashing may not be running."
  fi
}

act_start_hashing() {
  local sh="$BIN_DIR/hasher.sh"
  require "$sh" || { press_any; return; }
  info "Using hashes dir: $HASHES_DIR"
  # Runs with NAS-safe defaults (script controls flags)
  bash "$sh" || warn "Hasher exited non-zero."
  press_any
}

act_hashing_advanced() {
  local sh="$BIN_DIR/hasher.sh"
  require "$sh" || { press_any; return; }
  info "Launching advanced/custom hashing..."
  bash "$sh" --advanced || warn "Advanced hasher exited non-zero."
  press_any
}

act_find_duplicate_folders() {
  local script="$BIN_DIR/find-duplicate-folders.sh"
  require "$script" || { press_any; return; }
  local base
  base="$(latest_hashes_csv)"
  if [[ -z "$base" ]]; then
    warn "No hasher CSV found in $HASHES_DIR. Run Stage 1 first."
    press_any; return
  fi
  info "Using hashes file: $base"
  bash "$script" --input "$base" | tee -a "$LOGS_DIR/find-duplicate-folders.log"

  local SUM PLAN
  SUM="$(ls -1t "$LOGS_DIR"/duplicate-folders-*.txt 2>/dev/null | head -n1 || true)"
  PLAN="$APP_HOME/var/duplicates/latest-folder-plan.txt"

  echo
  if [[ -n "$SUM" && -f "$SUM" ]]; then
    info "Summary: $SUM"
    sed -n '1,80p' "$SUM" || true
  else
    warn "No summary file produced."
  fi

  if [[ ! -s "$PLAN" ]]; then
    echo
    info "Verified hashes, zero duplicate folders. Please proceed to the duplicate FILE checker."
    press_any; return
  fi

  # Parse scope/signature to re-use for bulk
  local scope sig
  scope="$(awk -F': ' '/^Scope:/{print $2}' "$SUM" | head -n1)"
  sig="$(awk   -F': ' '/^Signature:/{print $2}' "$SUM" | head -n1)"
  scope=${scope:-recursive}
  sig=${sig:-name+content}

  while :; do
    echo
    echo "What would you like to do?"
    echo "  r) Review the duplicates (open summary)"
    echo "  b) Bulk delete (DANGER): keep newest copy -> quarantine"
    echo "  q) Quit back to main menu"
    read -r -p "Choose [r/b/q]: " choice
    case "$choice" in
      r|R)
        if command -v less >/dev/null 2>&1; then
          less -N "$SUM"
        else
          sed -n '1,200p' "$SUM"; read -r -p "Press ENTER to return..." _
        fi
        ;;
      b|B)
        echo "This will MOVE duplicates (except the newest) to a quarantine folder."
        read -r -p "Type 'DELETE' to confirm: " conf
        [[ "$conf" == "DELETE" ]] || { echo "Cancelled."; continue; }
        local qdir="$APP_HOME/var/quarantine/$(date +%F)"
        bash "$script" \
          --input "$base" --mode apply --force --quarantine "$qdir" \
          --keep-strategy newest --scope "$scope" --signature "$sig" \
          | tee -a "$LOGS_DIR/find-duplicate-folders.log"
        info "Bulk move complete. Quarantine: $qdir"
        press_any; break
        ;;
      q|Q) break ;;
      *) echo "Invalid choice."; ;
    esac
  done
}

act_find_dupe_files() {
  local find_sh="$BIN_DIR/find-duplicates.sh"
  local review_sh="$BIN_DIR/review-duplicates.sh"
  require "$find_sh" || { press_any; return; }
  require "$review_sh" || { press_any; return; }

  local latest_csv
  latest_csv="$(latest_hashes_csv)"
  if [[ -z "$latest_csv" ]]; then
    err "No hasher CSV found in $HASHES_DIR. Run Stage 1 first."
    press_any; return
  fi
  info "Using hashes file: $latest_csv"
  echo
  echo "Select mode:"
  echo "  1) Standard (interactive review)"
  echo "  2) Bulk (auto, keep newest)"
  echo "  q) Back"
  read -r -p "Enter choice [1/2/q]: " m
  case "$m" in
    1)
      bash "$find_sh" --input "$latest_csv" | tee -a "$LOGS_DIR/find-duplicates.log"
      local report
      report="$(ls -1t "$LOGS_DIR"/*duplicate-hashes*.txt 2>/dev/null | head -n1)"
      if [[ -z "$report" || ! -f "$report" ]]; then
        err "No duplicate report produced."; press_any; return
      fi
      info "Launching interactive reviewer with: $report"
      bash "$review_sh" --from-report "$report" --keep newest
      ;;
    2)
      bash "$find_sh" --input "$latest_csv" | tee -a "$LOGS_DIR/find-duplicates.log"
      local report
      report="$(ls -1t "$LOGS_DIR"/*duplicate-hashes*.txt 2>/dev/null | head -n1)"
      if [[ -z "$report" || ! -f "$report" ]]; then
        err "No duplicate report produced."; press_any; return
      fi
      info "Building a plan automatically (keep newest across groups)…"
      bash "$review_sh" --from-report "$report" --non-interactive --keep newest
      local plan
      plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1)"
      if [[ -n "$plan" ]]; then
        echo "[NEXT] Review the plan: $plan"
        echo "[TIP] Dry-run delete:   bin/delete-duplicates.sh --from-plan \"$plan\""
        echo "[TIP] Execute delete:   bin/delete-duplicates.sh --from-plan \"$plan\" --force"
        echo "[TIP] Quarantine move:  bin/delete-duplicates.sh --from-plan \"$plan\" --force --quarantine \"var/quarantine/$(date +%F)\""
      else
        info "No deletable duplicates identified."
      fi
      ;;
    q|Q) ;;
    *) warn "Invalid choice." ;;
  esac
  press_any
}

act_review_interactive() {
  local review_sh="$BIN_DIR/review-duplicates.sh"
  require "$review_sh" || { press_any; return; }
  local report
  report="$(ls -1t "$LOGS_DIR"/*duplicate-hashes*.txt 2>/dev/null | head -n1)"
  if [[ -z "$report" ]]; then
    warn "No duplicate FILE report found in logs/. Run Option 3 first."
    press_any; return
  fi
  info "Starting reviewer for: $report"
  bash "$review_sh" --from-report "$report" --keep newest
  press_any
}

act_delete_zeros() {
  local sh="$BIN_DIR/delete-zero-length.sh"
  require "$sh" || { press_any; return; }
  bash "$sh" || warn "Zero-length cleanup exited non-zero."
  press_any
}

act_apply_deletes() {
  local folder_plan="$APP_HOME/var/duplicates/latest-folder-plan.txt"
  local sh="$BIN_DIR/find-duplicate-folders.sh"
  if [[ -s "$folder_plan" ]]; then
    info "Applying folder dedupe plan via quarantine move (recommended)."
    bash "$sh" --mode apply --force --quarantine "$APP_HOME/var/quarantine/$(date +%F)"
  else
    warn "No folder plan found at $folder_plan"
  fi
  press_any
}

act_system_check() {
  local sh="$BIN_DIR/system-check.sh"
  if [[ -x "$sh" ]]; then
    bash "$sh" | tee -a "$LOGS_DIR/system-check.log"
  else
    warn "No system-check.sh found. Checking core deps quickly..."
    for c in bash awk sort uniq sha256sum shasum openssl md5sum stat; do
      if command -v "$c" >/dev/null 2>&1; then echo "  ✔ $c"; else echo "  ✖ $c (optional)"; fi
    done
  fi
  press_any
}

act_view_logs() {
  local f="$LOGS_DIR/background.log"
  if [[ -f "$f" ]]; then tail -n 200 "$f"; else warn "No background.log yet."; fi
  press_any
}

# ---------- Main loop ----------
while :; do
  clear || true
  show_menu
  read -r -p "Choose an option: " menu_choice
  case "$menu_choice" in
    0) act_check_status ;;
    1) act_start_hashing ;;
    8) act_hashing_advanced ;;
    2) act_find_duplicate_folders ;;
    3) act_find_dupe_files ;;
    4) act_review_interactive ;;
    5) act_delete_zeros ;;
    6) act_apply_deletes ;;
    7) act_system_check ;;
    9) act_view_logs ;;
    q|Q) exit 0 ;;
    *) warn "Unknown option: $menu_choice"; press_any ;;
  esac
done
