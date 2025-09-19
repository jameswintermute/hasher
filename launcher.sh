\
    #!/usr/bin/env bash
    # launcher.sh — menu launcher for Hasher & Dedupe toolkit
    # - Backtick-free ASCII banner
    # - ANSI colors when TTY (no deps)
    # - Robust hasher discovery
    # - After starting hasher: brief guidance + last-run file count + tip to view logs
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

    # ── Colors ────────────────────────────────────────────────────────────
    init_colors() {
      if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        CHEAD="\033[1;35m"; CINFO="\033[1;34m"; COK="\033[1;32m"; CWARN="\033[1;33m"; CERR="\033[1;31m"; CRESET="\033[0m"
      else
        CHEAD=""; CINFO=""; COK=""; CWARN=""; CERR=""; CRESET=""
      fi
    }
    info(){ printf "%b[INFO]%b %s\n" "$CINFO" "$CRESET" "$*"; }
    ok(){   printf "%b[OK]%b %s\n"   "$COK"   "$CRESET" "$*"; }
    warn(){ printf "%b[WARN]%b %s\n" "$CWARN" "$CRESET" "$*"; }
    err(){  printf "%b[ERROR]%b %s\n" "$CERR" "$CRESET" "$*"; }
    init_colors

    _header() {
      printf "%b" "$CHEAD"
      printf "%s\n" " _   _           _               "
      printf "%s\n" "| | | | __ _ ___| |__   ___ _ __ "
      printf "%s\n" "| |_| |/ _' / __| '_ \\ / _ \\ '__|"
      printf "%s\n" "|  _  | (_| \\__ \\ | | |  __/ |   "
      printf "%s\n" "|_| |_|\\__,_|___/_| |_|\\___|_|   "
      printf "%s\n" ""
      printf "%s\n" "      NAS File Hasher & Dedupe"
      printf "%b" "$CRESET"
      printf "%s\n" ""
    }

    print_menu() {
      printf "%s\n" "### Stage 1 - Hash ###"
      printf "%s\n" "  0) Check hashing status"
      printf "%s\n" "  1) Start Hashing (NAS-safe defaults)"
      printf "%s\n" "  8) Advanced / Custom hashing"
      printf "%s\n" ""
      printf "%s\n" "### Stage 2 - Identify ###"
      printf "%s\n" "  2) Find duplicate folders"
      printf "%s\n" "  3) Find duplicate files"
      printf "%s\n" ""
      printf "%s\n" "### Stage 3 - Clean up ###"
      printf "%s\n" "  4) Review duplicates (interactive)"
      printf "%s\n" "  5) Delete zero-length files"
      printf "%s\n" "  6) Delete duplicates (apply plan)"
      printf "%s\n" "  10) Clean cache files & @eaDir (safe)"
      printf "%s\n" "  11) Delete junk (Thumbs.db, .DS_Store, @eaDir, etc.)"
      printf "%s\n" ""
      printf "%s\n" "### Other ###"
      printf "%s\n" "  7) System check (deps & readiness)"
      printf "%s\n" "  9) View logs (tail background.log)"
      printf "%s\n" ""
      printf "%s\n" "  q) Quit"
      printf "%s\n" ""
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
      val="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^[\"\\x27]//; s/[\"\\x27]$//')"
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
      local dfh
      dfh="$(df -h "$qdir" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
      info "Quarantine: $qdir — $dfh"
      local plan_file=""
      plan_file="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -n "$plan_file" ] && [ -s "$plan_file" ]; then
        info "Detected latest folder plan: $plan_file"
      fi
    }

    latest_hashes_csv() {
      local f
      f="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
      [ -n "$f" ] && echo "$f" || echo ""
    }

    pause() { read -r -p "Press Enter to continue... " _ || true; }

    # --- Robust hasher discovery ---
    find_hasher_script() {
      local candidates=(
        "$ROOT_DIR/hasher.sh"
        "$BIN_DIR/hasher.sh"
        "$ROOT_DIR/scripts/hasher.sh"
        "$ROOT_DIR/tools/hasher.sh"
      )
      local x
      for x in "${candidates[@]}"; do
        [ -f "$x" ] && { echo "$x"; return 0; }
      done
      # Fallback: any script matching *hasher*.sh under repo (depth 2)
      x="$(find "$ROOT_DIR" -maxdepth 2 -type f -name '*hasher*.sh' 2>/dev/null | head -n1 || true)"
      [ -n "$x" ] && { echo "$x"; return 0; }
      return 1
    }

    run_hasher_nohup() {
      local script="$1"
      local runner=""
      if [ -x "$script" ]; then
        runner="$script"
      else
        runner="sh \"$script\""
      fi
      info "Starting hasher: $script (nohup to $BACKGROUND_LOG)"
      nohup sh -c "$runner --nohup" >>"$BACKGROUND_LOG" 2>&1 &
      ok "Hasher launched."
      # Post-launch guidance
      local csv; csv="$(latest_hashes_csv)"
      if [ -n "$csv" ] && [ -s "$csv" ]; then
        # Lines - 1 header; wc handles big files quickly
        local lc; lc="$(wc -l < "$csv" | tr -d ' ')" || lc=0
        local files=$(( lc>0 ? lc-1 : 0 ))
        info "Last run indexed approximately: ${files} files."
      else
        info "No previous CSV detected; first full run can take a while depending on disk & CPU."
      fi
      info "While it runs, use option 9 to watch logs. Path: $BACKGROUND_LOG"
    }

    run_hasher_interactive() {
      local script="$1"
      local runner=""
      if [ -x "$script" ]; then
        runner="$script"
      else
        runner="sh \"$script\""
      fi
      info "Running hasher interactively: $script"
      eval "$runner"
    }

    # Actions
    action_check_status() {
      info "Background log: $BACKGROUND_LOG"
      [ -f "$BACKGROUND_LOG" ] && tail -n 100 "$BACKGROUND_LOG" || info "No background.log yet."
      pause
    }

    action_start_hashing() {
      local hs
      if hs="$(find_hasher_script)"; then
        run_hasher_nohup "$hs" || true
      else
        err "hasher.sh not found. Expected at one of:
          - $ROOT_DIR/hasher.sh
          - $BIN_DIR/hasher.sh
          - $ROOT_DIR/scripts/hasher.sh
          - $ROOT_DIR/tools/hasher.sh
          - or any *hasher*.sh within repo root"
      fi
      pause
    }

    action_custom_hashing() {
      local hs
      if hs="$(find_hasher_script)"; then
        run_hasher_interactive "$hs" || true
      else
        err "hasher.sh not found. See option 1 notes."
      fi
      pause
    }

    action_find_duplicate_folders() {
      local input; input="$(latest_hashes_csv)"
      if [ -z "$input" ]; then
        err "No hashes CSV found in $HASHES_DIR. Run hashing first."
        pause; return
      fi
      info "Using hashes file: $input"
      if [ -x "$BIN_DIR/find-duplicate-folders.sh" ]; then
        "$BIN_DIR/find-duplicate-folders.sh" --input "$input" --mode plan --min-group-size 2 --keep shortest-path --scope recursive || true
      else
        err "$BIN_DIR/find-duplicate-folders.sh not found or not executable."
      fi
      pause
    }

    action_find_duplicate_files() {
      local input; input="$(latest_hashes_csv)"
      if [ -z "$input" ]; then
        err "No hashes CSV found in $HASHES_DIR. Run hashing first."
        pause; return
      fi
      info "Using hashes file: $input"
      if [ -x "$BIN_DIR/find-duplicates.sh" ]; then
        "$BIN_DIR/find-duplicates.sh" --input "$input" || true
      else
        err "$BIN_DIR/find-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_review_duplicates() {
      show_quarantine_status
      if [ -x "$BIN_DIR/review-duplicates.sh" ]; then
        "$BIN_DIR/review-duplicates.sh" || true
      else
        err "$BIN_DIR/review-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_delete_zero_length() {
      if [ -x "$BIN_DIR/delete-zero-length.sh" ]; then
        "$BIN_DIR/delete-zero-length.sh" || true
      else
        err "$BIN_DIR/delete-zero-length.sh not found or not executable."
      fi
      pause
    }

    action_apply_plan() {
      show_quarantine_status
      local folder_plan=""
      folder_plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -n "$folder_plan" ]; then
        info "Found folder plan: $folder_plan"
        read -r -p "Apply folder plan now (move directories to quarantine)? [y/N]: " ans || ans=""
        case "${ans,,}" in
          y|yes)
            if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
              "$BIN_DIR/apply-folder-plan.sh" --plan "$folder_plan" --force || true
            else
              err "$BIN_DIR/apply-folder-plan.sh not found or not executable."
            fi
            pause; return
            ;;
        esac
        info "Skipping folder plan. Checking for file plan…"
      fi
      if [ -x "$BIN_DIR/delete-duplicates.sh" ]; then
        "$BIN_DIR/delete-duplicates.sh" || true
      else
        err "$BIN_DIR/delete-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_clean_caches() {
      local plan_file
      plan_file="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -z "$plan_file" ]; then
        info "No folder plan found. Run 'Find duplicate folders' first to scope the cleanup safely."
        pause; return
      fi
      if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
        "$BIN_DIR/apply-folder-plan.sh" --plan "$plan_file" --delete-metadata || true
      else
        err "$BIN_DIR/apply-folder-plan.sh not found or not executable."
      fi
      pause
    }

    action_delete_junk() {
      local paths=""
      if   [ -f "$LOCAL_DIR/paths.txt" ]; then paths="$LOCAL_DIR/paths.txt"
      elif [ -f "$ROOT_DIR/paths.txt" ]; then paths="$ROOT_DIR/paths.txt"
      elif [ -f "$DEFAULT_DIR/paths.example.txt" ]; then paths="$DEFAULT_DIR/paths.example.txt"
      fi
      if [ -z "$paths" ]; then
        err "No paths file found (local/paths.txt or ./paths.txt). Create one to use 'Delete junk'."
        pause; return
      fi

      info "Using paths file: $paths"
      read -r -p "Include recycle bins (#recycle)? [y/N]: " inc || inc=""
      read -r -p "Mode: verify only (v), quarantine (q), force delete (f) [v/q/f]: " mode || mode="v"

      # Build args list safely
      args=(--paths-file "$paths")
      case "${inc,,}" in y|yes) args+=(--include-recycle);; esac
      case "${mode,,}" in
        q|quarantine)
          qdir="$(resolve_quarantine_dir)"; ts="$(date +%F-%H%M%S)"; dest="$qdir/junk-$ts"
          args+=(--quarantine "$dest")
          ;;
        f|force) args+=(--force);;
        *)       args+=(--verify-only);;
      esac

      if [ -x "$BIN_DIR/delete-junk.sh" ]; then
        "$BIN_DIR/delete-junk.sh" "${args[@]}" || true
      else
        err "$BIN_DIR/delete-junk.sh not found or not executable."
      fi
      pause
    }

    action_system_check() {
      info "System check:"
      command -v awk  >/dev/null && echo "  - awk: OK"  || echo "  - awk: MISSING"
      command -v sort >/dev/null && echo "  - sort: OK" || echo "  - sort: MISSING"
      command -v cksum>/dev/null && echo "  - cksum: OK"|| echo "  - cksum: MISSING"
      command -v stat >/dev/null && echo "  - stat: OK" || echo "  - stat: MISSING"
      command -v df   >/dev/null && echo "  - df:   OK"  || echo "  - df:   MISSING"
      echo "  - Logs dir:    $LOGS_DIR"
      echo "  - Hashes dir:  $HASHES_DIR"
      echo "  - Bin dir:     $BIN_DIR"
      echo "  - Latest CSV:  $(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || echo none)"
      echo
      show_quarantine_status
      pause
    }

    action_view_logs() {
      if [ -f "$BACKGROUND_LOG" ]; then
        tail -n 200 "$BACKGROUND_LOG"
      else
        info "No background.log yet."
      fi
      pause
    }

    # Menu loop
    while :; do
      clear || true
      _header
      print_menu
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
        11) action_delete_junk ;;
        7) action_system_check ;;
        9) action_view_logs ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) echo "Unknown option: $choice"; sleep 1 ;;
      esac
    done
