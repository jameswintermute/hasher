#!/usr/bin/env bash
# Schedule weekly hasher run on Synology/Unix via cron
# Adds a clearly-marked block to /etc/crontab and restarts cron.
# Usage: schedule-hasher.sh enable|disable|show [--spec "5 0 * * 0"]

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOG_DIR="$APP_HOME/logs"
CONF_LOCAL="$APP_HOME/local/hasher.conf"
CONF_DEFAULT="$APP_HOME/default/hasher.conf"
mkdir -p "$LOG_DIR" "$APP_HOME/local"

ACTION="${1:-}"; shift || true
SPEC_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC_OVERRIDE="${2:-}"; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# Read CRON_SPEC from conf (default: Sun 00:05)
CRON_SPEC="5 0 * * 0"
read_kv(){ local f="$1" k="$2"; [ -r "$f" ] && awk -F= -v k="$k" '
  $0 !~ /^[[:space:]]*#/ && $1 ~ k { sub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }' "$f" | tail -n1 || true; }
v="$(read_kv "$CONF_LOCAL" "CRON_SPEC")"; [ -n "${v:-}" ] && CRON_SPEC="$v"
v="$(read_kv "$CONF_DEFAULT" "CRON_SPEC")"; [ -n "${v:-}" ] && CRON_SPEC="$v"
[ -n "$SPEC_OVERRIDE" ] && CRON_SPEC="$SPEC_OVERRIDE"

# Command to execute weekly (NAS-safe defaults; adjust as needed)
CMD="cd \"$APP_HOME\" && ./hasher.sh --pathfile paths.txt --algo sha256 --nohup"
CRON_TAG_BEGIN="# === HASher WEEKLY BEGIN (do not edit inside) ==="
CRON_TAG_END="# === HASher WEEKLY END ==="
CRON_ID_LINE="$CRON_TAG_BEGIN"
CRON_FILE="/etc/crontab"

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Must be run as root to modify $CRON_FILE and restart cron."
    exit 1
  fi
}

restart_cron(){
  # DSM 7 typically:
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart crond || true
    # Optional but often helpful on DSM7:
    systemctl restart synoscheduler 2>/dev/null || true
    return
  fi
  # DSM 6 / BusyBox fallbacks
  if command -v synoservicectl >/dev/null 2>&1; then
    synoservicectl --reload crond 2>/dev/null || synoservicectl --restart crond 2>/dev/null || true
  elif command -v synoservice >/dev/null 2>&1; then
    synoservice --restart crond 2>/dev/null || true
  else
    service crond restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
  fi
}

show(){
  echo "CRON_SPEC: $CRON_SPEC"
  echo "COMMAND  : $CMD"
  echo "Checking $CRON_FILE:"
  if [ -r "$CRON_FILE" ]; then
    awk "/$CRON_TAG_BEGIN/,/$CRON_TAG_END/" "$CRON_FILE" || echo "(no scheduled block found)"
  else
    echo "[WARN] Cannot read $CRON_FILE"
  fi
}

enable(){
  need_root
  [ -w "$CRON_FILE" ] || { echo "[ERROR] Cannot write $CRON_FILE"; exit 1; }

  # Remove old block if present
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  awk -v b="$CRON_TAG_BEGIN" -v e="$CRON_TAG_END" '
    BEGIN{skip=0}
    $0 ~ b {skip=1; next}
    $0 ~ e {skip=0; next}
    skip==0 {print}
  ' "$CRON_FILE" > "$tmp"

  # Append fresh block; run as root (6-column crontab on Synology uses a "user" field)
  {
    echo "$CRON_TAG_BEGIN"
    echo "# Runs hasher weekly. Adjust CRON_SPEC in hasher.conf."
    echo "$CRON_SPEC root bash -lc '$CMD >> \"$LOG_DIR/cron-hasher.log\" 2>&1'"
    echo "$CRON_TAG_END"
  } >> "$tmp"

  cp "$tmp" "$CRON_FILE"
  echo "[INFO] Wrote schedule to $CRON_FILE"
  restart_cron
  echo "[INFO] Cron restarted."
}

disable(){
  need_root
  [ -w "$CRON_FILE" ] || { echo "[ERROR] Cannot write $CRON_FILE"; exit 1; }
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  awk -v b="$CRON_TAG_BEGIN" -v e="$CRON_TAG_END" '
    BEGIN{skip=0}
    $0 ~ b {skip=1; next}
    $0 ~ e {skip=0; next}
    skip==0 {print}
  ' "$CRON_FILE" > "$tmp"
  cp "$tmp" "$CRON_FILE"
  echo "[INFO] Removed schedule block from $CRON_FILE"
  restart_cron
  echo "[INFO] Cron restarted."
}

case "${ACTION}" in
  show)    show ;;
  enable)  enable ;;
  disable) disable ;;
  *) echo "Usage: $0 enable|disable|show [--spec \"5 0 * * 0\"]"; exit 2 ;;
esac
