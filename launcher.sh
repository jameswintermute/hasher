\
    #!/usr/bin/env bash
    # launcher.sh — menu launcher for Hasher & Dedupe toolkit
    # - Safe ASCII banner (no backticks/heredocs)
    # - ANSI colors when TTY
    # - Robust hasher discovery
    # - Start hasher with nohup; pass explicit --paths-file/--exclude-from when available
    # - Preflight summary so user can see what will be scanned
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

    latest_hashes_csv() {
      local f
      f="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
      [ -n "$f" ] && echo "$f" || echo ""
    }

    # Quick sampler for rough scope (lower bound)
    sample_files_quick() {
      local paths="$1"
      [ -s "$paths" ] || { echo 0; return; }
      local total=0 line c
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|"") continue;; esac
        [ -d "$line" ] || continue
        c="$(find "$line" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')" || c=0
        total=$(( total + c ))
      done < "$paths"
      echo "$total"
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
      x="$(find "$ROOT_DIR" -maxdepth 2 -type f -name '*hasher*.sh' 2>/dev/null | head -n1 || true)"
      [ -n "$x" ] && { echo "$x"; return 0; }
      return 1
    }

    # --- Determine paths/excludes files ---
    determine_paths_file() {
      if   [ -s "$LOCAL_DIR/paths.txt" ]; then echo "$LOCAL_DIR/paths.txt"
      elif [ -s "$ROOT_DIR/paths.txt" ]; then echo "$ROOT_DIR/paths.txt"
      else echo ""; fi
    }
    determine_excludes_file() {
      if [ -s "$LOCAL_DIR/excludes.txt" ]; then echo "$LOCAL_DIR/excludes.txt"; else echo ""; fi
    }

    # --- Preflight summary ---
    preflight_hashing() {
      local pfile efile roots=0 exist=0 missing=0 line
      pfile="$(determine_paths_file)"
      efile="$(determine_excludes_file)"
      if [ -n "$pfile" ]; then
        info "Paths file: $pfile"
        # count roots and existing roots
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in \#*|"") continue;; esac
          roots=$((roots+1))
          [ -d "$line" ] && exist=$((exist+1)) || missing=$((missing+1))
        done < "$pfile"
        info "Roots listed: $roots (existing: $exist, missing: $missing)"
        # quick sample
        local lb; lb="$(sample_files_quick "$pfile")"
        info "Quick sample (depth≤2): at least ${lb} files to scan (lower-bound)."
      else
        warn "No paths file found (expected local/paths.txt or ./paths.txt). Hasher may discover 0 files."
      fi
      if [ -n "$efile" ]; then
        info "Excludes file: $efile"
      fi
    }

    # --- Start hasher (nohup) with explicit args when available ---
    run_hasher_nohup() {
      local script="$1"
      local pfile efile
      pfile="$(determine_paths_file)"
      efile="$(determine_excludes_file)"

      preflight_hashing

      : >"$BACKGROUND_LOG" 2>/dev/null || true

      # Build argv
      # We do not assume specific CLI, but pass commonly-supported flags when present.
      # If the script doesn't support them, it should ignore or print help; user can use option 8.
      declare -a argv
      argv+=("$script")
      [ -n "$pfile" ] && argv+=("--paths-file" "$pfile")
      [ -n "$efile" ] && argv+=("--exclude-from" "$efile")

      info "Starting hasher: ${argv[*]} (nohup to $BACKGROUND_LOG)"
      if [ -x "$script" ]; then
        nohup "${argv[@]}" >>"$BACKGROUND_LOG" 2>&1 &
      else
        nohup sh "${argv[@]}" >>"$BACKGROUND_LOG" 2>&1 &
      fi

      local pid=$!
      sleep 0.6
      if kill -0 "$pid" 2>/dev/null; then
        ok "Hasher launched (pid $pid)."
      else
        warn "Hasher may not be running. Recent log:"
        tail -n 40 "$BACKGROUND_LOG" 2>/dev/null || true
      fi

      # quick hints
      local csv lc files
      csv="$(latest_hashes_csv)"
      lc=0; files=0
      if [ -n "$csv" ] && [ -s "$csv" ]; then
        lc="$(wc -l < "$csv" | tr -d ' ')" || lc=0
        if [ "$lc" -gt 1 ]; then
          files=$(( lc - 1 ))
          info "Last run indexed approximately: ${files} files."
        fi
      fi

      sleep 0.8
      tail -n 20 "$BACKGROUND_LOG" 2>/dev/null | grep -q "Discovered 0 files to scan" && \
        warn "Hasher reported 0 files discovered. If this persists, try option 8 (Advanced) to run interactively."
      info "While it runs, use option 9 to watch logs. Path: $BACKGROUND_LOG"
    }

    run_hasher_interactive() {
      local script="$1"
      local pfile efile
      pfile="$(determine_paths_file)"
      efile="$(determine_excludes_file)"
      info "Running hasher interactively: $script"
      if [ -x "$script" ]; then
        [ -n "$pfile" ] && set -- "$script" --paths-file "$pfile" || set -- "$script"
        [ -n "$efile" ] && set -- "$@" --exclude-from "$efile"
        "$@"
      else
        [ -n "$pfile" ] && set -- sh "$script" --paths-file "$pfile" || set -- sh "$script"
        [ -n "$efile" ] && set -- "$@" --exclude-from "$efile"
        "$@"
      fi
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
      local plan_file
      plan_file="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -z "$plan_file" ]; then
        info "No folder plan found. Run 'Find duplicate folders' first."
        pause; return
      fi
      info "Found folder plan: $plan_file"
      read -r -p "Apply folder plan now (move directories to quarantine)? [y/N]: " ans || ans=""
      case "${ans,,}" in
        y|yes)
          if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
            "$BIN_DIR/apply-folder-plan.sh" --plan "$plan_file" --force || true
          else
            err "$BIN_DIR/apply-folder-plan.sh not found or not executable."
          fi
          pause; return
          ;;
      esac
      info "Skipping folder plan. Checking for file plan…"
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
      if [ -x "$BIN_DIR/delete-junk.sh" ]; then
        "$BIN_DIR/delete-junk.sh" || true
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
      # Show paths/excludes and quick sample
      pfile="$(determine_paths_file)"
      if [ -n "$pfile" ]; then
        echo "  - Paths file: $pfile"
        echo "    First roots:"
        sed -n '1,10p' "$pfile" | sed 's/^/      /'
        echo "    Lower-bound (depth≤2) file count: $(sample_files_quick "$pfile")"
      else
        echo "  - Paths file: (none found)"
      fi
      efile="$(determine_excludes_file)"
      if [ -n "$efile" ]; then
        echo "  - Excludes: $efile"
        sed -n '1,10p' "$efile" | sed 's/^/      /'
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
