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
LIB_DIR="$ROOT_DIR/lib"
BACKGROUND_LOG="$LOGS_DIR/background.log"
VAR_DIR="$ROOT_DIR/var"; mkdir -p "$VAR_DIR"

# Pidfile for reliable hasher-running detection
HASHER_PIDFILE="$VAR_DIR/hasher.pid"

# v1.2.0: parallel hashing worker count, persisted across launcher sessions
# in var/jobs.conf. 1 = serial (default). The performance menu ('p') edits it.
HASHER_JOBS_FILE="$VAR_DIR/jobs.conf"
HASHER_JOBS=1
if [ -r "$HASHER_JOBS_FILE" ]; then
  _j="$(head -n1 "$HASHER_JOBS_FILE" 2>/dev/null | tr -cd '0-9')"
  [ -n "$_j" ] && [ "$_j" -ge 1 ] 2>/dev/null && HASHER_JOBS="$_j"
fi
export HASHER_JOBS

# FIX (v1.1.9): source the host-detection helper so the launcher and
# everything it spawns can apply host-appropriate defaults (excludes,
# quarantine roots, scan fallbacks). The lib is POSIX-sh-safe so
# sourcing under bash 3.2 is fine.
if [ -r "$LIB_DIR/host-detect.sh" ]; then
  . "$LIB_DIR/host-detect.sh"
  detect_host
fi

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

# v1.3.2: tolerate helper scripts that arrived without the executable bit.
# Some users install via the GitHub web UI / zip upload, which does not
# preserve the +x bit, and cannot easily chmod on the NAS. Previously the
# launcher hard-failed ("not found or not executable") when a needed helper
# lacked +x — breaking folder review and auto-dedup on such installs.
# script_runnable: true if the script can be run either directly (+x) or via bash.
script_runnable() {
  [ -x "$1" ] || [ -r "$1" ]
}
# run_script: execute a helper, preferring direct execution; if it is readable
# but not executable, fall back to running it through bash so a missing +x bit
# is not fatal. (Best-effort chmod first, in case the filesystem allows it.)
run_script() {
  local s="$1"; shift
  if [ ! -x "$s" ] && [ -r "$s" ]; then
    chmod +x "$s" 2>/dev/null || true   # may fail on some mounts; harmless
  fi
  if [ -x "$s" ]; then
    "$s" "$@"
  elif [ -r "$s" ]; then
    bash "$s" "$@"
  else
    return 127
  fi
}

header() {
  printf "%s" "$MAG"
  printf "%s\n" " _   _           _               "
  printf "%s\n" "| | | | __ _ ___| |__   ___ _ __ "
  printf "%s\n" "| |_| |/ _' / __| '_ \ / _ \ '__|"
  printf "%s\n" "|  _  | (_| \__ \ | | |  __/ |   "
  printf "%s\n" "|_| |_|\__,_|___/_| |_|\___|_|   "
  printf "\n%s\n" "      NAS File Hasher & Dedupe"
  printf "\n%s\n" "      v1.3.2 - June 2026. James Wintermute"
  # FIX (v1.1.9): show the detected host class so the user sees at a
  # glance which set of host-aware defaults will apply.
  if command -v host_pretty_label >/dev/null 2>&1; then
    printf "%s\n" "      Host: $(host_pretty_label)"
  fi
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
  echo "${BOLD}Stage 1 — Hash${RST}"
  echo "   1) Start hashing (NAS-safe defaults)"
  echo "   a) Advanced / custom hashing"
  echo "   s) Hashing status"
  echo "   p) Performance settings (parallel hashing)"
  echo
  echo "${BOLD}Stage 2 — Identify${RST}"
  echo "   2) Find duplicate files"
  echo "   3) Find duplicate folders"
  echo "   f) Find file by hash (lookup)"
  echo
  echo "${BOLD}Stage 3 — Review & clean${RST}"
  echo "   4) Review duplicate FILES (interactive)"
  echo "   r) Review duplicate FOLDERS plan (interactive)"
  echo "   5) Auto-dedup (keep shortest path — no prompts)"
  echo "   6) Apply dedup plan (FILE or FOLDER)"
  echo "   7) Delete zero-length files"
  echo "   8) Delete junk (uses local/junk-extensions.txt)"
  echo "   9) Clean cache files & @eaDir (safe)"
  echo
  echo "${BOLD}Other${RST}"
  echo "   d) System diagnostics (deps & readiness)"
  echo "   l) Follow logs (tail -f background.log)"
  echo "   t) Stats & scheduling hints"
  echo "   v) Clean internal working files (var/)"
  echo "   c) Clean logs (rotate & prune)"
  echo
  echo "   q) Quit"
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

  # FIX (v1.1.9): host-aware default excludes instead of a fixed
  # Synology-only set. host_default_excludes() returns one pattern per
  # line, including OS-specific noise dirs (Spotlight/.fseventsd on mac,
  # @eaDir/@tmp on Synology, etc.). Falls back to the legacy hardcoded
  # set if the host-detect lib isn't sourced for any reason.
  if command -v host_default_excludes >/dev/null 2>&1; then
    while IFS= read -r pat; do
      [ -n "$pat" ] && set -- "$@" --exclude "$pat"
    done <<EOF
$(host_default_excludes)
EOF
  else
    set -- "$@" --exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"
  fi

  info "Starting hasher: $script (nohup to $BACKGROUND_LOG)"
  # v1.2.0: pass parallel-jobs setting if configured
  if [ -n "${HASHER_JOBS:-}" ] && [ "${HASHER_JOBS:-1}" -gt 1 ] 2>/dev/null; then
    set -- "$@" --jobs "$HASHER_JOBS"
    info "Parallel hashing: $HASHER_JOBS workers."
  fi
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
  # FIX (v1.1.10): the previous check was 'tail -n 5 | grep Run-ID:'.
  # On a fast/zero-file run (e.g. external disk not mounted, missing path)
  # hasher.sh completes in well under a second; by the time we tail, the
  # log has scrolled past Run-ID into the recommended-next-steps block,
  # the grep fails, and the launcher warns "Hasher may not be running"
  # for a process that already finished cleanly. We now look at the whole
  # background log (limited to the last 200 lines), and treat either
  # 'Run-ID:' (still running) OR 'Run complete' / 'Hashed' (already done)
  # as success. We also detect the new "all paths missing" exit and
  # surface it as a hard error rather than a confusing warning.
  if tail -n 200 "$BACKGROUND_LOG" 2>/dev/null \
       | grep -qE 'Run-ID:|Run complete|Hashed [0-9]+/[0-9]+ files'; then
    if tail -n 200 "$BACKGROUND_LOG" 2>/dev/null \
         | grep -qE 'are missing or unreadable|No input paths provided'; then
      err "Hasher exited with a path error. Recent log:"
      tail -n 30 "$BACKGROUND_LOG" 2>/dev/null || true
      err "Edit local/paths.txt and confirm those paths exist before retrying."
      clear_pidfile
    elif tail -n 200 "$BACKGROUND_LOG" 2>/dev/null \
           | grep -qE 'Hashed 0/0 files'; then
      warn "Hasher completed but processed 0 files. Recent log:"
      tail -n 20 "$BACKGROUND_LOG" 2>/dev/null || true
      warn "Common causes: paths.txt empty, all paths excluded, or disk not mounted."
      clear_pidfile
    else
      next "Hasher launched (PID $bgpid)."
    fi
  else
    warn "Hasher may not be running. Recent log:"
    tail -n 60 "$BACKGROUND_LOG" 2>/dev/null || true
    clear_pidfile
  fi
  info "While it runs, use option 'l' to watch logs. Path: $BACKGROUND_LOG"
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

  # FIX (v1.1.9): host-aware default excludes (see run_hasher_nohup).
  if command -v host_default_excludes >/dev/null 2>&1; then
    while IFS= read -r pat; do
      [ -n "$pat" ] && set -- "$@" --exclude "$pat"
    done <<EOF
$(host_default_excludes)
EOF
  else
    set -- "$@" --exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"
  fi

  info "Running hasher interactively: $script"
  # v1.2.0: pass parallel-jobs setting if configured
  if [ -n "${HASHER_JOBS:-}" ] && [ "${HASHER_JOBS:-1}" -gt 1 ] 2>/dev/null; then
    set -- "$@" --jobs "$HASHER_JOBS"
    info "Parallel hashing: $HASHER_JOBS workers."
  fi
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

# v1.2.0: performance settings — parallel hashing worker count
action_performance_settings(){
  # Detect a sensible recommended value: cores capped at 4
  cores=1
  if command -v nproc >/dev/null 2>&1; then
    cores="$(nproc 2>/dev/null || echo 1)"
  elif command -v sysctl >/dev/null 2>&1; then
    cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  fi
  case "$cores" in ''|*[!0-9]*) cores=1 ;; esac
  recommended="$cores"
  [ "$recommended" -gt 4 ] && recommended=4

  echo
  echo "${BOLD}Performance — parallel hashing${RST}"
  echo
  echo "Hashing can run multiple workers in parallel. More workers speed up"
  echo "large runs on multi-core systems and SSD / SHR arrays. On a single"
  echo "spinning HDD, too many workers cause seek thrashing — keep it low (1-2)."
  echo
  echo "  Detected CPU cores : $cores"
  echo "  Recommended (safe) : $recommended"
  echo "  Current setting    : $HASHER_JOBS worker(s)$([ "$HASHER_JOBS" -eq 1 ] && echo '  (serial)')"
  echo
  echo "  1) Serial (1 worker)        — safest, original behaviour"
  echo "  2) Recommended ($recommended workers) — balanced default for most NAS units"
  echo "  3) Aggressive ($cores workers)        — full cores; SSD/SHD arrays only"
  echo "  4) Custom value"
  echo "  q) Back (no change)"
  echo
  printf "Choice: "
  read -r pc || pc="q"
  case "$pc" in
    1) HASHER_JOBS=1 ;;
    2) HASHER_JOBS="$recommended" ;;
    3) HASHER_JOBS="$cores" ;;
    4)
      printf "Enter worker count (1-%s): " "$cores"
      read -r cv || cv=""
      cv="$(printf '%s' "$cv" | tr -cd '0-9')"
      if [ -n "$cv" ] && [ "$cv" -ge 1 ] 2>/dev/null; then
        HASHER_JOBS="$cv"
        if [ "$cv" -gt "$cores" ]; then
          warn "Set to $cv, above the $cores detected cores — workers will contend for CPU."
        fi
      else
        warn "Invalid value; keeping $HASHER_JOBS."
      fi
      ;;
    *) info "No change."; printf "Press Enter to continue... "; read -r _ || true; return ;;
  esac

  # Persist
  printf '%s\n' "$HASHER_JOBS" > "$HASHER_JOBS_FILE" 2>/dev/null || true
  export HASHER_JOBS
  info "Parallel hashing set to $HASHER_JOBS worker(s). Saved."
  printf "Press Enter to continue... "; read -r _ || true
}

# ── First-run guided setup (v1.3.0) ──────────────────────────────────────────
# Detection: presence of the sentinel file local/.setup-complete. Absent means
# this is the first launch on this install. The sentinel is written when setup
# finishes OR is skipped, so the prompt never appears again (first launch only,
# never on upgrade). Reaching every step manually via the menu is always
# possible; this flow just guides a new user through the sensible starting
# points so they aren't dropped cold into the full menu.

SETUP_SENTINEL="$LOCAL_DIR/.setup-complete"

is_first_run() {
  [ ! -f "$SETUP_SENTINEL" ]
}

mark_setup_complete() {
  mkdir -p "$LOCAL_DIR" 2>/dev/null || true
  {
    printf '# Hasher setup completed/skipped on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# Delete this file to see the first-run guided setup again.\n'
  } > "$SETUP_SENTINEL" 2>/dev/null || true
}

# Step: pick a parallel-jobs value (shared logic with action_performance_settings,
# but inline here so the first-run flow reads as one continuous guided sequence).
firstrun_performance() {
  cores=1
  if command -v nproc >/dev/null 2>&1; then
    cores="$(nproc 2>/dev/null || echo 1)"
  elif command -v sysctl >/dev/null 2>&1; then
    cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  fi
  case "$cores" in ''|*[!0-9]*) cores=1 ;; esac
  recommended="$cores"; [ "$recommended" -gt 4 ] && recommended=4

  echo
  echo "${BOLD}Step 2 of 4 — Performance (parallel hashing)${RST}"
  echo
  echo "Hashing can use multiple workers in parallel. More workers are faster"
  echo "on multi-core systems with SSD or SHR/RAID storage. On a single spinning"
  echo "HDD, keep this low (1-2) — too many workers cause seek thrashing."
  echo
  echo "  Detected CPU cores : $cores"
  echo
  echo "  1) Serial (1 worker)         — safest"
  echo "  2) Recommended ($recommended worker(s))  — good default for most NAS units"
  echo "  3) Aggressive ($cores worker(s))   — SSD/SHR arrays only"
  echo "  s) Skip (leave at current: $HASHER_JOBS)"
  echo
  printf "Choice [2]: "
  read -r pc || pc="2"
  [ -z "$pc" ] && pc="2"
  case "$pc" in
    1) HASHER_JOBS=1 ;;
    2) HASHER_JOBS="$recommended" ;;
    3) HASHER_JOBS="$cores" ;;
    s|S) info "Skipped — performance left at $HASHER_JOBS."; return ;;
    *) info "Unrecognised; using recommended ($recommended)."; HASHER_JOBS="$recommended" ;;
  esac
  printf '%s\n' "$HASHER_JOBS" > "$HASHER_JOBS_FILE" 2>/dev/null || true
  export HASHER_JOBS
  info "Parallel hashing set to $HASHER_JOBS worker(s)."
}

# Step: ensure paths.txt has at least one real scan root.
firstrun_paths() {
  echo
  echo "${BOLD}Step 3 of 4 — Scan paths${RST}"
  echo
  pfile="$(determine_paths_file)"
  # "configured" = a paths file exists with at least one non-comment, non-blank line
  configured=0
  if [ -n "$pfile" ]; then
    if grep -vE '^[[:space:]]*(#|$)' "$pfile" >/dev/null 2>&1; then configured=1; fi
  fi

  if [ "$configured" -eq 1 ]; then
    info "Scan paths already configured in: $pfile"
    grep -vE '^[[:space:]]*(#|$)' "$pfile" | sed 's/^/    /'
    info "Edit that file any time to change what gets scanned."
    return
  fi

  echo "Hasher needs at least one directory to scan. None is configured yet."
  echo "You can add one now, or skip and edit local/paths.txt yourself later."
  echo
  printf "Enter a directory to scan (absolute path), or leave blank to skip: "
  read -r p || p=""
  p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -z "$p" ]; then
    warn "Skipped. Add paths to local/paths.txt before hashing (menu option 1 will warn if empty)."
    return
  fi
  if [ ! -d "$p" ]; then
    warn "That path does not exist or is not a directory: $p"
    warn "Not added. You can add it later in local/paths.txt once it's available."
    return
  fi
  mkdir -p "$LOCAL_DIR" 2>/dev/null || true
  # Preserve any template header if the file exists; just append the real path.
  printf '%s\n' "$p" >> "$LOCAL_DIR/paths.txt"
  info "Added to local/paths.txt: $p"
  info "Add more any time by editing that file (one path per line)."
}

# Step: confirm where quarantine will live (read-only; reassurance, not a change).
firstrun_quarantine() {
  echo
  echo "${BOLD}Step 4 of 4 — Quarantine location${RST}"
  echo
  qroot=""
  if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
    # shellcheck disable=SC1090
    . "$ROOT_DIR/lib/host-detect.sh"
    qroot="$(default_quarantine_root 2>/dev/null || true)"
  fi
  [ -z "$qroot" ] && qroot="$ROOT_DIR/quarantine-$(date +%F)"
  echo "When you remove duplicates or junk, Hasher MOVES them to quarantine"
  echo "(it never deletes outright — quarantine is recoverable). On this install,"
  echo "quarantine will be created beside the tool, at:"
  echo
  echo "    ${BOLD}$qroot${RST}"
  echo
  echo "To use a different location, set QUARANTINE_DIR in local/hasher.conf."
  info "Nothing to do here — just so you know where to look."
}

first_run_setup() {
  clear 2>/dev/null || true
  header
  echo "${BOLD}Welcome to Hasher — first-run setup${RST}"
  echo
  echo "This looks like the first launch on this install. I can walk you through"
  echo "a few quick checks to get you ready: dependencies, performance, scan paths,"
  echo "and where quarantine lives. It takes under a minute and everything is"
  echo "skippable. You can also reach all of it later from the menu."
  echo
  printf "Run guided setup now? [Y/n]: "
  read -r ans || ans="y"
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      info "Skipping guided setup. You can run individual checks from the menu"
      info "(d = diagnostics, p = performance). This prompt won't appear again."
      mark_setup_complete
      printf "Press Enter to continue to the menu... "; read -r _ || true
      return
      ;;
  esac

  # Step 1 — dependencies (reuse check-deps.sh)
  echo
  echo "${BOLD}Step 1 of 4 — Dependencies & readiness${RST}"
  echo
  if [ -x "$BIN_DIR/check-deps.sh" ]; then
    "$BIN_DIR/check-deps.sh" || true
    echo
    # offer --fix if it looks like a hash tool may be missing
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
      warn "No sha256 tool detected."
      printf "Attempt to create OpenSSL-based shims now? [y/N]: "
      read -r fixit || fixit="n"
      case "$(printf '%s' "$fixit" | tr '[:upper:]' '[:lower:]')" in
        y|yes) "$BIN_DIR/check-deps.sh" --fix || true ;;
      esac
    fi
  else
    warn "check-deps.sh not found — skipping dependency check."
  fi
  printf "Press Enter for the next step... "; read -r _ || true

  # Step 2 — performance
  firstrun_performance
  printf "Press Enter for the next step... "; read -r _ || true

  # Step 3 — paths
  firstrun_paths
  printf "Press Enter for the next step... "; read -r _ || true

  # Step 4 — quarantine
  firstrun_quarantine
  echo
  echo "${BOLD}Setup complete.${RST} You're ready to hash (menu option 1)."
  mark_setup_complete
  printf "Press Enter to continue to the menu... "; read -r _ || true
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
  groups="$(ls -1t "$LOGS_DIR"/duplicate-folders-groups-*.tsv 2>/dev/null | head -n1 || true)"
  if [ -n "$plan" ]; then
    info "Plan saved to: $plan"
    [ -n "$groups" ] && info "Group context: $groups"
    echo
    # NEW (v1.1.13): offer to launch the interactive reviewer immediately
    if [ -n "$groups" ] && script_runnable "$BIN_DIR/review-folder-plan.sh"; then
      printf "Review this plan interactively now? [Y/n]: "
      read -r ans || ans="y"
      case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
        ""|y|yes)
          run_script "$BIN_DIR/review-folder-plan.sh" --groups "$groups" --plan "$plan" || true
          ;;
        *)
          info "OK — review later with menu option 'r', or apply raw plan via option 6."
          ;;
      esac
    else
      info "Review later with menu option 'r', or apply raw plan via option 6."
    fi
  else
    info "No folder plan found to suggest next steps."
  fi
  printf "Press Enter to continue... "; read -r _ || true
}

# NEW (v1.1.13): interactive reviewer for the folder-dedup plan
action_review_folder_plan(){
  groups="$(ls -1t "$LOGS_DIR"/duplicate-folders-groups-*.tsv 2>/dev/null | head -n1 || true)"
  if [ -z "$groups" ]; then
    err "No folder groups TSV found. Run option 3 (Find duplicate folders) first."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi
  if ! script_runnable "$BIN_DIR/review-folder-plan.sh"; then
    err "$BIN_DIR/review-folder-plan.sh not found or not readable."
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi
  plan="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
  run_script "$BIN_DIR/review-folder-plan.sh" --groups "$groups" ${plan:+--plan "$plan"} || true
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
  # Collect latest plan of each type: review-duplicates, auto-dedup, folder
  review_plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  auto_plan="$(ls -1t "$LOGS_DIR"/auto-dedup-plan-*.txt 2>/dev/null | head -n1 || true)"

  # NEW (v1.1.13): for folder plans, prefer reviewed plans over raw ones.
  # The reviewer writes duplicate-folders-plan-reviewed-DATETIME.txt; the
  # finder writes duplicate-folders-plan-DATE.txt. Both match the same
  # broad glob, so we split them and pick the reviewed one when present,
  # warning the user if they're about to apply a raw plan that has no
  # reviewed sibling.
  folder_plan_reviewed="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-reviewed-*.txt 2>/dev/null | head -n1 || true)"
  folder_plan_raw="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-[0-9]*.txt 2>/dev/null | head -n1 || true)"

  folder_plan=""; _folder_src=""
  if [ -n "$folder_plan_reviewed" ]; then
    folder_plan="$folder_plan_reviewed"
    _folder_src="reviewed"
  elif [ -n "$folder_plan_raw" ]; then
    folder_plan="$folder_plan_raw"
    _folder_src="raw (unreviewed)"
  fi

  # Use the newest file plan between review and auto-dedup
  file_plan=""; _plan_src=""
  if [ -n "$review_plan" ] && [ -n "$auto_plan" ]; then
    if [ "$review_plan" -nt "$auto_plan" ]; then
      file_plan="$review_plan"; _plan_src="interactive review"
    else
      file_plan="$auto_plan"; _plan_src="auto-dedup"
    fi
  elif [ -n "$review_plan" ]; then
    file_plan="$review_plan"; _plan_src="interactive review"
  elif [ -n "$auto_plan" ]; then
    file_plan="$auto_plan"; _plan_src="auto-dedup"
  fi

  has_file=0; has_folder=0
  [ -n "$file_plan" ]   && has_file=1
  [ -n "$folder_plan" ] && has_folder=1

  if [ "$has_file" -eq 0 ] && [ "$has_folder" -eq 0 ]; then
    info "No plan found. Generate one first:"
    info "  - File dedup: option 2 (find duplicate files), then option 4 (review) or 5 (auto-dedup)"
    info "  - Folder dedup: option 3 (find duplicate folders), then option 'r' (review)"
    printf "Press Enter to continue... "; read -r _ || true
    return
  fi

  echo
  if [ "$has_file" -eq 1 ]; then
    info "Latest FILE dedupe plan ($_plan_src):"
    info "  $file_plan"
  else
    info "No file dedupe plan found."
  fi
  if [ "$has_folder" -eq 1 ]; then
    info "Latest FOLDER dedupe plan ($_folder_src):"
    info "  $folder_plan"
    # NEW (v1.1.13): warn if folder plan is unreviewed
    if [ "$_folder_src" = "raw (unreviewed)" ]; then
      warn "This folder plan has NOT been interactively reviewed."
      warn "Consider running menu option 'r' first to review each group before applying."
    fi
  else
    info "No folder dedupe plan found."
  fi

  echo
  echo "Which plan do you want to apply?"
  [ "$has_file"   -eq 1 ] && echo "  f) Apply FILE plan   ($_plan_src)"
  [ "$has_folder" -eq 1 ] && echo "  d) Apply FOLDER plan ($_folder_src)"
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
      # NEW (v1.1.13): extra confirmation when applying an unreviewed plan
      if [ "$_folder_src" = "raw (unreviewed)" ]; then
        warn "About to apply an UNREVIEWED folder plan."
        printf "Proceed without review? [y/N]: "
        read -r confirm || confirm="n"
        case "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" in
          y|yes) : ;;
          *) info "Cancelled. Run menu option 'r' to review first."
             printf "Press Enter to continue... "; read -r _ || true; return ;;
        esac
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
  # FIX (v1.1.9): host-aware default scan root instead of hardcoded /volume1
  if command -v host_default_scan_root >/dev/null 2>&1; then
    default_root="$(host_default_scan_root)"
  else
    default_root="/volume1"
  fi
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
  if ! script_runnable "$BIN_DIR/auto-dedup.sh"; then
    err "$BIN_DIR/auto-dedup.sh not found or not readable."
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

  run_script "$BIN_DIR/auto-dedup.sh" --keep "$KEEP" || true

  # Offer to apply the plan immediately
  echo
  plan_file="$(ls -1t "$LOGS_DIR"/auto-dedup-plan-*.txt 2>/dev/null | head -n1 || true)"
  if [ -n "$plan_file" ] && [ -s "$plan_file" ]; then
    del_count="$(grep -c '^DEL|' "$plan_file" 2>/dev/null || echo 0)"
    echo "Plan contains $del_count file(s) marked for quarantine."
    printf "Apply this plan now? [y/N] "
    read -r _apply || _apply="n"
    case "$(printf '%s' "$_apply" | tr '[:upper:]' '[:lower:]')" in
      y|yes)
        info "Applying plan: $plan_file"
        if [ -x "$BIN_DIR/delete-duplicates.sh" ]; then
          "$BIN_DIR/delete-duplicates.sh" "$plan_file" || true
        else
          err "$BIN_DIR/delete-duplicates.sh not found or not executable."
        fi
        ;;
      *)
        info "Plan not applied. Use option 6 to apply when ready."
        ;;
    esac
  fi

  printf "Press Enter to continue... "; read -r _ || true
}

# ── First-run guided setup (v1.3.0) ──────────────────────────────────────────
# Runs once on the first launch of a new install (sentinel: local/.setup-complete).
if is_first_run; then
  first_run_setup
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
while :; do
  clear 2>/dev/null || true
  header
  print_menu
  read -r choice || { echo; exit 0; }

  case "${choice:-}" in
    # ── Stage 1: Hash ─────────────────────────────────────────────────────
    1)       action_start_hashing ;;
    a|A)     action_custom_hashing ;;
    s|S)     action_check_status ;;
    p|P)     action_performance_settings ;;

    # ── Stage 2: Identify ─────────────────────────────────────────────────
    2)       action_find_duplicate_files ;;
    3)       action_find_duplicate_folders ;;
    f|F)     action_find_by_hash ;;

    # ── Stage 3: Review & clean ───────────────────────────────────────────
    4)       action_review_duplicates ;;
    r|R)     action_review_folder_plan ;;
    5)       action_auto_dedup ;;
    6)       action_apply_plan ;;
    7)       action_delete_zero_length ;;
    8)       action_delete_junk ;;
    9)       action_clean_caches ;;

    # ── Other ─────────────────────────────────────────────────────────────
    d|D)     action_system_check ;;
    l|L)     action_view_logs_follow ;;
    t|T)     action_stats_and_cron ;;
    v|V)     action_clean_internal ;;
    c|C)     action_clean_logs ;;

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
