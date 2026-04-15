#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#
# NOTE: This launcher requires bash (not plain sh) because:
#   - action_clean_caches uses 'read -r -d ""' (bash/ksh extension)
#   - The project's hasher.sh also requires bash
# Minimum: bash 3.2+ (compatible with Synology DSM default bash)

set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$ROOT_DIR"

LOGS_DIR="$ROOT_DIR/logs"; mkdir -p "$LOGS_DIR"
HASHES_DIR="$ROOT_DIR/hashes"; mkdir -p "$HASHES_DIR"
BIN_DIR="$ROOT_DIR/bin"
LOCAL_DIR="$ROOT_DIR/local"
BACKGROUND_LOG="$LOGS_DIR/background.log"
VAR_DIR="$ROOT_DIR/var"; mkdir -p "$VAR_DIR"

# Pidfile for reliable hasher-running detection
HASHER_PIDFILE="$VAR_DIR/hasher.pid"

# TTY-aware colour palette
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  RED="$(printf '\033[31m')"
  GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"
  BLU="$(printf '\033[34m')"
  MAG="$(printf '\033[35m')"
  BOLD="$(printf '\033[1m')"
  RST="$(printf '\033[0m')"
else
  RED=""; GRN=""; YEL=""; BLU=""; MAG=""; BOLD=""; RST=""
fi

info(){  printf "%s[INFO]%s %s\n"  "$GRN" "$RST" "$*"; }
warn(){  printf "%s[WARN]%s %s\n"  "$YEL" "$RST" "$*"; }
err(){   printf "%s[ERR ]%s %s\n"  "$RED" "$RST" "$*"; }
next(){  printf "%s[NEXT]%s %s\n" "$BLU" "$RST" "$*"; }

header() {
  printf "%s" "$MAG"
  printf "%s\n" " _   _           _               "
  printf "%s\n" "| | | | __ _ ___| |__   ___ _ __ "
  printf "%s\n" "| |_| |/ _' / __| '_ \ / _ \ '__|"
  printf "%s\n" "|  _  | (_| \__ \ | | |  __/ |   "
  printf "%s\n" "|_| |_|\__,_|___/_| |_|\___|_|   "
  printf "\n%s\n" "      NAS File Hasher & Dedupe"
  printf "\n%s\n" "      v1.1.5 - Feb 2026. James Wintermute"
  printf "%s" "$RST"
  printf "\n"
}

# ── Pidfile-based running detection ──────────────────────────────────────────
# FIX: replaced unreliable ps|grep approach with a pidfile.
# The pidfile is written when hasher is launched and cleared on completion.
# This avoids false positives from paths containing "hasher" and ps truncation.

write_pidfile() {
  printf "%s\n" "$1" >"$HASHER_PIDFILE"
}

clear_pidfile() {
  rm -f "$HASHER_PIDFILE" 2>/dev/null || true
}

is_hasher_running() {
  [ -f "$HASHER_PIDFILE" ] || return 1
  pid="$(cat "$HASHER_PIDFILE" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) clear_pidfile; return 1 ;;
  esac
  # Check the pid is actually alive
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  else
    # Stale pidfile — process is gone
    clear_pidfile
    return 1
  fi
}

ensure_no_running_hasher() {
  if is_hasher_running; then
    pid="$(cat "$HASHER_PIDFILE" 2>/dev/null || true)"
    warn "Hasher appears to be already running (PID $pid)."
    printf "Start another run anyway? [y/N]: "
    read -r ans || ans=""
    case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      *) printf "Aborting new hasher run.\n"; return 1 ;;
    esac
  fi
  return 0
}

print_menu() {
  echo
  echo "### Stage 1 - Hash ###"
  echo "  0) Check hashing status (static)"
  echo "  1) Start Hashing (NAS-safe defaults)"
  echo "  8) Advanced / Custom hashing"
  echo
  echo "### Stage 2 - Identify ###"
  echo "  2) Find duplicate folders"
  echo "  3) Find duplicate files"
  echo " 12) Find file by HASH (lookup)"
  echo
  echo "### Stage 3 - Clean up ###"
  echo "  4) Review duplicates (interactive)"
  echo " 16) Auto-dedup (keep shortest path — no prompts)"
  echo "  5) Delete zero-length files"
  echo "  6) Delete duplicates (apply plan)"
  echo " 10) Clean cache files & @eaDir (safe)"
  echo " 11) Delete junk (uses local/junk-extensions.txt)"
  echo
  echo "### Other ###"
  echo "  7) System check (deps & readiness)"
  echo "  9) Follow logs (tail -f background.log)"
  echo " 13) Stats & scheduling hints"
  echo " 14) Clean internal working files (var/)"
  echo " 15) Clean logs (rotate & prune old logs/plans)"
  echo
  echo "  q) Quit"
  echo
  printf "Select an option: "
}

latest_hashes_csv() {
  # shellcheck disable=SC2012
  f="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
  [ -n "${f:-}" ] && printf "%s" "$f" || printf ""
}

determine_paths_file() {
  if [ -s "$LOCAL_DIR/paths.txt" ]; then printf "%s" "$LOCAL_DIR/paths.txt"; return; fi
  if [ -s "$ROOT_DIR/paths.txt" ]; then printf "%s" "$ROOT_DIR/paths.txt"; return; fi
  printf ""
}

determine_excludes_file() {
  if [ -s "$LOCAL_DIR/excludes.txt" ]; then printf "%s" "$LOCAL_DIR/excludes.txt"; return; fi
  printf ""
}

sample_files_quick() {
  pfile="$1"
  [ -s "$pfile" ] || { printf "0"; return; }
  total=0
  # shellcheck disable=SC2162
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|"") continue ;; esac
    [ -d "$line" ] || continue
    # FIX: added head -n 10001 safety limit to prevent hanging on huge volumes.
    # The count is capped at 10000+ as a signal rather than an exact number.
    c="$(find "$line" -maxdepth 2 -type f 2>/dev/null | head -n 10001 | wc -l | tr -d ' ')" || c=0
    total=$(( total + c ))
  done < "$pfile"
  printf "%s" "$total"
}

preflight_hashing() {
  pfile="$(determine_paths_file)"
  efile="$(determine_excludes_file)"
  if [ -n "$pfile" ]; then
    roots=0; exist=0; missing=0
    # shellcheck disable=SC2162
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|"") continue ;; esac
      roots=$((roots+1))
      if [ -d "$line" ]; then exist=$((exist+1)); else missing=$((missing+1)); fi
    done < "$pfile"
    info "Paths file: $pfile"
    info "Roots listed: $roots (existing: $exist, missing: $missing)"
    info "Quick sample (depth≤2): at least $(sample_files_quick "$pfile") files to scan (lower-bound)."
  else
    warn "No paths file found (local/paths.txt or ./paths.txt)."
  fi
  if [ -n "$efile" ]; then info "Excludes file: $efile"; fi
}

find_hasher_script() {
  for c in "$ROOT_DIR/hasher.sh" "$BIN_DIR/hasher.sh" "$ROOT_DIR/scripts/hasher.sh" "$ROOT_DIR/tools/hasher.sh"; do
    [ -f "$c" ] && { printf "%s" "$c"; return 0; }
  done
  # shellcheck disable=SC2010
  f="$(ls -1 "$BIN_DIR"/hasher*.sh 2>/dev/null | head -n1 || true)"
  [ -n "${f:-}" ] && { printf "%s" "$f"; return 0; }
  return 1
}

run_hasher_nohup() {
  if ! ensure_no_running_hasher; then
    return 0
  fi

  script="$(find_hasher_script || true)"
  if [ -z "${script:-}" ]; then err "hasher.sh not found."; return 1; fi

  preflight_hashing
  : >"$BACKGROUND_LOG" 2>/dev/null || true

  pfile="$(determine_paths_file)"
  efile="$(determine_excludes_file)"

  set -- "$script"
  if [ -n "$pfile" ]; then
    set -- "$@" --pathfile "$pfile"
  fi
  if [ -n "$efile" ]; then
    # shellcheck disable=SC2162
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|"") continue ;; esac
      pat="$(printf "%s" "$line" | sed 's/\*//g; s://*:/:g; s:/*$::')"
      [ -n "$pat" ] && set -- "$@" --exclude "$pat"
    done < "$efile"
  fi

  set -- "$@" --exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"

  info "Starting hasher: $script (nohup to $BACKGROUND_LOG)"
  if [ -x "$script" ]; then
    nohup "$@" </dev/null >>"$BACKGROUND_LOG" 2>&1 &
  else
    nohup sh "$@" </dev/null >>"$BACKGROUND_LOG" 2>&1 &
  fi
  bgpid=$!

  # FIX: write pidfile so is_hasher_running() works reliably
  write_pidfile "$bgpid"

  # Register cleanup so pidfile is removed when the background process exits
  # (best-effort; works when launched from an interactive shell)
  ( wait "$bgpid" 2>/dev/null; clear_pidfile ) &

  sleep 1
  if tail -n 5 "$BACKGROUND_LOG" 2>/dev/null | grep -q 'Run-ID:'; then
    next "Hasher launched (PID $bgpid)."
  else
    warn "Hasher may not be running. Recent log:"
    tail -n 60 "$BACKGROUND_LOG" 2>/dev/null || true
    clear_pidfile
  fi
  info "While it runs, use option 9 to watch logs. Path: $BACKGROUND_LOG"
}

run_hasher_interactive() {
  if ! ensure_no_running_hasher; then
    return 0
  fi

  script="$(find_hasher_script || true)"
  if [ -z "${script:-}" ]; then err "hasher.sh not found."; return 1; fi

  pfile="$(determine_paths_file)"
  efile="$(determine_excludes_file)"

  set -- "$script"
  if [ -n "$pfile" ]; then set -- "$@" --pathfile "$pfile"; fi
  if [ -n "$efile" ]; then
    # shellcheck disable=SC2162
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|"") continue ;; esac
      pat="$(printf "%s" "$line" | sed 's/\*//g; s://*:/:g; s:/*$::')"
      [ -n "$pat" ] && set -- "$@" --exclude "$pat"
    done < "$efile"
  fi

  set -- "$@" --exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"

  info "Running hasher interactively: $script"
  if [ -x "$script" ]; then "$@"; else sh "$@"; fi
}

action_check_status(){
  info "Background log: $BACKGROUND_LOG"
  if is_hasher_running; then
    pid="$(cat "$HASHER_PIDFILE" 2>/dev/null || true)"
    info "Hasher is currently running (PID $pid)."
  else
    info "Hasher is not currently running."
  fi
  [ -f "$BACKGROUND_LOG" ] && tail -n 200 "$BACKGROUND_LOG" || info "No background.log yet."
  printf "Press Enter to continue... "; read -r _ || true;
}

action_start_hashing(){
  run_hasher_nohup
  printf "Press Enter to continue... "; read -r _ || true;
}

action_custom_hashing(){
  run_hasher_interactive
  printf "Press Enter to continue... "; read -r _ || true;
}

action_view_logs_follow(){
  if [ ! -f "$BACKGROUND_LOG" ]; then
    info "No background.log yet."
    printf "Press Enter to continue... "; read -r _ || true;
    return
  fi
  info "Following $BACKGROUND_LOG"
  printf "%s(Ctrl+C to stop)%s\n" "$YEL" "$RST"
  tail -f "$BACKGROUND_LOG"
}

action_find_duplicate_folders(){
  input="$(latest_hashes_csv)"
  [ -z "$input" ] && { err "No hashes CSV found."; printf "Press Enter to continue... "; read -r _ || true; return; }
  info "Using hashes file: $input"

  if [ ! -x "$BIN_DIR/find-duplicate-folders.sh" ]; then
    err "$BIN_DIR/find-duplicate-folders.sh not found or not executable."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  # FIX: inform the user of the defaults being applied, especially --keep shortest-path
  # which silently decides which copy is the "primary". Users should know this.
  echo
  info "Running with defaults: --mode plan --scope recursive --min-group-size 2 --keep shortest-path"
  warn "Note: '--keep shortest-path' will nominate the copy with the shortest path as the keeper."
  warn "Edit local/hasher.conf to change this default, or run find-duplicate-folders.sh directly for custom flags."
  echo

  "$BIN_DIR/find-duplicate-folders.sh" \
    --input "$input"       \
    --mode plan            \
    --scope recursive      \
    --min-group-size 2     \
    --keep shortest-path   \
    || true

  plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
  if [ -n "$plan" ]; then
    info "Plan saved to: $plan"
    info "Review it first (cat/tail), then run option 6) Delete duplicates (apply plan)."
  else
    info "No folder plan found to suggest next steps."
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

action_find_duplicate_files(){
  if [ -x "$BIN_DIR/run-find-duplicates.sh" ]; then
    "$BIN_DIR/run-find-duplicates.sh" || true
  else
    input="$(latest_hashes_csv)"
    [ -z "$input" ] && { err "No hashes CSV found."; printf "Press Enter to continue... "; read -r _ || true; return; }
    info "Using hashes file: $input"
    if [ -x "$BIN_DIR/find-duplicates.sh" ]; then
      "$BIN_DIR/find-duplicates.sh" --input "$input" || true
    else
      err "$BIN_DIR/find-duplicates.sh not found or not executable."
    fi
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

action_review_duplicates(){
  if [ -x "$BIN_DIR/launch-review.sh" ]; then
    "$BIN_DIR/launch-review.sh" || true
  else
    if [ -x "$BIN_DIR/review-duplicates.sh" ]; then
      "$BIN_DIR/review-duplicates.sh" || true
    else
      err "$BIN_DIR/review-duplicates.sh not found or not executable."
    fi
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

action_delete_zero_length(){
  if [ -x "$BIN_DIR/delete-zero-length.sh" ]; then
    "$BIN_DIR/delete-zero-length.sh" || true
  else
    err "$BIN_DIR/delete-zero-length.sh not found or not executable."
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

# FIX: action_apply_plan previously silently preferred file plans and never
# mentioned folder plans if a file plan existed. Now both are surfaced and
# the user chooses which to apply.
action_apply_plan(){
  file_plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  folder_plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"

  has_file=0; has_folder=0
  [ -n "$file_plan" ]   && has_file=1
  [ -n "$folder_plan" ] && has_folder=1

  if [ "$has_file" -eq 0 ] && [ "$has_folder" -eq 0 ]; then
    info "No file or folder plan found. Run option 2 or 4 first."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  echo
  if [ "$has_file" -eq 1 ]; then
    info "Latest FILE dedupe plan:   $file_plan"
  else
    info "No file dedupe plan found."
  fi
  if [ "$has_folder" -eq 1 ]; then
    info "Latest FOLDER dedupe plan: $folder_plan"
  else
    info "No folder dedupe plan found."
  fi

  echo
  echo "Which plan do you want to apply?"
  [ "$has_file"   -eq 1 ] && echo "  f) Apply FILE plan   (from review-duplicates)"
  [ "$has_folder" -eq 1 ] && echo "  d) Apply FOLDER plan (from find-duplicate-folders)"
  echo "  q) Cancel"
  printf "Choice: "
  read -r ans || ans="q"

  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    f)
      if [ "$has_file" -eq 0 ]; then
        warn "No file plan available."; printf "Press Enter to continue... "; read -r _ || true; return
      fi
      info "Applying FILE plan: $file_plan"
      if [ -x "$BIN_DIR/delete-duplicates.sh" ]; then
        "$BIN_DIR/delete-duplicates.sh" "$file_plan" || true
      else
        err "$BIN_DIR/delete-duplicates.sh not found or not executable."
      fi
      ;;
    d)
      if [ "$has_folder" -eq 0 ]; then
        warn "No folder plan available."; printf "Press Enter to continue... "; read -r _ || true; return
      fi
      info "Applying FOLDER plan: $folder_plan"
      if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
        "$BIN_DIR/apply-folder-plan.sh" --plan "$folder_plan" --force || true
      else
        err "$BIN_DIR/apply-folder-plan.sh not found or not executable."
      fi
      ;;
    *)
      info "Cancelled."
      ;;
  esac

  printf "Press Enter to continue... "; read -r _ || true
}

action_system_check(){
  info "System check:"
  command -v awk  >/dev/null && echo "  - awk:  OK" || echo "  - awk:  MISSING"
  command -v sort >/dev/null && echo "  - sort: OK" || echo "  - sort: MISSING"
  command -v cksum>/dev/null && echo "  - cksum:OK" || echo "  - cksum:MISSING"
  command -v stat >/dev/null && echo "  - stat: OK" || echo "  - stat: MISSING"
  command -v df   >/dev/null && echo "  - df:   OK" || echo "  - df:   MISSING"
  echo "  - Logs dir:    $LOGS_DIR"
  echo "  - Hashes dir:  $HASHES_DIR"
  echo "  - Bin dir:     $BIN_DIR"
  echo "  - Latest CSV:  $(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || echo none)"
  pfile="$(determine_paths_file)"
  if [ -n "$pfile" ]; then
    echo "  - Paths file: $pfile"
    sed -n '1,10p' "$pfile" | sed 's/^/      /'
    echo "    Lower-bound (depth≤2): $(sample_files_quick "$pfile") files"
  else
    echo "  - Paths file: (none found)"
  fi
  efile="$(determine_excludes_file)"
  if [ -n "$efile" ]; then
    echo "  - Excludes: $efile"
    sed -n '1,10p' "$efile" | sed 's/^/      /'
  fi
  printf "Press Enter to continue... "; read -r _ || true;
}

action_clean_caches() {
  paths_file="$LOCAL_DIR/paths.txt"
  default_root="/volume1"
  listfile="$VAR_DIR/eadir-list-$(date +%s).txt"
  : > "$listfile"

  if [ -f "$paths_file" ]; then
    info "Using roots from $paths_file"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|"") continue ;; esac
      [ -d "$line" ] || { warn "Missing root: $line"; continue; }
      find "$line" -type d -name '@eaDir' -prune -print0 >> "$listfile"
    done < "$paths_file"
  else
    printf "Root to clean (default: %s): " "$default_root"; read -r _r || _r=""
    root="${_r:-$default_root}"
    [ -d "$root" ] || { warn "Missing root: $root"; printf "Press Enter to continue... "; read -r _ || true; return; }
    find "$root" -type d -name '@eaDir' -prune -print0 >> "$listfile"
  fi

  total=0
  if [ -s "$listfile" ]; then
    total=$(tr -cd '\0' < "$listfile" | wc -c | tr -d ' ')
  fi
  info "Found @eaDir directories: $total"
  if [ "$total" -eq 0 ]; then
    printf "Nothing to clean. Press Enter to continue... "; read -r _ || true; return
  fi

  printf '[INFO] Examples:\n'
  tr '\0' '\n' < "$listfile" | head -n 10

  printf "Delete ALL @eaDir directories found? [y/N]: "
  read -r ans || ans=""
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *) info "Aborted."; printf "Press Enter to continue... "; read -r _ || true; return ;;
  esac

  done_count=0
  last=$(date +%s)
  while IFS= read -r -d '' d; do
    rm -rf -- "$d" 2>/dev/null || true
    done_count=$((done_count+1))
    now=$(date +%s)
    if [ $((now-last)) -ge 15 ] 2>/dev/null; then
      printf '[PROGRESS] Deleted %d/%d @eaDir folders\n' "$done_count" "$total"
      last="$now"
    fi
  done < "$listfile"

  rm -f "$listfile" 2>/dev/null || true
  printf '[OK] Deleted %d @eaDir folders.\n' "$done_count"
  printf "Press Enter to continue... "; read -r _ || true
}

action_delete_junk(){
  if [ ! -x "$BIN_DIR/delete-junk.sh" ]; then
    err "$BIN_DIR/delete-junk.sh not found or not executable."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  echo
  echo ">>> Delete junk files"
  echo "    - Using rules from: local/junk-extensions.txt"
  echo "    - Matches both extensions (e.g. AAE, LRV, THM)"
  echo "      and common junk basenames (Thumbs.db, .DS_Store, Desktop.ini)"
  echo
  echo "The script will:"
  echo "  - Scan your configured paths (local/paths.txt)"
  echo "  - Show a preview of junk files and total size"
  echo "  - Ask for confirmation before deleting anything"
  echo

  "$BIN_DIR/delete-junk.sh"
  printf "Press Enter to continue... "; read -r _ || true
}

# FIX: SHA256 validation previously only checked the first character with a
# case pattern, allowing strings like "abc123xyz" to pass. Now validates
# that the entire string is 64 hex characters using grep -E.
action_find_by_hash() {
  printf "Enter SHA256 hash to look up: "
  read -r HASHVAL || HASHVAL=""
  if [ -z "$HASHVAL" ]; then
    warn "No hash entered."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  clean_hash="$(printf "%s" "$HASHVAL" | tr -d '[:space:]')"

  # Full-string validation: must be exactly 64 hex characters
  if ! printf "%s" "$clean_hash" | grep -qE '^[0-9a-fA-F]{64}$'; then
    warn "Input does not look like a valid SHA256 hash (expected 64 hex characters)."
    warn "Got: $clean_hash"
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  if [ -x "$BIN_DIR/hash-check.sh" ] || [ -f "$BIN_DIR/hash-check.sh" ]; then
    info "Looking up hash: $clean_hash"
    "$BIN_DIR/hash-check.sh" "$clean_hash" || true
  else
    err "hash-check.sh not found in $BIN_DIR"
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

action_stats_and_cron() {
  info "Hasher usage stats (approximate):"

  csv_count=$(ls -1 "$HASHES_DIR"/hasher-*.csv 2>/dev/null | wc -l | tr -d ' ')
  echo "  - Hash runs (CSV files): $csv_count"

  latest_csv=$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)
  if [ -n "$latest_csv" ]; then
    echo "  - Latest hashes CSV: $latest_csv"
  else
    echo "  - Latest hashes CSV: (none yet)"
  fi

  plan_count=$(ls -1 "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | wc -l | tr -d ' ')
  echo "  - File dedupe plans created: $plan_count"

  latest_plan=$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)
  if [ -n "$latest_plan" ] && [ -f "$latest_plan" ]; then
    echo "  - Latest file dedupe plan: $latest_plan"
  fi

  echo
  echo "Example cron entries (templates only; adjust paths & options):"
  echo
  echo "  # Run hasher nightly at 02:00"
  echo "  0 2 * * * cd <hasher_root_dir> && ./hasher.sh --pathfile local/paths.txt >> logs/cron-hash.log 2>&1"
  echo
  echo "  # Run junk cleaner weekly on Sundays at 03:00"
  echo "  0 3 * * 0 cd <hasher_root_dir> && bin/delete-junk.sh >> logs/cron-junk.log 2>&1"
  echo
  echo "Edit crontab with: crontab -e"
  printf "Press Enter to continue... "; read -r _ || true
}

action_clean_logs() {
  if [ ! -x "$BIN_DIR/clean-logs.sh" ]; then
    err "$BIN_DIR/clean-logs.sh not found or not executable."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi
  echo
  info "Running log housekeeping (bin/clean-logs.sh)…"
  info "This will rotate large logs and prune old hash CSVs, run logs, and dedupe plans."
  echo
  "$BIN_DIR/clean-logs.sh" || true
  printf "Press Enter to continue... "; read -r _ || true
}

action_clean_internal() {
  if [ ! -d "$VAR_DIR" ]; then
    info "VAR dir not found: $VAR_DIR"
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  # Single find pass into a temp file
  tmplist="$VAR_DIR/.clean-list-$$.txt"
  find "$VAR_DIR" -mindepth 1 -maxdepth 10 -print 2>/dev/null >"$tmplist" || true
  count="$(wc -l <"$tmplist" | tr -d ' ')"

  info "Internal working dir: $VAR_DIR"
  echo "  - Items that would be removed (files + dirs): $count"

  if [ "${count:-0}" -eq 0 ] 2>/dev/null; then
    rm -f "$tmplist"
    info "Nothing to clean."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  printf "Delete ALL contents of %s (keeping the directory itself)? [y/N]: " "$VAR_DIR"
  read -r ans || ans=""
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      # Delete deepest entries first to handle non-empty dirs correctly
      sort -r "$tmplist" | while IFS= read -r item; do
        rm -rf -- "$item" 2>/dev/null || true
      done
      rm -f "$tmplist"
      info "Internal working files cleaned."
      ;;
    *)
      rm -f "$tmplist"
      info "Aborted."
      ;;
  esac

  printf "Press Enter to continue... "; read -r _ || true
}

action_auto_dedup() {
  if [ ! -x "$BIN_DIR/auto-dedup.sh" ]; then
    err "$BIN_DIR/auto-dedup.sh not found or not executable."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  echo
  echo ">>> Auto-dedup — keep shortest path"
  echo
  echo "This will automatically generate a dedup plan for ALL duplicate groups"
  echo "without interactive review. The strategy is: for each group, the copy"
  echo "with the SHORTEST file path is kept; all others are marked for deletion."
  echo
  echo "No files are moved yet — a plan file is written to logs/."
  echo "Review it with:  cat <plan-file> | grep '^DEL' | head -50"
  echo "Apply it with:   option 6 (Delete duplicates / apply plan)"
  echo

  # Optional: allow choosing a different strategy
  echo "Keep strategy:"
  echo "  1) shortest-path  (default — recommended for dedupe after backup copies)"
  echo "  2) longest-path"
  echo "  3) newest"
  echo "  4) oldest"
  printf "Strategy [1]: "
  read -r strat_choice || strat_choice="1"
  case "${strat_choice:-1}" in
    2) KEEP="longest-path" ;;
    3) KEEP="newest" ;;
    4) KEEP="oldest" ;;
    *) KEEP="shortest-path" ;;
  esac

  echo
  info "Running auto-dedup with strategy: $KEEP"
  echo

  "$BIN_DIR/auto-dedup.sh" --keep "$KEEP" || true

  printf "Press Enter to continue... "; read -r _ || true
}

# ── Main loop ─────────────────────────────────────────────────────────────────
while :; do
  clear 2>/dev/null || true
  header
  print_menu
  read -r choice || { echo; exit 0; }

  case "${choice:-}" in
    0)  action_check_status ;;
    1)  action_start_hashing ;;
    8)  action_custom_hashing ;;
    2)  action_find_duplicate_folders ;;
    3)  action_find_duplicate_files ;;
    12) action_find_by_hash ;;
    4)  action_review_duplicates ;;
    16) action_auto_dedup ;;
    5)  action_delete_zero_length ;;
    6)  action_apply_plan ;;
    10) action_clean_caches ;;
    11) action_delete_junk ;;
    7)  action_system_check ;;
    9)  action_view_logs_follow ;;
    13) action_stats_and_cron ;;
    14) action_clean_internal ;;
    15) action_clean_logs ;;
    q|Q)
        echo "Bye."
        exit 0
        ;;
    *)
        echo "Unknown option: $choice"
        sleep 1
        ;;
  esac
done
