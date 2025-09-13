#!/usr/bin/env bash
# launcher.sh — NAS File Hasher & Dedupe (menu)
# Copyright (C) 2025 James
# GNU GPLv3 — This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ───── Layout ─────
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$SCRIPT_DIR"
BIN_DIR="$APP_HOME/bin"
LOG_DIR="$APP_HOME/logs"
HASHES_DIR="$APP_HOME/hashes"
VAR_DIR="$APP_HOME/var"
LOCAL_DIR="$APP_HOME/local"
DEFAULT_DIR="$APP_HOME/default"
mkdir -p "$BIN_DIR" "$LOG_DIR" "$HASHES_DIR" "$VAR_DIR" "$LOCAL_DIR" "$DEFAULT_DIR"

# ───── Colors ─────
BOLD="\033[1m"; DIM="\033[2m"; RED="\033[31m"; GRN="\033[32m"; YLW="\033[33m"; BLU="\033[34m"; MAG="\033[35m"; CYN="\033[36m"; NC="\033[0m"

# ───── Helpers ─────
pause(){ read -rp "Press Enter to continue…"; }
exists(){ command -v "$1" >/dev/null 2>&1; }
run_or_hint(){
  local path="$1"; shift
  if [ -x "$path" ]; then "$path" "$@"; else
    echo -e "${YLW}[WARN]${NC} Missing helper: ${path}."; return 127
  fi
}

latest_by_pattern(){
  # $1=glob pattern; echoes newest file or blank
  ls -1t $1 2>/dev/null | head -n1 || true
}

latest_duplicate_report(){
  # canonical reports are logs/YYYY-MM-DD-duplicate-hashes.txt
  latest_by_pattern "$LOG_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-duplicate-hashes.txt
}

latest_review_plan(){
  latest_by_pattern "$LOG_DIR"/review-dedupe-plan-*.txt
}

print_header(){
  clear || true
  cat <<'BANNER'

 _   _           _               
| | | | __ _ ___| |__   ___ _ __ 
| |_| |/ _` / __| '_ \ / _ \ '__|
|  _  | (_| \__ \ | | |  __/ |   
|_| |_|\__,_|___/_| |_|\___|_|   

      NAS File Hasher & Dedupe
BANNER
}

# ───── Config read (flat k=v only) ─────
CONF_LOCAL="$LOCAL_DIR/hasher.conf"
CONF_DEFAULT="$DEFAULT_DIR/hasher.conf"
read_kv(){ local f="$1" k="$2"; [ -r "$f" ] && awk -F= -v k="$k" '
  $0 !~ /^[[:space:]]*#/ && $1 ~ k { sub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }' "$f" | tail -n1 || true; }
get_conf(){
  local k="$1" v
  v="$(read_kv "$CONF_LOCAL" "$k")"; [ -n "${v:-}" ] || v="$(read_kv "$CONF_DEFAULT" "$k")"
  echo "$v"
}

CRON_SPEC="$(get_conf CRON_SPEC)"; [ -n "$CRON_SPEC" ] || CRON_SPEC="5 0 * * 0"

# ───── Menu actions ─────

start_hashing_defaults(){
  echo -e "${BLU}[INFO]${NC} Starting hashing with NAS-safe defaults…"
  if [ -r "$LOCAL_DIR/paths.txt" ]; then
    PATHFILE="local/paths.txt"
  elif [ -r "$APP_HOME/paths.txt" ]; then
    PATHFILE="paths.txt"
  elif [ -r "$DEFAULT_DIR/paths.example.txt" ]; then
    PATHFILE="default/paths.example.txt"
    echo -e "${YLW}[WARN]${NC} Using example paths: $PATHFILE — create local/paths.txt for your volumes."
  else
    echo -e "${RED}[ERROR]${NC} No paths file found (local/paths.txt, paths.txt, default/paths.example.txt)."
    pause; return
  fi

  if [ -x "$APP_HOME/hasher.sh" ]; then
    ( cd "$APP_HOME" && ./hasher.sh --pathfile "$PATHFILE" --algo sha256 --nohup )
  else
    echo -e "${RED}[ERROR]${NC} hasher.sh not found/executable."
  fi
  pause
}

start_hashing_advanced(){
  echo -e "${BLU}[INFO]${NC} Advanced hashing options."
  read -rp "Pathfile [local/paths.txt]: " PF; PF="${PF:-local/paths.txt}"
  read -rp "Algorithm (sha256|sha1|sha512|md5|blake2) [sha256]: " ALG; ALG="${ALG:-sha256}"
  read -rp "Run under nohup (y/N)? " YN; case "${YN,,}" in y|yes) NH="--nohup";; *) NH="";; esac
  if [ -x "$APP_HOME/hasher.sh" ]; then
    ( cd "$APP_HOME" && ./hasher.sh --pathfile "$PF" --algo "$ALG" ${NH:-} )
  else
    echo -e "${RED}[ERROR]${NC} hasher.sh not found/executable."
  fi
  pause
}

check_hash_status(){
  echo -e "${BLU}[INFO]${NC} Tail background log (Ctrl+C to stop)…"
  if [ -r "$LOG_DIR/background.log" ]; then
    tail -n 200 -f "$LOG_DIR/background.log" || true
  else
    echo -e "${YLW}[WARN]${NC} No background.log yet."
  fi
  pause
}

identify_duplicates(){
  echo -e "${BLU}[INFO]${NC} Building canonical duplicate report…"
  # Prefer explicit helper; otherwise, fallback to hasher.sh stage if it supports it
  if [ -x "$BIN_DIR/find-duplicates.sh" ]; then
    "$BIN_DIR/find-duplicates.sh"
  elif [ -x "$APP_HOME/hasher.sh" ]; then
    echo -e "${DIM}[INFO] Falling back to hasher.sh --find-duplicates (if supported)…${NC}"
    ( cd "$APP_HOME" && ./hasher.sh --find-duplicates || true )
  else
    echo -e "${RED}[ERROR]${NC} Neither bin/find-duplicates.sh nor hasher.sh present."
  fi
  latest=$(latest_duplicate_report)
  if [ -n "$latest" ]; then
    echo -e "${GRN}[OK]${NC} Report created: $latest"
  else
    echo -e "${YLW}[WARN]${NC} Could not locate a new duplicate report in $LOG_DIR."
  fi
  pause
}

review_duplicates(){
  echo -e "${BLU}[INFO]${NC} Review duplicate groups (interactive)."
  local report default_report slice_skip slice_take keep
  default_report="$(latest_duplicate_report)"
  read -rp "Report file [${default_report:-(none)}]: " report
  report="${report:-$default_report}"
  if [ -z "$report" ] || [ ! -r "$report" ]; then
    echo -e "${RED}[ERROR]${NC} Report not found or unreadable."
    pause; return
  fi
  read -rp "Order (size|count) [size]: " order; order="${order:-size}"
  read -rp "Skip how many groups (0 for start) [0]: " slice_skip; slice_skip="${slice_skip:-0}"
  read -rp "Take how many groups (0=use LIMIT/conf) [100]: " slice_take; slice_take="${slice_take:-100}"
  read -rp "Keep policy (newest|oldest|largest|smallest|first|last) [newest]: " keep; keep="${keep:-newest}"

  local args=( --from-report "$report" --order "$order" --keep "$keep" )
  [ "$slice_skip" != "0" ] && args+=( --skip "$slice_skip" )
  [ "$slice_take" != "0" ] && args+=( --take "$slice_take" )

  run_or_hint "$BIN_DIR/review-duplicates.sh" "${args[@]}"
  echo
  PLAN="$(latest_review_plan)"
  if [ -n "$PLAN" ]; then
    echo -e "${GRN}[OK]${NC} Latest plan: $PLAN"
  else
    echo -e "${YLW}[WARN]${NC} No plan written yet."
  fi
  pause
}

delete_duplicates_menu(){
  echo -e "${BLU}[INFO]${NC} Delete duplicates from a review plan."
  local plan default_plan; default_plan="$(latest_review_plan)"
  read -rp "Plan file [${default_plan:-(none)}]: " plan
  plan="${plan:-$default_plan}"
  if [ -z "$plan" ] || [ ! -r "$plan" ]; then
    echo -e "${RED}[ERROR]${NC} Plan not found or unreadable."
    pause; return
  fi
  echo "1) Dry-run (no changes)"
  echo "
