#!/usr/bin/env bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# launcher.sh — menu launcher for Hasher & Dedupe toolkit

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$ROOT_DIR/logs"
mkdir -p "$LOGS_DIR"

C_YLW="\033[1;33m"; C_RED="\033[0;31m"; C_CYN="\033[0;36m"; C_RST="\033[0m"
SCRIPT_DIR="$ROOT_DIR"
have() { command -v "$1" >/dev/null 2>&1; }

latest_du_outdir() { ls -1dt "$LOGS_DIR"/du-* 2>/dev/null | head -n1 || true; }
latest_du_report() {
  local d; d="$(latest_du_outdir)"
  [[ -n "$d" && -f "$d/duplicates.txt" ]] && echo "$d/duplicates.txt"
}

run_review_duplicates() {
  echo -e "${C_CYN}Review duplicates — choose a mode${C_RST}"

  local report; report="$(latest_du_report || true)"
  if [[ -z "$report" ]]; then
    echo -e "${C_YLW}No duplicate analysis found. Run Option 2 first.${C_RST}"; return 1
  fi
  local outdir="$(dirname "$report")"
  echo "Latest analysis: $outdir"

  local state="$LOGS_DIR/review-batch.state"
  local have_state=false
  if [[ -f "$state" ]]; then
    . "$state" 2>/dev/null || true
    [[ "${SKIP:-}" =~ ^[0-9]+$ ]] && [[ "${TAKE:-}" =~ ^[0-9]+$ ]] && have_state=true
  fi

  echo
  echo "Modes:"
  echo "  1) Standard mode (interactive) — manually choose keep-per-group"
  echo "  2) Bulk mode (auto) — keep 'newest' in the top N biggest groups (no prompts)"
  if $have_state; then
    echo "  3) Resume, last interactive pass (skip=${SKIP:-0}, take=${TAKE:-100})"
  fi
  echo "  b) Back"
  read -r -p "Select [default 1]: " mode

  case "${mode:-1}" in
    1)
      read -r -p "How many groups to review this pass (take)? [default 100]: " take
      take="${take:-100}"
      if [[ "$take" -eq 0 ]]; then echo "Nothing to review (take=0)."; return 0; fi
      read -r -p "Skip how many groups first? [default 0]: " skip; skip="${skip:-0}"
      read -r -p "Default keep policy hint [default newest]: " policy; policy="${policy:-newest}"
      local cmd=("$SCRIPT_DIR/bin/review-duplicates.sh" --from-report "$report" --order size --skip "$skip" --take "$take" --keep "$policy")
      echo "Command: ${cmd[*]}"; "${cmd[@]}" || { echo -e "${C_RED}review-duplicates.sh failed.${C_RST}"; return 1; }
      printf 'SKIP=%s\nTAKE=%s\n' "$skip" "$take" > "$state";;
    2)
      read -r -p "How many groups to process (take)? [default 100]: " take; take="${take:-100}"
      if [[ "$take" -eq 0 ]]; then echo "Nothing to review (take=0)."; return 0; fi
      read -r -p "Skip how many groups first? [default 0]: " skip; skip="${skip:-0}"
      read -r -p "Policy [default newest]: " policy; policy="${policy:-newest}"
      local cmd=("$SCRIPT_DIR/bin/review-duplicates.sh" --from-report "$report" --order size --skip "$skip" --take "$take" --non-interactive --keep "$policy" --quiet)
      echo "Command: ${cmd[*]}"; "${cmd[@]}" || { echo -e "${C_RED}review-duplicates.sh failed.${C_RST}"; return 1; };;
    3)
      if $have_state; then
        read -r -p "Default keep policy hint [default newest]: " policy; policy="${policy:-newest}"
        local cmd=("$SCRIPT_DIR/bin/review-duplicates.sh" --from-report "$report" --order size --skip "${SKIP:-0}" --take "${TAKE:-100}" --keep "$policy")
        echo "Command: ${cmd[*]}"; "${cmd[@]}" || { echo -e "${C_RED}review-duplicates.sh failed.${C_RST}"; return 1; }
      fi;;
    b|B) return 0;;
    *) echo "Unknown option.";; esac

  local plan; plan="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$plan" ]]; then
    echo; echo "Latest plan: $plan"; echo "Tip: Dry-run deletion with:"; echo "  ./bin/delete-duplicates.sh --from-plan \"$plan\""
  fi
}

# rest of launcher.sh omitted for brevity
