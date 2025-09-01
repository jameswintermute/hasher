\
#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

APP_HOME="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOGS_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
ZERO_DIR="$APP_HOME/zero-length"
LOCAL_DIR="$APP_HOME/local"
DEFAULT_DIR="$APP_HOME/default"

mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$ZERO_DIR"

draw_banner(){
cat <<'EOF'
 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe
EOF
}

press_any(){ read -rp "Press Enter to continue..." _ || true; }

latest_csv(){ ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true; }
latest_report(){ ls -1t "$LOGS_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-duplicate-hashes.txt 2>/dev/null | head -n1 || true; }
latest_zero(){ ls -1t "$ZERO_DIR"/zero-length-*.txt 2>/dev/null | head -n1 || true; }

# ───── Option 0: status (friendly ETA-to-clocktime) ─────
status(){
  echo "— Latest progress —"
  tail -n 10 "$LOGS_DIR/background.log" 2>/dev/null || echo "(no background.log yet)"
  local csv; csv="$(latest_csv)"
  if [ -n "$csv" ]; then
    echo; echo "Latest CSV: $csv"
    local rows; rows="$(wc -l < "$csv" | tr -d ' ')"
    echo "Row count (including header): $rows"
  fi

  # Try to parse the last PROGRESS line for ETA hh:mm:ss, convert to clock time
  local last; last="$(tac "$LOGS_DIR/background.log" 2>/dev/null | grep -m1 '\[PROGRESS\]' || true)"
  if [ -n "$last" ]; then
    eta_hms="$(echo "$last" | sed -n 's/.* eta=\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\).*/\1/p')"
    pct="$(echo "$last" | sed -n 's/.* Hashing: \[\([0-9]\+\)%\].*/\1/p')"
    if [ -n "$eta_hms" ]; then
      IFS=: read -r eh em es <<< "$eta_hms"
      secs=$((10#$eh*3600 + 10#$em*60 + 10#$es))
      end_epoch=$(( $(date +%s) + secs ))
      end_local="$(date -d "@$end_epoch" "+%H:%M:%S %Z")"
      echo; echo "Summary: ${pct:-?}% complete • ETA in ~${eh}h ${em}m ${es}s (≈ ${end_local})"
    fi
  fi

  # Activity heuristic
  local last_ts; last_ts="$(tail -n 1 "$LOGS_DIR/background.log" 2>/dev/null | sed -n 's/^\[\(....-..-.. ..:..:..\)\].*/\1/p')"
  if [ -n "$last_ts" ]; then
    echo; echo "[STATUS] $(tail -n 1 "$LOGS_DIR/background.log")"
  fi
  press_any
}

# ───── Option 1: start hashing (safe defaults) ─────
start_hashing(){
  echo "Starting Hasher now using defaults..."
  echo "Command:"
  echo "  bin/hasher.sh --pathfile $LOCAL_DIR/paths.txt --algo sha256 --nohup"
  ( cd "$APP_HOME" && "$BIN_DIR/hasher.sh" --pathfile "$LOCAL_DIR/paths.txt" --algo sha256 --nohup )
  echo; echo "Tail logs with:"
  echo "  tail -f \"$LOGS_DIR/background.log\" \"$LOGS_DIR/hasher.log\""
  press_any
}

# ───── Option 2: find duplicates (summary) ─────
find_dupes(){
  echo "Finding duplicate groups from latest CSV..."
  ( cd "$APP_HOME" && "$BIN_DIR/find-duplicates.sh" )
  press_any
}

# ───── Option 3: review duplicates (interactive) ─────
review_dupes(){
  local rep; rep="$(latest_report)"
  if [ -z "$rep" ]; then
    echo "[INFO] No duplicate report found; generating one..."
    ( cd "$APP_HOME" && "$BIN_DIR/find-duplicates.sh" )
    rep="$(latest_report)"
    [ -z "$rep" ] && { echo "[ERROR] Still no report found."; press_any; return; }
  fi
  echo "[INFO] Using latest report: $rep"
  # Force interactive TTY read for child
  ( cd "$APP_HOME" && "$BIN_DIR/review-duplicates.sh" --from-report "$rep" ) < /dev/tty
  press_any
}

# ───── Option 4: delete zero-length files ─────
delete_zero_len(){
  local z; z="$(latest_zero)"
  if [ -z "$z" ]; then
    echo "[INFO] No zero-length list found. You can run: bin/hasher.sh --pathfile local/paths.txt --algo sha256 --zero-length-only"
    press_any; return
  fi
  echo "Zero-length list: $z"
  echo "Choose mode: [v]erify-only (default), [d]ry-run, [f]orce, [q]uarantine"
  read -r -p "> " mode || mode=""
  case "${mode,,}" in
    d|dry|dry-run)      ( cd "$APP_HOME" && "$BIN_DIR/delete-zero-length.sh" "$z" ) ;;
    f|force)            ( cd "$APP_HOME" && "$BIN_DIR/delete-zero-length.sh" "$z" --force ) ;;
    q|quarantine)       ( cd "$APP_HOME" && "$BIN_DIR/delete-zero-length.sh" "$z" --force --quarantine "$ZERO_DIR/quarantine-$(date +%F)" ) ;;
    *|v|verify|verify-only) ( cd "$APP_HOME" && "$BIN_DIR/delete-zero-length.sh" "$z" --verify-only ) ;;
  esac
  press_any
}

# ───── Option 5: delete junk files (Thumbs.db, .DS_Store, @eaDir…) ─────
delete_junk(){
  echo "Junk cleaner — choose mode: [v]erify-only (default), [d]ry-run, [f]orce, [q]uarantine"
  read -r -p "> " mode || mode=""
  case "${mode,,}" in
    d|dry|dry-run)      ( cd "$APP_HOME" && "$BIN_DIR/delete-junk.sh" --dry-run ) ;;
    f|force)            ( cd "$APP_HOME" && "$BIN_DIR/delete-junk.sh" --force ) ;;
    q|quarantine)       ( cd "$APP_HOME" && "$BIN_DIR/delete-junk.sh" --quarantine "$APP_HOME/var/junk/quarantine-$(date +%F)" ) ;;
    *|v|verify|verify-only) ( cd "$APP_HOME" && "$BIN_DIR/delete-junk.sh" --verify-only ) ;;
  esac
  press_any
}

# ───── Option 6: write a starter paths file ─────
populate_paths(){
  local f="$LOCAL_DIR/paths.txt"
  if [ -s "$f" ]; then
    echo "[INFO] $f already exists:"
    nl -ba "$f" | head -n 20
  else
    mkdir -p "$LOCAL_DIR"
    cat > "$f" <<EOF
/volume1/Family
/volume1/James
/volume1/Media
EOF
    echo "[INFO] Wrote starter $f"
  fi
  press_any
}

# ───── Option 7: edit conf (local overlays default) ─────
edit_conf(){
  local lf="$LOCAL_DIR/hasher.conf"
  local df="$DEFAULT_DIR/hasher.conf"
  [ -r "$df" ] && echo "[INFO] Default conf: $df"
  if [ ! -r "$lf" ]; then
    mkdir -p "$LOCAL_DIR"
    cp -n "$df" "$lf" 2>/dev/null || true
    echo "[INFO] Created local conf: $lf"
  fi
  ${EDITOR:-vi} "$lf" || true
}

main_menu(){
  while :; do
    clear || true
    draw_banner
    cat <<EOF

### Stage 1 - Hash ###
  0) Check hashing status
  1) Start Hashing (NAS-safe defaults)
  8) Advanced / Custom hashing

### Stage 2 - Identify ###
  2) Find duplicate hashes
  3) Review duplicate hashes (latest report)

### Stage 3 - Cleanup ###
  4) Delete Zero-Length files
  5) Delete Junk files (Thumbs.db, .DS_Store, @eaDir…)

### Other ###
  6) Populate the paths file (local/paths.txt)
  7) Edit config (local/hasher.conf; overlays default/hasher.conf)

  q) Quit
EOF
    read -r -p "Select an option: " opt || opt=""
    case "$opt" in
      0) status ;;
      1) start_hashing ;;
      2) find_dupes ;;
      3) review_dupes ;;
      4) delete_zero_len ;;
      5) delete_junk ;;
      6) populate_paths ;;
      7) edit_conf ;;
      8) echo "[INFO] Try: bin/hasher.sh --help"; press_any ;;
      q|Q) exit 0 ;;
      *) echo "Unknown option"; press_any ;;
    esac
  done
}

main_menu
