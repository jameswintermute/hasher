#!/bin/sh
# Minimal BusyBox-safe launcher for Hasher — correctly passes --pathfile/--exclude.
# POSIX sh only: no arrays, no bashisms, nohup with </dev/null, no eval, no process substitution.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$ROOT_DIR"

LOGS_DIR="$ROOT_DIR/logs"; mkdir -p "$LOGS_DIR"
HASHES_DIR="$ROOT_DIR/hashes"; mkdir -p "$HASHES_DIR"
BIN_DIR="$ROOT_DIR/bin"
LOCAL_DIR="$ROOT_DIR/local"
BACKGROUND_LOG="$LOGS_DIR/background.log"
VAR_DIR="$ROOT_DIR/var"; mkdir -p "$VAR_DIR"

# ------------------------------------------------------------------
# Standardized color palette (TTY-aware)
# ------------------------------------------------------------------
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

# keep original names but use standardized look
info(){  printf "%s[INFO]%s %s\n"  "$GRN" "$RST" "$*"; }
ok(){    printf "%s[OK  ]%s %s\n"  "$BLU" "$RST" "$*"; }
warn(){  printf "%s[WARN]%s %s\n"  "$YEL" "$RST" "$*"; }
err(){   printf "%s[ERR ]%s %s\n"  "$RED" "$RST" "$*"; }

header() {
  printf "%s" "$MAG"
  printf "%s\n" " _   _           _               "
  printf "%s\n" "| | | | __ _ ___| |__   ___ _ __ "
  printf "%s\n" "| |_| |/ _' / __| '_ \ / _ \ '__|"
  printf "%s\n" "|  _  | (_| \__ \ | | |  __/ |   "
  printf "%s\n" "|_| |_|\__,_|___/_| |_|\___|_|   "
  printf "\n%s\n" "      NAS File Hasher & Dedupe"
  printf "\n%s\n" "      v1.0.9 - Nov 2025"
  printf "%s" "$RST"
  printf "\n"
}

# --- NEW: Running Hasher detection ---
is_hasher_running() {
  # BusyBox-safe process check.
  # We look for hasher processes but ignore the launcher itself.
  if ps w 2>/dev/null | grep '[h]asher' | grep -v 'launcher.sh' >/dev/null; then
    return 0
  fi
  return 1
}

ensure_no_running_hasher() {
  if is_hasher_running; then
    warn "Hasher appears to be already running."
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
  printf "%s\n" "### Stage 1 - Hash ###"
  printf "%s\n" "  0) Check hashing status (static)"
  printf "%s\n" "  1) Start Hashing (NAS-safe defaults)"
  printf "%s\n" "  8) Advanced / Custom hashing"
  printf "\n"
  printf "%s\n" "### Stage 2 - Identify ###"
  printf "%s\n" "  2) Find duplicate folders"
  printf "%s\n" "  3) Find duplicate files"
  printf "%s\n" " 12) Find file by HASH (lookup)   <-- NEW"
  printf "\n"
  printf "%s\n" "### Stage 3 - Clean up ###"
  printf "%s\n" "  4) Review duplicates (interactive)"
  printf "%s\n" "  5) Delete zero-length files"
  printf "%s\n" "  6) Delete duplicates (apply plan)"
  printf "%s\n" "  10) Clean cache files & @eaDir (safe)"
  printf "%s\n" "  11) Delete junk (Thumbs.db, .DS_Store, @eaDir, etc.)"
  printf "\n"
  printf "%s\n" "### Other ###"
  printf "%s\n" "  7) System check (deps & readiness)"
  printf "%s\n" "  9) Follow logs (tail -f background.log)"
  printf "\n"
  printf "%s\n" "  q) Quit"
  printf "\n"
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
    case "$line" in \#*|"" ) continue ;; esac
    [ -d "$line" ] || continue
    c="$(find "$line" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')" || c=0
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
      case "$line" in \#*|"" ) continue ;; esac
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
  # Concurrency guard
  if ! ensure_no_running_hasher; then
    return 0
  fi

  script="$(find_hasher_script || true)"
  if [ -z "${script:-}" ]; then err "hasher.sh not found."; return 1; fi

  preflight_hashing
  : >"$BACKGROUND_LOG" 2>/dev/null || true

  pfile="$(determine_paths_file)"
  efile="$(determine_excludes_file)"

  # Build argv in POSIX-safe way (set --)
  set -- "$script"
  if [ -n "$pfile" ]; then
    set -- "$@" --pathfile "$pfile"
  fi
  if [ -n "$efile" ]; then
    # shellcheck disable=SC2162
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|"" ) continue ;; esac
      pat="$(printf "%s" "$line" | sed 's/\*//g; s://*:/:g; s:/*$::')"
      [ -n "$pat" ] && set -- "$@" --exclude "$pat"
    done < "$efile"
  fi

  # Hard-exclude known recycle bins
  set -- "$@" --exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"

  info "Starting hasher: $script (nohup to $BACKGROUND_LOG)"
  if [ -x "$script" ]; then
    nohup "$@" </dev/null >>"$BACKGROUND_LOG" 2>&1 &
  else
    nohup sh "$@" </dev/null >>"$BACKGROUND_LOG" 2>&1 &
  fi

  sleep 1
  if tail -n 5 "$BACKGROUND_LOG" 2>/dev/null | grep -q 'Run-ID:'; then
    ok "Hasher launched."
  else
    warn "Hasher may not be running. Recent log:"
    tail -n 60 "$BACKGROUND_LOG" 2>/dev/null || true
  fi
  info "While it runs, use option 9 to watch logs. Path: $BACKGROUND_LOG"
}

run_hasher_interactive() {
  # Concurrency guard
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
      case "$line" in \#*|"" ) continue ;; esac
      pat="$(printf "%s" "$line" | sed 's/\*//g; s://*:/:g; s:/*$::')"
      [ -n "$pat" ] && set -- "$@" --exclude "$pat"
    done < "$efile"
  fi

  # Hard-exclude known recycle bins
  set -- "$@" --exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"

  info "Running hasher interactively: $script"
  if [ -x "$script" ]; then "$@"; else sh "$@"; fi
}

action_check_status(){
  info "Background log: $BACKGROUND_LOG"
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

# Keep the rest of the actions as placeholders; they call existing bin scripts if present.
action_find_duplicate_folders(){
  input="$(latest_hashes_csv)"
  [ -z "$input" ] && { err "No hashes CSV found."; printf "Press Enter to continue... "; read -r _ || true; return; }
  info "Using hashes file: $input"
  if [ -x "$BIN_DIR/find-duplicate-folders.sh" ]; then
    "$BIN_DIR/find-duplicate-folders.sh"       --input "$input"       --mode plan       --scope recursive       --min-group-size 2       --keep shortest-path || true
    plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
    if [ -n "$plan" ]; then
      info "Plan saved to: $plan"
      info "Review it first (cat/tail), then run option 6) Delete duplicates (apply plan)."
    else
      info "No folder plan found to suggest next steps."
    fi
  else
    err "$BIN_DIR/find-duplicate-folders.sh not found or not executable."
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

# Updated Option 3: use wrapper with spinner + next steps
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

action_apply_plan(){
  dup_var_dir="$VAR_DIR/duplicates"; mkdir -p "$dup_var_dir"

  file_plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  [ -z "$file_plan" ] && [ -f "$dup_var_dir/latest-plan.txt" ] && file_plan="$dup_var_dir/latest-plan.txt"

  if [ -n "$file_plan" ]; then
    info "Found FILE delete plan: $file_plan"
    printf "Apply FILE plan now (move files to quarantine)? [y/N]: "; read -r ans || ans=""
    case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
      y|yes)
        if [ -x "$BIN_DIR/apply-file-plan.sh" ]; then
          "$BIN_DIR/apply-file-plan.sh" --plan "$file_plan" --force || true
        else
          err "$BIN_DIR/apply-file-plan.sh not found or not executable."
        fi
      ;;
    esac
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
  if [ -z "$plan" ]; then
    info "No folder plan found."
    printf "Press Enter to continue... "; read -r _ || true; return
  fi
  info "Found FOLDER plan: $plan"
  printf "Apply FOLDER plan now (move directories to quarantine)? [y/N]: "; read -r ans || ans=""
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      if [ -x "$BIN_DIR/apply-folder-plan.sh" ]; then
        "$BIN_DIR/apply-folder-plan.sh" --plan "$plan" --force || true
      else
        err "$BIN_DIR/apply-folder-plan.sh not found or not executable."
      fi
    ;;
  esac
  printf "Press Enter to continue... "; read -r _ || true
}

action_system_check(){
  info "System check:"
  command -v awk >/dev/null && echo "  - awk: OK" || echo "  - awk: MISSING"
  command -v sort >/dev/null && echo "  - sort: OK" || echo "  - sort: MISSING"
  command -v cksum >/dev/null && echo "  - cksum: OK"|| echo "  - cksum: MISSING"
  command -v stat >/dev/null && echo "  - stat: OK" || echo "  - stat: MISSING"
  command -v df >/dev/null && echo "  - df:   OK" || echo "  - df:   MISSING"
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
      case "$line" in \#*|"" ) continue ;; esac
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

  printf '[OK] Deleted %d @eaDir folders.\n' "$done_count"
  printf "Press Enter to continue... "; read -r _ || true
}

action_delete_junk(){
  junk_script=""
  if [ -x "$BIN_DIR/review-junk.sh" ]; then
    junk_script="$BIN_DIR/review-junk.sh"
  elif [ -x "$BIN_DIR/delete-junk.sh" ]; then
    junk_script="$BIN_DIR/delete-junk.sh"
  else
    err "$BIN_DIR/review-junk.sh / delete-junk.sh not found or not executable."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  pfile="$(determine_paths_file)"
  args_base=""
  [ -n "$pfile" ] && args_base="$args_base --paths-file $pfile"

  printf "\n[Junk Cleaner]\n"
  printf "  1) Scan / dry-run (recommended)\n"
  printf "  2) Scan and delete (force)\n"
  printf "  b) Back\n"
  printf "Choose an option: "
  read -r jc || jc=""
  case "$jc" in
    1)
      # shellcheck disable=SC2086
      "$junk_script" $args_base --dry-run || true
      ;;
    2)
      # shellcheck disable=SC2086
      "$junk_script" $args_base --force || true
      ;;
    b|B|"")
      ;;
    *)
      printf "Unknown option.\n"
      ;;
  esac
  printf "Press Enter to continue... "; read -r _ || true
}

# NEW: find file by hash
action_find_by_hash() {
  printf "Enter SHA256 hash to look up: "
  read -r HASHVAL || HASHVAL=""
  if [ -z "$HASHVAL" ]; then
    warn "No hash entered."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  if [ -x "$BIN_DIR/hash-check.sh" ] || [ -f "$BIN_DIR/hash-check.sh" ]; then
    info "Looking up hash: $HASHVAL"
    "$BIN_DIR/hash-check.sh" "$HASHVAL" || true
  else
    err "hash-check.sh not found in $BIN_DIR"
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

# main loop
while :; do
  clear 2>/dev/null || true
  header
  print_menu
  printf "Choose an option: "; read -r choice || { echo; exit 0; }
  case "${choice:-}" in
    0) action_check_status ;;
    1) action_start_hashing ;;
    8) action_custom_hashing ;;
    2) action_find_duplicate_folders ;;
    3) action_find_duplicate_files ;;
    12) action_find_by_hash ;;
    4) action_review_duplicates ;;
    5) action_delete_zero_length ;;
    6) action_apply_plan ;;
    10) action_clean_caches ;;
    11) action_delete_junk ;;
    7) action_system_check ;;
    9) action_view_logs_follow ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) echo "Unknown option: $choice" ; sleep 1 ;;
  esac
done
