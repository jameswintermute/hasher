\
    #!/usr/bin/env bash
    # launcher.sh — menu launcher for Hasher & Dedupe toolkit
    # Minimal update: add quarantine free-space heads-up using QUARANTINE_DIR from hasher.conf
    # Safe defaults, Synology-friendly.
    #
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
    DEFAULT_DIR="$ROOT_DIR/default"

    mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$BIN_DIR" "$VAR_DIR" "$LOCAL_DIR"
    BACKGROUND_LOG="$LOGS_DIR/background.log"

    # ────────────────────────────── Helpers ──────────────────────────────
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

    # Extract QUARANTINE_DIR from config (local overrides default).
    # Supports a literal value or the pattern $(date +%F) in the path.
    resolve_quarantine_dir() {
      local raw=""
      if [ -f "$LOCAL_DIR/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$LOCAL_DIR/hasher.conf" | tail -n1 || true)"
      fi
      if [ -z "$raw" ] && [ -f "$DEFAULT_DIR/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$DEFAULT_DIR/hasher.conf" | tail -n1 || true)"
      fi
      # Parse value
      local val
      val="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^[\"\x27]//; s/[\"\x27]$//')"
      if [ -z "$val" ]; then
        # fallback default on same volume as ROOT_DIR
        val="$ROOT_DIR/quarantine-$(date +%F)"
      else
        # Only expand the specific pattern $(date +%F) to avoid arbitrary evaluation
        val="${val//\$\(date +%F\)/$(date +%F)}"
      fi
      printf '%s\n' "$val"
    }

    # Show free space for the quarantine target. Warn if cross-filesystem and insufficient.
    show_quarantine_status() {
      local qdir; qdir="$(resolve_quarantine_dir)"
      mkdir -p -- "$qdir" 2>/dev/null || true

      local dfh dfp free_bytes
      dfh="$(df -h "$qdir" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
      free_bytes="$(df -Pk "$qdir" | awk 'NR==2{print $4 * 1024}')"
      echo "[INFO] Quarantine: $qdir — $dfh"

      # If we can detect a plan file for files or directories, estimate size (optional best-effort)
      local plan_size_bytes=0 plan_file=""
      # Prefer latest duplicate-folders plan
      plan_file="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
      if [ -z "$plan_file" ]; then
        # Fallback: any generic review plan file produced by review-duplicates
        plan_file="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
      fi
      if [ -n "$plan_file" ] && [ -s "$plan_file" ]; then
        echo "[INFO] Detected latest plan: $plan_file"
        # If plan lists directories, sum using CSV; if it lists files, stat (best-effort).
        # We try to use size_bytes from the latest hashes CSV for speed.
        local latest_csv=""; latest_csv="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
        if [ -n "$latest_csv" ]; then
          # Build a path→size map in awk and sum
          plan_size_bytes="$(awk -v plan="$plan_file" -v csv="$latest_csv" '
            BEGIN{FS=","}
            NR==FNR{ next } # placeholder
            ' /dev/null )"
          # The above placeholder avoids macOS awk weirdness; do real work below with tabs
          plan_size_bytes="$(awk -v PF="$plan_file" -v CSV="$latest_csv" '
            BEGIN{
              FS=","; OFS="\t"
              # Preload CSV size map path->size
              while ((getline < CSV) > 0) {
                if (NR==1) {
                  # header: find indexes
                  for (i=1;i<=NF;i++) {
                    h=tolower($i); gsub(/^[ \t"]+|[ \t"]+$/,"",h)
                    if (h=="path") p=i
                    if (h=="size_bytes") s=i
                  }
                  if (!p || !s) { close(CSV); break }
                  continue
                }
                path=$p
                gsub(/^"|"$/,"",path)
                size=$s+0
                sz[path]=size
              }
              close(CSV)
              total=0
              while ((getline line < PF) > 0) {
                gsub(/\r$/,"", line)
                if (line=="") continue
                if (line in sz) total+=sz[line]
                else {
                  # if plan holds directories, we cannot sum without walking; skip
                }
              }
              print total
            }' )"
        fi
        if [ -z "${plan_size_bytes:-}" ] || ! [[ "$plan_size_bytes" =~ ^[0-9]+$ ]]; then
          plan_size_bytes=0
        fi
        if [ "$plan_size_bytes" -gt 0 ]; then
          awk -v b="$plan_size_bytes" 'BEGIN{
            gb=b/1024/1024/1024; mb=b/1024/1024;
            if (gb>=1) printf("[INFO] Estimated plan size (files matched in CSV): %.2f GB\n", gb);
            else printf("[INFO] Estimated plan size (files matched in CSV): %.2f MB\n", mb);
          }'
        fi
        # Cross-filesystem warning only if we know at least one source path
        local first_src=""; first_src="$(head -n1 "$plan_file" || true)"
        if [ -n "$first_src" ]; then
          local src_fs q_fs
          src_fs="$(df -Pk "$first_src" | awk 'NR==2{print $1}')"
          q_fs="$(df -Pk "$qdir" | awk 'NR==2{print $1}')"
          if [ "$src_fs" != "$q_fs" ] && [ "${plan_size_bytes:-0}" -gt "${free_bytes:-0}" ]; then
            echo "[WARN] Plan may exceed free space on quarantine filesystem for a cross-filesystem move."
            echo "       Consider setting QUARANTINE_DIR on the same filesystem as sources, or reduce the plan."
          fi
        fi
      fi
    }

    latest_hashes_csv() {
      local f
      f="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
      if [ -z "$f" ]; then
        echo ""
      else
        echo "$f"
      fi
    }

    pause() { read -r -p "Press Enter to continue... " _ || true; }

    # ────────────────────────────── Menu Actions ──────────────────────────
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
      end_if:
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
      if [ -x "$BIN_DIR/delete-duplicates.sh" ]; then
        "$BIN_DIR/delete-duplicates.sh" || true
      else
        echo "[ERROR] $BIN_DIR/delete-duplicates.sh not found or not executable."
      fi
      pause
    }

    action_system_check() {
      echo "[INFO] System check:"
      command -v awk >/dev/null && echo "  - awk: OK" || echo "  - awk: MISSING"
      command -v sort >/dev/null && echo "  - sort: OK" || echo "  - sort: MISSING"
      command -v cksum >/dev/null && echo "  - cksum: OK" || echo "  - cksum: MISSING"
      command -v stat >/dev/null && echo "  - stat: OK" || echo "  - stat: MISSING"
      command -v df   >/dev/null && echo "  - df:   OK" || echo "  - df:   MISSING"
      echo "  - Logs dir:    $LOGS_DIR"
      echo "  - Hashes dir:  $HASHES_DIR"
      echo "  - Bin dir:     $BIN_DIR"
      echo "  - Latest CSV:  $(latest_hashes_csv || echo 'none')"
      echo
      show_quarantine_status
      pause
    }

    action_view_logs() {
      if [ -f "$BACKGROUND_LOG" ]; then
        tail -n 200 "$BACKGROUND_LOG"
      else
        echo "[INFO] No background.log yet."
      fi
      pause
    }

    # ────────────────────────────── Menu Loop ─────────────────────────────
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
        7) action_system_check ;;
        9) action_view_logs ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) echo "Unknown option: $choice"; sleep 1 ;;
      esac
    done
