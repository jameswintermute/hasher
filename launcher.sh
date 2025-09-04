#!/usr/bin/env bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"; export PATH="$SCRIPT_DIR:$SCRIPT_DIR/bin:$PATH"
# launcher.sh — menu launcher for Hasher & Dedupe toolkit
# License: GPLv3

set -Eeuo pipefail
IFS=$'\n\t'

# ────────────────────────────── Globals ──────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

LOGS_DIR="$ROOT_DIR/logs"
HASHES_DIR="$ROOT_DIR/hashes"
BACKGROUND_LOG="$LOGS_DIR/background.log"

mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$ROOT_DIR/local"

is_tty() { [[ -t 1 ]]; }
if is_tty; then
  C_GRN="\033[0;32m"; C_YLW="\033[1;33m"; C_RED="\033[0;31m"; C_CYN="\033[0;36m"; C_MGN="\033[0;35m"; C_BLU="\033[0;34m"; C_RST="\033[0m"
else
  C_GRN=""; C_YLW=""; C_RED=""; C_CYN=""; C_MGN=""; C_BLU=""; C_RST=""
fi

pause() { read -r -p "Press Enter to return to the menu..." _; }
exists() { [[ -f "$1" ]]; }
have() { command -v "$1" >/dev/null 2>&1; }

# ─────────────────────── path file resolution ────────────────────────
_paths_file() {
  # Prefer local/paths.txt, else legacy ./paths.txt. Create local if none.
  if [[ -f "$ROOT_DIR/local/paths.txt" ]]; then
    echo "$ROOT_DIR/local/paths.txt"; return 0
  fi
  if [[ -f "$ROOT_DIR/paths.txt" ]]; then
    echo "$ROOT_DIR/paths.txt"; return 0
  fi
  mkdir -p "$ROOT_DIR/local"
  : > "$ROOT_DIR/local/paths.txt"
  echo "$ROOT_DIR/local/paths.txt"
}

# ────────────────────────────── Banner ───────────────────────────────
banner() {
  clear 2>/dev/null || true
  cat <<'EOF'

 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      File System and NAS Integrity Hasher & Dedupe

EOF
}

# ─────────────────────────── Helper funcs ────────────────────────────
latest_csv() {
  # Prefer explicit latest.csv if present; else newest hasher-*.csv
  if [[ -f "$HASHES_DIR/latest.csv" ]]; then
    echo "$HASHES_DIR/latest.csv"
    return 0
  fi
  local newest
  newest="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
  if [[ -n "$newest" && -f "$newest" ]]; then
    echo "$newest"
    return 0
  fi
  return 1
}

_when_from_now() {
  local add="$1"
  if date -d "@$(( $(date +%s) + add ))" "+%H:%M:%S %Z" >/dev/null 2>&1; then
    date -d "@$(( $(date +%s) + add ))" "+%H:%M:%S %Z"
  elif date -r "$(( $(date +%s) + add ))" "+%H:%M:%S %Z" >/dev/null 2>&1; then
    date -r "$(( $(date +%s) + add ))" "+%H:%M:%S %Z"
  else
    echo "unknown"
  fi
}

status_summary() {
  echo -e "${C_CYN}### Hashing status ###${C_RST}"
  if [[ -f "$BACKGROUND_LOG" ]]; then
    echo "- Log: $BACKGROUND_LOG"
    echo "- Recent progress:"
    if grep -q "\[PROGRESS\]" "$BACKGROUND_LOG"; then
      grep "\[PROGRESS\]" "$BACKGROUND_LOG" | tail -n 12
    else
      tail -n 12 "$BACKGROUND_LOG"
    fi
  else
    echo "No background log found at $BACKGROUND_LOG"
  fi

  echo
  local csv; if csv="$(latest_csv)"; then
    local rows; rows="$(wc -l <"$csv" | tr -d ' ')" || rows="unknown"
    echo -e "${C_CYN}### Latest CSV ###${C_RST}"
    echo "File: $csv"
    echo "Rows (incl. header): $rows"
  else
    echo -e "${C_YLW}No CSV files found in $HASHES_DIR yet.${C_RST}"
  fi

  if [[ -f "$BACKGROUND_LOG" ]] && grep -q "\[PROGRESS\]" "$BACKGROUND_LOG"; then
    local last pct cur total eta h m s secs finish
    last="$(grep "\[PROGRESS\]" "$BACKGROUND_LOG" | tail -n 1)"
    pct="$(sed -n 's/.*Hashing: \[\([0-9]\+\)%\].*/\1/p' <<<"$last" || true)"
    cur="$(sed -n 's/.*] \([0-9]\+\)\/[0-9]\+.*/\1/p' <<<"$last" || true)"
    total="$(sed -n 's/.*] [0-9]\+\/\([0-9]\+\).*/\1/p' <<<"$last" || true)"
    eta="$(sed -n 's/.* eta=\([0-9:]\+\).*/\1/p' <<<"$last" || true)"
    if [[ -n "$eta" ]]; then
      IFS=':' read -r h m s <<< "$eta"
      secs=$((10#$h*3600 + 10#$m*60 + 10#$s))
      finish="$(_when_from_now "$secs")"
      if [[ -n "$pct" && -n "$finish" ]]; then
        echo
        echo "Summary: ${pct}% complete • ETA ~${eta} (≈ ${finish})"
      fi
    fi
  fi
}

start_hashing_defaults() {
  echo -e "${C_CYN}Starting hashing (NAS-safe defaults)…${C_RST}"
  local args=(--algo sha256 --nohup)
  local pf; pf="$(_paths_file)"
  if [[ -s "$pf" ]]; then
    args+=(--pathfile "$pf")
    echo "Using pathfile: $pf"
  else
    echo -e "${C_YLW}No paths found. Use menu option 6 to add paths before hashing.${C_RST}"
  fi
  echo "Command: \"$SCRIPT_DIR/bin/hasher.sh\" ${args[*]}"
  echo
  "$SCRIPT_DIR/bin/hasher.sh" "${args[@]}" || {
    echo -e "${C_RED}hasher.sh failed. See logs for details.${C_RST}"
    return 1
  }
}

advanced_hashing() {
  echo -e "${C_CYN}Advanced / Custom hashing${C_RST}"
  echo "Enter additional flags for hasher.sh (example: --pathfile local/paths.txt --algo sha256 --nohup)"
  echo "Leave empty to cancel."
  printf "hasher.sh "
  read -r extra || true
  [[ -z "${extra:-}" ]] && { echo "Cancelled."; return 0; }
  "$SCRIPT_DIR/bin/hasher.sh" $extra
}

configure_paths() {
  echo -e "${C_CYN}Configure paths to hash (paths.txt)${C_RST}"
  local pf legacy
  legacy="$ROOT_DIR/paths.txt"
  pf="$(_paths_file)"
  if [[ "$pf" == "$legacy" ]]; then
    echo -e "${C_YLW}Using legacy paths file: $legacy${C_RST}"
    echo -e "${C_YLW}Tip:${C_RST} Create and use ${C_BLU}local/paths.txt${C_RST} for per-host config."
  else
    echo "Paths file: $pf"
  fi
  touch "$pf"
  while true; do
    echo
    echo "Current entries:"
    nl -ba "$pf" | sed 's/^/  /' || true
    echo
    echo "a) Add path"
    echo "r) Remove by number (comma or space separated)"
    echo "c) Clear all"
    echo "t) Test scan (count files quickly)"
    echo "m) Migrate legacy ./paths.txt -> local/paths.txt"
    echo "b) Back"
    read -r -p "Choose: " act
    case "${act:-}" in
      a|A)
        read -r -p "Enter absolute path to add: " p
        [[ -z "${p:-}" ]] && continue
        printf '%s\n' "$p" >> "$pf"
        echo "Added."
        ;;
      r|R)
        read -r -p "Enter number(s) to remove: " nums
        [[ -z "${nums:-}" ]] && continue
        tmp="$(mktemp)"; nl -ba "$pf" > "$tmp" || true
        awk -v list="$nums" '
          BEGIN{ n=split(list, arr, /[ ,]+/); for(i=1;i<=n;i++) del[arr[i]]=1 }
          { if (!($1 in del)) { $1=""; sub(/^[ \t]+/,""); print } }
        ' "$tmp" > "$pf.new" || true
        mv -f "$pf.new" "$pf"
        rm -f "$tmp"
        echo "Updated."
        ;;
      c|C)
        : > "$pf"; echo "Cleared."
        ;;
      t|T)
        echo "Counting files under listed paths (quick scan)…"
        total=0
        while IFS= read -r line || [[ -n "$line" ]]; do
          [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
          if [[ -d "$line" ]]; then
            cnt="$(find "$line" -type f -print 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
            printf '  %s : %s files\n' "$line" "$cnt"
            total=$(( total + cnt ))
          elif [[ -f "$line" ]]; then
            printf '  %s : 1 file\n' "$line"
            total=$(( total + 1  ))
          else
            printf '  %s : (missing)\n' "$line"
          fi
        done < "$pf"
        echo "Total files (approx): $total"
        ;;
      m|M)
        if [[ -f "$legacy" ]]; then
          mkdir -p "$ROOT_DIR/local"
          cat "$legacy" >> "$ROOT_DIR/local/paths.txt"
          pf="$ROOT_DIR/local/paths.txt"
          echo "Migrated entries to $pf"
        else
          echo "Legacy ./paths.txt not found."
        fi
        ;;
      b|B) return 0 ;;
      *) echo "Unknown option." ;;
    esac
  done
}

run_find_duplicates() {
  echo -e "${C_CYN}Running find-duplicates…${C_RST}"
  local in outdir ts
  ts="$(date +'%Y-%m-%d-%H%M%S')"
  outdir="$LOGS_DIR/du-$ts"
  mkdir -p "$outdir"

  if in="$(latest_csv)"; then
    echo "Input CSV: $in"
  else
    echo -e "${C_RED}No input CSV found. Run hashing first.${C_RST}"
    return 1
  fi

  local cmd=("$SCRIPT_DIR/bin/find-duplicates.sh" --csv "$in" --out "$outdir")
  if have ionice; then cmd=(ionice -c3 nice -n 19 "${cmd[@]}"); fi

  echo "Command: ${cmd[*]}"
  ${cmd[@]} || {
    echo -e "${C_RED}find-duplicates.sh failed.${C_RST}"
    return 1
  }

  echo
  echo "Outputs (if script succeeded):"
  for f in "$outdir"/duplicates.csv "$outdir"/groups.summary.txt "$outdir"/top-groups.txt "$outdir"/reclaimable.txt "$outdir"/duplicates.txt; do
    [[ -f "$f" ]] && echo " - $f"
  done
}

run_review_duplicates() {
  echo -e "${C_CYN}Review duplicates (interactive)…${C_RST}"
  # State file to remember progress
  local state="$LOGS_DIR/review-batch.state"
  local last_skip=0 last_take=100
  if [[ -f "$state" ]]; then
    # shellcheck disable=SC1090
    . "$state" 2>/dev/null || true
    [[ "${SKIP:-}" =~ ^[0-9]+$ ]] && last_skip="$SKIP" || true
    [[ "${TAKE:-}" =~ ^[0-9]+$ ]] && last_take="$TAKE" || true
  fi
  local def_skip=$(( last_skip + last_take ))
  local def_take=100

  read -r -p "How many groups to review this pass? [default ${def_take}]: " take
  take="${take:-$def_take}"
  read -r -p "Skip how many groups (already reviewed)? [default ${def_skip}]: " skip
  skip="${skip:-$def_skip}"

  # Persist chosen values
  printf 'SKIP=%s\nTAKE=%s\n' "$skip" "$take" > "$state"

  local cmd=("$SCRIPT_DIR/bin/review-batch.sh" --skip "$skip" --take "$take" --keep newest)
  echo "Command: ${cmd[*]}"
  "${cmd[@]}" || { echo -e "${C_RED}review-batch.sh failed.${C_RST}"; return 1; }

  local plan
  plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$plan" ]]; then
    echo
    echo "Latest plan: $plan"
    echo "Tip: Dry-run deletion with:"
    echo "  ./bin/delete-duplicates.sh --from-plan \"$plan\""
  fi
}

run_delete_duplicates() {
  echo -e "${C_RED}DANGER ZONE: Execute plan to delete files from duplicate groups.${C_RST}"
  local plan
  plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  if [[ -z "$plan" ]]; then
    echo -e "${C_YLW}No review plan found. Run option 3 (Review duplicates) first.${C_RST}"
    return 1
  fi
  echo "Using plan: $plan"
  read -r -p "Type 'DELETE' to proceed (dry-run otherwise): " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    echo "Dry-run…"
    "$SCRIPT_DIR/bin/delete-duplicates.sh" --from-plan "$plan" || true
    return 0
  fi

  echo
  echo "Choose action:"
  echo "  1) Move to quarantine (safer)"
  echo "  2) Permanently delete"
  read -r -p "Select: " mode
  case "${mode:-}" in
    1) "$SCRIPT_DIR/bin/delete-duplicates.sh" --from-plan "$plan" --force --quarantine "quarantine-$(date +%F)" ;;
    2) "$SCRIPT_DIR/bin/delete-duplicates.sh" --from-plan "$plan" --force ;;
    *) echo "Cancelled." ;;
  esac
}

run_delete_junk() {
  echo -e "${C_CYN}Delete junk files (safe flow)…${C_RST}"
  local script="$SCRIPT_DIR/bin/delete-junk.sh"
  if ! [[ -f "$script" ]]; then
    echo -e "${C_YLW}delete-junk.sh not found in bin/.${C_RST}"
    echo "Place it in bin/ and make it executable: chmod +x bin/delete-junk.sh"
    return 0
  fi
  if ! [[ -x "$script" ]]; then
    chmod +x "$script" || true
  fi

  local args=()
  local pf; pf="$(_paths_file)"
  if [[ -s "$pf" ]]; then
    args+=(--paths-file "$pf")
    echo "Using paths file: $pf"
  fi

  local cmd_preview=("$script" "${args[@]}" --dry-run)
  echo
  echo -e "${C_BLU}Preview (no deletions will occur in this step)…${C_RST}"
  echo "Command: ${cmd_preview[*]}"
  echo
  if have ionice; then cmd_preview=(ionice -c3 nice -n 19 "${cmd_preview[@]}"); fi
  ${cmd_preview[@]} || true

  echo
  echo -e "${C_RED}Proceed to ACTUAL deletion?${C_RST}"
  read -r -p "Type 'APPLY' to delete junk files, anything else to cancel: " go
  [[ "$go" != "APPLY" ]] && { echo "Cancelled."; return 0; }

  local cmd_apply=("$script" "${args[@]}" --force)
  echo "Command: ${cmd_apply[*]}"
  if have ionice; then cmd_apply=(ionice -c3 nice -n 19 "${cmd_apply[@]}"); fi
  ${cmd_apply[@]}
}

# Delete zero-length files native flow (no external script required)
run_delete_zero_length() {
  echo -e "${C_CYN}Delete zero-length files (safe flow)…${C_RST}"

  local ts outdir nulfile listfile delog
  ts="$(date +'%Y-%m-%d-%H%M%S')"
  outdir="$LOGS_DIR/zlen-$ts"
  mkdir -p "$outdir"
  nulfile="$outdir/candidates.nul"
  listfile="$outdir/candidates.txt"
  delog="$outdir/deleted.txt"

  local bases=()
  local pf; pf="$(_paths_file)"
  if [[ -s "$pf" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      bases+=("$line")
    done < "$pf"
  fi
  if [[ ${#bases[@]} -eq 0 ]]; then
    bases=("$ROOT_DIR")
    echo -e "${C_YLW}No paths.txt found or it was empty — scanning repo root: $ROOT_DIR${C_RST}"
    echo "Tip: use menu option 6 to add paths for targeted cleanup."
  else
    echo "Scanning base paths from: $pf"
    printf ' - %s\n' "${bases[@]}"
  fi

  echo "Gathering zero-length candidates…"
  : > "$nulfile"
  for base in "${bases[@]}"; do
    find "$base" \
      \( -type d \( -iname '#recycle' -o -name '@eaDir' -o -name '.Trash*' -o -name '.Spotlight-V100' -o -name '.fseventsd' \) -prune \) -o \
      -type f -size 0c -print0 >> "$nulfile" 2>/dev/null || true
  done

  local count
  count="$(tr -cd '\0' < "$nulfile" | wc -c | tr -d ' ')" || count=0
  tr '\0' '\n' < "$nulfile" > "$listfile"

  if [[ "$count" -eq 0 ]]; then
    echo -e "${C_GRN}No zero-length files found. Nice and tidy!${C_RST}"
    echo "Report folder: $outdir"
    return 0
  fi

  echo -e "${C_YLW}Found $count zero-length files.${C_RST}"
  echo "List saved to: $listfile"
  echo
  echo "Sample:"
  head -n 20 "$listfile" || true
  if [[ "$count" -gt 20 ]]; then
    echo "… (see full list above)"
  fi
  echo
  echo -e "${C_RED}Proceed to delete ALL $count zero-length files listed?${C_RST}"
  read -r -p "Type 'APPLY' to delete them, anything else to cancel: " go
  [[ "$go" != "APPLY" ]] && { echo "Cancelled. No files were deleted."; return 0; }

  echo "Deleting…"
  : > "$delog"
  while IFS= read -r -d '' f; do
    if rm -f -- "$f"; then
      printf '%s\n' "$f" >> "$delog"
    fi
  done < "$nulfile"

  local dcount
  dcount="$(wc -l < "$delog" | tr -d ' ')" || dcount=0
  echo -e "${C_GRN}Deleted $dcount zero-length files.${C_RST}"
  echo "Deletion log: $delog"
}

run_system_check() {
  echo -e "${C_CYN}System check (deps & readiness)…${C_RST}"
  if [[ -x "$ROOT_DIR/bin/check-deps.sh" ]]; then
    "$ROOT_DIR/bin/check-deps.sh" --fix || true
  else
    echo -e "${C_YLW}bin/check-deps.sh not found or not executable.${C_RST}"
    echo "Create it from the template shared previously, then mark executable:"
    echo "  mkdir -p bin"
    echo "  chmod +x bin/check-deps.sh"
  fi
}

view_logs() {
  echo -e "${C_CYN}Tail logs/background.log (Ctrl+C to stop)…${C_RST}"
  if [[ -f "$BACKGROUND_LOG" ]]; then
    tail -n 50 -f "$BACKGROUND_LOG"
  else
    echo "No background log at $BACKGROUND_LOG"
  fi
}

# ────────────────────────────── Menu ────────────────────────────────
show_menu() {
  banner
  echo "### Stage 1 - Hash ###"
  echo "  0) Check hashing status"
  echo "  1) Start Hashing (NAS-safe defaults)"
  echo "  8) Advanced / Custom hashing"
  echo
  echo "### Stage 2 - Identify ###"
  echo "  2) Find duplicate hashes"
  echo "  3) Review duplicates (interactive)"
  echo "  d) Delete duplicates (DANGER)"
  echo
  echo "### Stage 3 - Clean up ###"
  echo "  4) Delete junk files"
  echo "  5) Delete zero-length files"
  echo
  echo "### Other ###"
  echo "  6) Configure paths to hash"
  echo "  7) System check (deps & readiness)"
  echo "  9) View logs (tail background.log)"
  echo
  echo "  q) Quit"
  echo
}

main_loop() {
  while true; do
    show_menu
    read -r -p "Select an option: " choice
    case "${choice:-}" in
      0) clear 2>/dev/null || true; status_summary; echo; pause ;;
      1) clear 2>/dev/null || true; start_hashing_defaults; echo; pause ;;
      8) clear 2>/dev/null || true; advanced_hashing; echo; pause ;;
      2) clear 2>/dev/null || true; run_find_duplicates; echo; pause ;;
      3) clear 2>/dev/null || true; run_review_duplicates; echo; pause ;;
      d|D) clear 2>/dev/null || true; run_delete_duplicates; echo; pause ;;
      4) clear 2>/dev/null || true; run_delete_junk; echo; pause ;;
      5) clear 2>/dev/null || true; run_delete_zero_length; echo; pause ;;
      6) clear 2>/dev/null || true; configure_paths; echo; pause ;;
      7) clear 2>/dev/null || true; run_system_check; echo; pause ;;
      9) clear 2>/dev/null || true; view_logs ;;
      q|Q) echo "Bye!"; exit 0 ;;
      *) echo -e "${C_YLW}Unknown option: ${choice}. Please try again.${C_RST}" ;;
    esac
  done
}

main_loop
