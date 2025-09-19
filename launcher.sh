\
    #!/usr/bin/env bash
    # launcher.sh — menu launcher for Hasher & Dedupe toolkit (with folder-plan apply + cache cleanup)
    set -Eeuo pipefail
    IFS=$'\n\t'; LC_ALL=C

    ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    cd "$ROOT_DIR"

    LOGS_DIR="$ROOT_DIR/logs"
    HASHES_DIR="$ROOT_DIR/hashes"
    BIN_DIR="$ROOT_DIR/bin"
    VAR_DIR="$ROOT_DIR/var"
    LOCAL_DIR="$ROOT_DIR/local"
    DEFAULT_DIR="$ROOT_DIR/default"

    mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$BIN_DIR" "$VAR_DIR" "$LOCAL_DIR"
    BACKGROUND_LOG="$LOGS_DIR/background.log"

    _header() {
      cat <<'BANNER'

     _   _           _               
    | | | | __ _ ___| |__   ___ _ __ 
    | |_| |/ _` / __| '_ \ / _ \ '__|
    |  _  | (_| \__ \ | | |  __/ |   
    |_| |_|\__,_|___/_| |_|\___|_|   

          NAS File Hasher & Dedupe

    BANNER
    }

    resolve_quarantine_dir() {
      local raw=""
      if [ -f "$LOCAL_DIR/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$LOCAL_DIR/hasher.conf" | tail -n1 || true)"
      fi
      if [ -z "$raw" ] && [ -f "$DEFAULT_DIR/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$DEFAULT_DIR/hasher.conf" | tail -n1 || true)"
      fi
      local val
      val="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^[\"\x27]//; s/[\"\x27]$//')"
      if [ -z "$val" ]; then
        val="$ROOT_DIR/quarantine-$(date +%F)"
      else
        val="${val//\$\((date +%F)\)/$(date +%F)}"
        val="${val//\$(date +%F)/$(date +%F)}"
      fi
      printf '%s\n' "$val"
    }

    show_quarantine_status() {
      local qdir; qdir="$(resolve_quarantine_dir)"
      mkdir -p -- "$qdir" 2>/dev/null || true
      local dfh free_bytes
      dfh="$(df -h "$qdir" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
      free_bytes="$(df -Pk "$qdir" | awk 'NR==2{print $4 * 1024}')"
      echo "[INFO] Quarantine: $qdir — $dfh"

      local plan_file=""
      plan_file="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -n "$plan_file" ] && [ -s "$plan_file" ]; then
        echo "[INFO] Detected latest folder plan: $plan_file"
      fi
    }

    latest_hashes_csv() {
      local f
      f="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
      [ -n "$f" ] && echo "$f" || echo ""
    }

    pause() { read -r -p "Press Enter to continue... " _ || true; }

    # Actions
    action_check_status() {
      echo "[INFO] Background log: $BACKGROUND_LOG"
      [ -f "$BACKGROUND_LOG" ] && tail -n 100 "$BACKGROUND_LOG" || echo "[INFO] No background.log yet."
      pause
    }

    action_start_hashing() {
      if [ -x "$ROOT_DIR/hasher.sh" ]; then
        echo "[INFO] Starting hasher with NAS-safe defaults (nohup)…"
        "$ROOT_DIR/hasher.sh" --nohup || true
      else
        echo "[ERROR] hasher.sh not found or not executable."
      fi
      pause
    }

    action_custom_hashing() {
      if [ -x "$ROOT_DIR/hasher.sh" ]; then
        "$ROOT_DIR/hasher.sh" || true
      else
        echo "[ERROR] hasher.sh not found or not executable."
      fi
      pause
    }

    action_find_duplicate_folders() {
      local input; input="$(latest_hashes_csv)"
      if [ -z "$input" ]; then
        echo "[ERROR] No hashes CSV found in $HASHES_DIR. Run hashing first."
        pause; return
      fi
      echo "[INFO] Using hashes file: $input"
      if [ -x "$BIN_DIR/find-duplicate-folders.sh" ]; then
        "$BIN_DIR/find-duplicate-folders.sh" --input "$input" --mode plan --min-group-size 2 --keep shortest-path --scope recursive || true
      else
        echo "[ERROR] $BIN_DIR/find-duplicate-folders.sh not found or not executable."
      fi
      pause
    }

    action_find_duplicate_files() {
      local input; input="$(latest_hashes_csv)"
      if [ -z "$input" ]; then
        echo "[ERROR] No hashes CSV found in $HASHES_DIR. Run hashing first."
        pause; return
      fi
      echo "[INFO] Using hashes file: $input"
      if [ -x "$BIN_DIR/find-duplicates.sh" ]; then
        "$BIN_DIR/find-duplicates.sh" --input "$input" || true
      else
        echo "[ERROR] $BIN_DIR/find-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_review_duplicates() {
      show_quarantine_status
      if [ -x "$BIN_DIR/review-duplicates.sh" ]; then
        "$BIN_DIR/review-duplicates.sh" || true
      else
        echo "[ERROR] $BIN_DIR/review-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_delete_zero_length() {
      if [ -x "$BIN_DIR/delete-zero-length.sh" ]; then
        "$BIN_DIR/delete-zero-length.sh" || true
      else
        echo "[ERROR] $BIN_DIR/delete-zero-length.sh not found or not executable."
      fi
      pause
    }

    action_apply_plan() {
      show_quarantine_status
      # Prefer folder plan if present
      local folder_plan=""
      folder_plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -n "$folder_plan" ]; then
        echo "[INFO] Found folder plan: $folder_plan"
        read -r -p "Apply folder plan now (move directories to quarantine)? [y/N]: " ans || ans=""
        case "${ans,,}" in
          y|yes)
            if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
              "$BIN_DIR/apply-folder-plan.sh" --plan "$folder_plan" --force || true
            else
              echo "[ERROR] $BIN_DIR/apply-folder-plan.sh not found or not executable."
            fi
            pause; return
            ;;
        esac
        echo "[INFO] Skipping folder plan. Checking for file plan…"
      fi
      if [ -x "$BIN_DIR/delete-duplicates.sh" ]; then
        "$BIN_DIR/delete-duplicates.sh" || true
      else
        echo "[ERROR] $BIN_DIR/delete-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_clean_caches() {
      local plan_file
      plan_file="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -z "$plan_file" ]; then
        echo "[INFO] No folder plan found. Run 'Find duplicate folders' first to scope the cleanup safely."
        pause; return
      fi
      if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
        "$BIN_DIR/apply-folder-plan.sh" --plan "$plan_file" --delete-metadata || true
      else
        echo "[ERROR] $BIN_DIR/apply-folder-plan.sh not found or not executable."
      fi
      pause
    }

    # Menu loop
    while :; do
      clear || true
      _header
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
      10) Clean cache files & @eaDir (safe)

    ### Other ###
      7) System check (deps & readiness)
      9) View logs (tail background.log)

      q) Quit

    MENU
      read -r -p "Choose an option: " choice || { echo; exit 0; }
      case "${choice:-}" in
        0) action_check_status ;;
        1) action_start_hashing ;;
        8) action_custom_hashing ;;
        2) action_find_duplicate_folders ;;
        3) action_find_duplicate_files ;;
        4) action_review_duplicates ;;
        5) action_delete_zero_length ;;
        6) action_apply_plan ;;
        10) action_clean_caches ;;
        7) action_system_check ;;
        9) action_view_logs ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) echo "Unknown option: $choice"; sleep 1 ;;
      esac
    done
