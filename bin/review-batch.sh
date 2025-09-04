#!/usr/bin/env bash
# review-window.sh — small wrapper to review a window of duplicate groups
# - Clear prompts, default skip=0, optional auto-resume
# - Calls existing bin/review-batch.sh
# - Adds 2× spacing before/after the batch run for readability

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ─── Layout ───
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$APP_HOME/bin"
LOG_DIR="$APP_HOME/logs"
mkdir -p "$LOG_DIR"

STATE_FILE="$LOG_DIR/review-duplicates.next_skip"  # keep old name for continuity
KEEP="${KEEP:-newest}"                              # newest|oldest|largest|smallest|first|last

# ─── Prompts ───
echo "Review duplicates (interactive)…"

read -r -p "How many groups to review this pass? [default 100]: " TAKE || true
TAKE="${TAKE:-100}"

SUGGESTED=""
if [[ -r "$STATE_FILE" ]]; then
  val="$(tr -cd '0-9' < "$STATE_FILE" || true)"
  if [[ -n "$val" && "$val" -gt 0 ]]; then
    SUGGESTED="$val"
  fi
fi

SKIP_SET=""
if [[ -n "$SUGGESTED" ]]; then
  read -r -p "Resume from last position (~${SUGGESTED} groups already reviewed)? [Y/n]: " RESUME || true
  case "${RESUME,,}" in
    n|no) ;;
    *) SKIP="$SUGGESTED"; SKIP_SET="yes" ;;
  esac
fi

if [[ -z "${SKIP_SET}" ]]; then
  echo "Have you already partially reviewed and would like to skip?"
  read -r -p "Enter how many groups to skip (0 if starting fresh) [default 0]: " SKIP || true
  SKIP="${SKIP:-0}"
fi

# ─── Input hygiene ───
[[ "$TAKE" =~ ^[0-9]+$ ]] || TAKE=100
[[ "$SKIP" =~ ^[0-9]+$ ]] || SKIP=0

# ─── Execute underlying batch reviewer ───
CMD="$BIN_DIR/review-batch.sh --skip \"$SKIP\" --take \"$TAKE\" --keep \"$KEEP\""

echo "Command: $BIN_DIR/review-batch.sh"
echo "--skip"; echo "$SKIP"
echo "--take"; echo "$TAKE"
echo "--keep"; echo "$KEEP"

# Spacing for readability
echo; echo

# shellcheck disable=SC2086
eval "$CMD"

# Spacing after the batch run
echo; echo

# ─── Persist next suggested starting point ───
NEXT=$(( SKIP + TAKE ))
printf "%d\n" "$NEXT" > "$STATE_FILE" || true
