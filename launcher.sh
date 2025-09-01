\
#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ───────────────────────── Layout discovery ─────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$SCRIPT_DIR"
BIN_DIR="$APP_HOME/bin"
LOG_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
VAR_DIR="$APP_HOME/var"
ZERO_DIR="$VAR_DIR/zero-length"
LOW_DIR="$VAR_DIR/low-value"
QUAR_DIR="$VAR_DIR/quarantine"

# Ensure dirs
mkdir -p "$LOG_DIR" "$HASHES_DIR" "$ZERO_DIR" "$LOW_DIR" "$QUAR_DIR"

# Load helper paths if present
if [ -r "$BIN_DIR/lib_paths.sh" ]; then
  . "$BIN_DIR/lib_paths.sh" 2>/dev/null || true
  # lib may override vars; ensure fallbacks exist
  APP_HOME="${APP_HOME:-$SCRIPT_DIR}"
  BIN_DIR="${BIN_DIR:-$APP_HOME/bin}"
  LOG_DIR="${LOG_DIR:-$APP_HOME/logs}"
  HASHES_DIR="${HASHES_DIR:-$APP_HOME/hashes}"
  VAR_DIR="${VAR_DIR:-$APP_HOME/var}"
  ZERO_DIR="${ZERO_DIR:-$VAR_DIR/zero-length}"
  LOW_DIR="${LOW_DIR:-$VAR_DIR/low-value}"
  QUAR_DIR="${QUAR_DIR:-$VAR_DIR/quarantine}"
fi

PATHFILE_DEFAULT="$APP_HOME/local/paths.txt"
CONF_DEFAULT_LOCAL="$APP_HOME/local/hasher.conf"
CONF_DEFAULT_DIST="$APP_HOME/default/hasher.conf"

# ───────────────────────── Helpers ─────────────────────────
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
say(){ printf "[%s] %s\n" "$(ts)" "$*"; }
pause(){ read -rp "Press Enter to continue..." _; }

pick_latest(){
  # $1 = glob pattern (unquoted to allow expansion)
  ls -1t $1 2>/dev/null | head -n1 || true
}

open_in_editor(){
  # $1 = file
  local f="$1"
  local ed="${EDITOR:-}"
  if [ -z "$ed" ]; then
    if command -v nano >/dev/null 2>&1; then ed="nano"
    elif command -v vi >/dev/null 2>&1; then ed="vi"
    elif command -v vim >/dev/null 2>&1; then ed="vim"
    else ed=""; fi
  fi
  if [ -n "$ed" ]; then "$ed" "$f" || true
  else
    say "No terminal editor found (looked for $EDITOR, nano, vi, vim). Please edit: $f"
  fi
}

print_cmd(){
  local out=""
  for arg in "$@"; do
    printf -v q '%q' "$arg"
    out+="$q "
  done
  echo "${out%% }"
}

ascii(){
cat <<'BANNER'
 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe
BANNER
}

menu(){
  clear
  ascii
  cat <<'MENU'

### Stage 1 - Hash ###
  0) Check hashing status
  1) Start Hashing (NAS-safe defaults)
  8) Advanced / Custom hashing

### Stage 2 - Identify ###
  2) Find duplicate hashes
  3) Review duplicate hashes (latest report)

### Stage 3 - Cleanup ###
  4) Delete Zero-Length files
  5) Delete Low-Value files (tiny files diverted from review)

### Other ###
  6) Populate the paths file (local/paths.txt)
  7) Edit config (local/hasher.conf; overlays default/hasher.conf)

  q) Quit
MENU
  echo -n "Select an option: "
}

# ───────────────────────── Status helpers ──────────────────
# Return 0 if hashing appears active (recent PROGRESS within 10 minutes), else 1.
is_hashing_active(){
  local bg="$LOG_DIR/background.log"
  [ -s "$bg" ] || return 1
  local line ts_str pct
  # last progress line
  line="$(awk '/\\[PROGRESS\\]/{l=$0} END{print l}' "$bg" 2>/dev/null)"
  [ -n "$line" ] || return 1

  # extract timestamp inside first [..]
  ts_str="$(printf '%s\n' "$line" | sed -n 's/^\\[\\([^]]\\+\\)\\].*/\\1/p')"
  # Try to compute age; if unavailable, assume active
  if date -d "$ts_str" +%s >/dev/null 2>&1; then
    local ts now age
    ts="$(date -d "$ts_str" +%s)"
    now="$(date +%s)"
    age=$(( now - ts ))
    if [ "$age" -gt $((10*60)) ]; then
      return 1
    fi
  fi

  # if progress shows 100%, treat as not active
  pct="$(printf '%s\n' "$line" | sed -n 's/.*Hashing: \\[\\([0-9]\\+\\)%\\].*/\\1/p')"
  if [ -n "$pct" ] && [ "$pct" -ge 100 ]; then
    return 1
  fi
  return 0
}

# Return 0 if GNU date supports -d "@EPOCH"
gnu_date_epoch_ok(){
  date -d "@0" +%s >/dev/null 2>&1
}

show_hash_status(){
  local bg="$LOG_DIR/background.log"
  if [ ! -s "$bg" ]; then
    say "No background hashing log found at $bg"
    echo "Start hashing with option 1, then re-check status."
    pause; return
  fi

  # Extract most recent progress line and derive friendly ETA
  local line ts_str pct eta_str eta_h eta_m eta_s friendly_eta
  line="$(awk '/\\[PROGRESS\\]/{l=$0} END{print l}' "$bg" 2>/dev/null)"
  ts_str="$(printf '%s\n' "$line" | sed -n 's/^\\[\\([^]]\\+\\)\\].*/\\1/p')"
  pct="$(printf '%s\n' "$line" | sed -n 's/.*\\[\\([0-9]\\+\\)%\\].*/\\1/p')"

  # Robust ETA extraction: first try awk split on 'eta=' token, then sed fallback
  eta_str="$(printf '%s\n' "$line" | awk -F'eta=' '{print $2}' | awk '{print $1}' )"
  if [[ ! "$eta_str" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    eta_str="$(printf '%s\n' "$line" | sed -n 's/.*eta=\\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\).*/\\1/p')"
  fi

  if [ -n "$eta_str" ]; then
    IFS=':' read -r eta_h eta_m eta_s <<EOF
$eta_str
EOF
    # Strip leading zeros for readability
    [ "${eta_h#0}" = "" ] && eta_h="0" || eta_h="${eta_h#0}"
    [ "${eta_m#0}" = "" ] && eta_m="0" || eta_m="${eta_m#0}"
    [ "${eta_s#0}" = "" ] && eta_s="0" || eta_s="${eta_s#0}"
    friendly_eta="~${eta_h}h ${eta_m}m"

    # Optional absolute time if GNU date is available
    if gnu_date_epoch_ok; then
      local now epoch abs_day abs_time label today tomorrow add
      epoch="$(date +%s)"
      now="$epoch"
      add=$((10#$eta_h*3600 + 10#$eta_m*60 + 10#$eta_s))
      abs_day="$(date -d "@$((now + add))" +%F)"
      abs_time="$(date -d "@$((now + add))" +%T)"
      today="$(date +%F)"
      tomorrow="$(date -d "@$((now + 86400))" +%F)"
      if [ "$abs_day" = "$today" ]; then label="today"
      elif [ "$abs_day" = "$tomorrow" ]; then label="tomorrow"
      else label="$abs_day"; fi
      friendly_eta="$friendly_eta (around $abs_time $label)"
    fi
  else
    friendly_eta="(ETA unavailable)"
  fi

  echo "— Latest progress —"
  awk '/\\[PROGRESS\\]/{print}' "$bg" | tail -n 10

  if [ -n "$pct" ]; then
    echo
    echo "Summary: ${pct}% complete • ETA ${friendly_eta}"
  fi

  # Determine latest RUN ID seen in background.log
  local last_run_id run_log
  last_run_id="$(awk '/\\[RUN /{rid=$3} END{print rid}' "$bg" | sed 's/\\[RUN //;s/\\]//')"

  # If a Completed line exists for the last run, show it prominently
  local completed_line completed_ts completed_csv completed_elapsed completed_fail completed_counts
  if [ -n "$last_run_id" ]; then
    completed_line="$(grep -F \"[RUN $last_run_id]\" \"$bg\" | grep -F \"] [INFO] Completed.\" | tail -n 1 || true)"
    if [ -n \"$completed_line\" ]; then
      completed_ts=\"$(printf '%s\n' \"$completed_line\" | sed -n 's/^\\[\\([^]]\\+\\)\\].*/\\1/p')\"
      completed_csv=\"$(printf '%s\n' \"$completed_line\" | sed -n 's/.* CSV: \\([^ ]\\+\\).*/\\1/p')\"
      completed_elapsed=\"$(printf '%s\n' \"$completed_line\" | sed -n 's/.* in \\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)\\. .*/\\1/p')\"
      completed_counts=\"$(printf '%s\n' \"$completed_line\" | sed -n 's/.* Hashed \\([0-9]\\+\\/[^ ]\\+\\) files.*/\\1/p')\"

      echo
      echo \"*** COMPLETED ***\"
      [ -n \"$completed_ts\" ] && echo \"Finished at: $completed_ts\"
      [ -n \"$completed_counts\" ] && echo \"Files hashed: $completed_counts\"
      [ -n \"$completed_elapsed\" ] && echo \"Duration: $completed_elapsed\"
      if [ -n \"$completed_csv\" ]; then
        # If path is relative, show absolute
        case \"$completed_csv\" in
          /*) echo \"CSV: $completed_csv\" ;;
          *)  echo \"CSV: $APP_HOME/$completed_csv\" ;;
        esac
      fi
    fi
  fi

  # Show latest CSV (still useful if no Completed line parsed)
  local latest_csv
  latest_csv="$(pick_latest "$HASHES_DIR/hasher-*.csv")"
  if [ -n "$latest_csv" ]; then
    echo
    echo "Latest CSV: $latest_csv"
    echo "Row count (including header): $(wc -l < "$latest_csv" 2>/dev/null || echo 0)"
  fi

  # Show tail of the per-run log if present
  if [ -n "$last_run_id" ]; then
    run_log="$LOG_DIR/hasher-$last_run_id.log"
    if [ -f "$run_log" ]; then
      echo
      echo "Run log: $run_log (tail -n 20)"
      tail -n 20 "$run_log" || true
    fi
  fi

  # Active/idle hint
  if is_hashing_active; then
    echo
    echo "[STATUS] Hashing appears ACTIVE (recent progress in $bg)."
    echo "Tip: avoid launching a second run until this completes."
  else
    # If we showed a completed line, be explicit; otherwise generic
    if [ -n \"$completed_line\" ]; then
      echo
      echo "[STATUS] Hashing is COMPLETE for the latest run."
    else
      echo
      echo "[STATUS] No recent progress detected — hashing may be idle or complete."
    fi
  fi
  pause
}

# ───────────────────────── Actions ─────────────────────────
start_hashing(){
  # Guard against accidental double-start
  if is_hashing_active; then
    echo "[WARN] Hashing appears ACTIVE (recent progress in $LOG_DIR/background.log)."
    read -r -p "Start another run anyway? (y/N): " yn
    case "$yn" in y|Y) : ;; *) say "Cancelled."; pause; return ;; esac
  fi

  local algo="sha256"
  local pathfile="$PATHFILE_DEFAULT"
  if [ ! -f "$pathfile" ]; then
    say "paths file not found: $pathfile"
    echo -n "Create it now? (y/n) "
    read -r yn
    case "$yn" in
      y|Y) : ;;
      *) return ;;
    esac
    mkdir -p "$(dirname "$pathfile")"
    cat > "$pathfile" <<'TPL'
# One directory per line (absolute paths recommended), e.g.:
/volume1/Family
/volume1/Media
/volume1/James
# Lines beginning with # are ignored.
TPL
    say "Template written: $pathfile"
    open_in_editor "$pathfile"
  fi

  # CRLF warning
  if grep -q $'\r' "$pathfile"; then
    say "WARN: Detected CRLF in $pathfile (handled automatically). To normalise: sed -i 's/\r$//' \"$pathfile\""
  fi

  say "Starting hasher with nohup (algo=$algo, pathfile=$pathfile)"
  "$BIN_DIR/hasher.sh" --pathfile "$pathfile" --algo "$algo" --nohup
  echo
  say "Tail logs with:"
  echo "  tail -f \"$LOG_DIR/background.log\" \"$LOG_DIR/hasher.log\""
  pause
}

custom_hashing(){
  echo
  echo "=== Advanced / Custom hashing ==="

  # Pathfile
  read -r -p "Path file [default: $PATHFILE_DEFAULT]: " pathfile
  pathfile="${pathfile:-$PATHFILE_DEFAULT}"
  if [ ! -f "$pathfile" ]; then
    say "WARN: paths file not found: $pathfile"
    read -r -p "Create a template here? (y/N): " yn
    case "$yn" in y|Y) : ;; *) say "Aborting custom hashing."; pause; return ;; esac
    mkdir -p "$(dirname "$pathfile")"
    cat > "$pathfile" <<'TPL'
# One directory per line (absolute paths recommended), e.g.:
/volume1/Family
/volume1/Media
/volume1/James
# Lines beginning with # are ignored.
TPL
    say "Template written: $pathfile"
  fi

  # Algorithm
  echo "Select algorithm: [1] sha256 (default), [2] sha1, [3] sha512, [4] md5, [5] blake2"
  read -r -p "> " algopt
  case "${algopt:-1}" in
    2) algo="sha1" ;;
    3) algo="sha512" ;;
    4) algo="md5" ;;
    5) algo="blake2" ;;
    *) algo="sha256" ;;
  esac

  # Mode
  echo "Run mode: [b]ackground (nohup, default) or [f]oreground?"
  read -r -p "> " mode
  case "${mode:-b}" in
    f|F) nohup_flag=false ;;
    *)   nohup_flag=true ;;
  esac

  # Zero-length-only
  echo "Zero-length-only scan (no hashing)? [y/N]"
  read -r -p "> " zopt
  case "${zopt:-n}" in y|Y) zlo=true ;; *) zlo=false ;; esac

  # Extra excludes (literal substring match; comma separated)
  read -r -p "Extra excludes (comma-separated substrings, leave blank for none): " extra_ex
  IFS=',' read -r -a extra_patterns <<< "${extra_ex:-}"

  # Optional config file
  read -r -p "Use a specific config file (leave blank to auto-detect): " conf_file

  # Optional custom output CSV path
  read -r -p "Output CSV path (leave blank for default in hashes/): " out_csv

  # Build command
  cmd=( "$BIN_DIR/hasher.sh" --pathfile "$pathfile" --algo "$algo" )
  [ -n "$conf_file" ] && cmd+=( --config "$conf_file" )
  [ -n "$out_csv" ] && cmd+=( --output "$out_csv" )
  if [ "${#extra_patterns[@]}" -gt 0 ] && [ -n "${extra_patterns[0]}" ]; then
    for p in "${extra_patterns[@]}"; do
      p_trim="$(echo "$p" | sed 's/^ *//;s/ *$//')"
      [ -n "$p_trim" ] && cmd+=( --exclude "$p_trim" )
    done
  fi
  $zlo && cmd+=( --zero-length-only )
  $nohup_flag && cmd+=( --nohup )

  echo
  echo "About to run:"
  echo "  $(print_cmd "${cmd[@]}")"
  read -r -p "Proceed? (y/N): " go
  case "$go" in y|Y) "${cmd[@]}" ;; *) say "Cancelled." ;; esac
  pause
}

find_duplicates(){
  say "Finding duplicate groups using latest CSV in $HASHES_DIR"
  "$BIN_DIR/find-duplicates.sh" || true
  echo
  local latest_report
  latest_report="$(pick_latest "$LOG_DIR/*duplicate-hashes*.txt")"
  if [ -n "$latest_report" ]; then
    say "Report: $latest_report"
  else
    say "No duplicate report found."
  fi
  pause
}

review_duplicates(){
  local latest_report
  latest_report="$(pick_latest "$LOG_DIR/*duplicate-hashes*.txt")"
  if [ -z "$latest_report" ]; then
    say "No duplicate report found in $LOG_DIR. Run 'Find duplicate hashes' first."
    pause; return
  fi
  say "Launching review for: $latest_report"
  if [ -x "$BIN_DIR/review-latest.sh" ]; then
    "$BIN_DIR/review-latest.sh" || true
  else
    "$BIN_DIR/review-duplicates.sh" --from-report "$latest_report" || true
  fi
  pause
}

delete_zero_length(){
  local list
  list="$(pick_latest "$ZERO_DIR/zero-length-*.txt")"
  if [ -z "$list" ]; then
    say "No zero-length candidate list found in $ZERO_DIR"
    echo "Generate by running hashing or zero-length scan."
    pause; return
  fi
  echo "Zero-length list: $list"
  echo "Choose mode: [v]erify-only (default), [d]ry-run, [f]orce, [q]uarantine"
  read -r -p "> " mode
  case "${mode:-v}" in
    q|Q)
      local qdir="$ZERO_DIR/quarantine-$(date +%F)"
      "$BIN_DIR/delete-zero-length.sh" "$list" --force --quarantine "$qdir" ;;
    f|F)
      "$BIN_DIR/delete-zero-length.sh" "$list" --force ;;
    d|D)
      "$BIN_DIR/delete-zero-length.sh" "$list" ;;
    *)
      "$BIN_DIR/delete-zero-length.sh" "$list" --verify-only ;;
  esac
  pause
}

delete_low_value(){
  local list
  list="$(pick_latest "$LOW_DIR/low-value-candidates-*.txt")"
  if [ -z "$list" ]; then
    say "No low-value candidate list found in $LOW_DIR"
    echo "Run 'Review duplicate hashes' to generate one."
    pause; return
  fi
  echo "Low-value list: $list"
  echo "Choose mode: [v]erify-only (default), [d]ry-run, [f]orce, [q]uarantine"
  read -r -p "> " mode
  case "${mode:-v}" in
    q|Q)
      local qdir="$LOW_DIR/quarantine-$(date +%F)"
      "$BIN_DIR/delete-low-value.sh" --from-list "$list" --force --quarantine "$qdir" ;;
    f|F)
      "$BIN_DIR/delete-low-value.sh" --from-list "$list" --force ;;
    d|D)
      "$BIN_DIR/delete-low-value.sh" --from-list "$list" ;;
    *)
      "$BIN_DIR/delete-low-value.sh" --from-list "$list" --verify-only ;;
  esac
  pause
}

populate_paths(){
  local f="$PATHFILE_DEFAULT"
  mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then
    cat > "$f" <<'TPL'
# One directory per line (absolute paths recommended), e.g.:
/volume1/Family
/volume1/Media
/volume1/James
# Lines beginning with # are ignored.
TPL
    say "Template written: $f"
  else
    say "Editing existing: $f"
  fi
  open_in_editor "$f"
}

edit_conf(){
  local f_local="$CONF_DEFAULT_LOCAL"
  mkdir -p "$(dirname "$f_local")"
  if [ ! -f "$f_local" ]; then
    if [ -r "$CONF_DEFAULT_DIST" ]; then
      cp -f "$CONF_DEFAULT_DIST" "$f_local"
      say "Created local override from default: $f_local"
    else
      cat > "$f_local" <<'TPL'
# local/hasher.conf (overrides default/hasher.conf)
# Example overrides:
# LOW_VALUE_THRESHOLD_BYTES=0
# ZERO_APPLY_EXCLUDES=false
# EXCLUDES_FILE=local/excludes.txt
TPL
      say "Created blank local config: $f_local"
    fi
  fi
  open_in_editor "$f_local"
}

# ───────────────────────── Main loop ───────────────────────
while true; do
  menu
  read -r choice
  case "${choice:-}" in
    0) show_hash_status ;;
    1) start_hashing ;;
    8) custom_hashing ;;
    2) find_duplicates ;;
    3) review_duplicates ;;
    4) delete_zero_length ;;
    5) delete_low_value ;;
    6) populate_paths ;;
    7) edit_conf ;;
    q|Q) echo "Bye!"; exit 0 ;;
    *) echo "Unknown option: $choice"; sleep 1 ;;
  esac
done
