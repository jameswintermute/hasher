\
    #!/usr/bin/env bash
    # apply-folder-plan.sh — move duplicate folders listed in the plan to QUARANTINE_DIR
    # Default: prompt the user; --force to skip confirmation. BusyBox/Bash safe.
    set -Eeuo pipefail
    IFS=$'\n\t'; LC_ALL=C

    ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
    LOGS_DIR="${ROOT_DIR}/logs"
    mkdir -p "$LOGS_DIR"

    PLAN_FILE=""
    FORCE=false

    usage() {
      printf "%s\n" \
        "Usage: apply-folder-plan.sh [--plan <file>] [--force]" \
        "  --plan FILE   Plan file (one directory per line). Defaults to latest duplicate-folders plan in logs/" \
        "  --force       Do not ask for confirmation."
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --plan) PLAN_FILE="${2:-}"; shift 2;;
        --force) FORCE=true; shift;;
        -h|--help) usage; exit 0;;
        *) echo "[ERROR] Unknown arg: $1"; usage; exit 2;;
      esac
    done

    if [ -z "${PLAN_FILE:-}" ]; then
      PLAN_FILE="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "${PLAN_FILE:-}" ] || [ ! -s "$PLAN_FILE" ]; then
      echo "[ERROR] No plan file found. Run 'Find duplicate folders' first." >&2
      exit 2
    fi

    # Resolve quarantine dir from hasher.conf (local overrides default)
    resolve_quarantine_dir() {
      local raw=""
      if [ -f "$ROOT_DIR/local/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$ROOT_DIR/local/hasher.conf" | tail -n1 || true)"
      fi
      if [ -z "$raw" ] && [ -f "$ROOT_DIR/default/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$ROOT_DIR/default/hasher.conf" | tail -n1 || true)"
      fi
      local val
      val="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^[\"\x27]//; s/[\"\x27]$//')"
      if [ -z "$val" ]; then
        val="$ROOT_DIR/quarantine-$(date +%F)"
      else
        val="${val//\$\((date +%F)\)/$(date +%F)}"
        val="${val//\$(date +%F)/$(date +%F)}"
      fi
      printf '%s\n' "$val"
    }

    QDIR="$(resolve_quarantine_dir)"
    TS="$(date +%F-%H%M%S)"
    DEST_ROOT="$QDIR/folders-$TS"
    mkdir -p -- "$DEST_ROOT"

    # Free space
    DF_H="$(df -h "$QDIR" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
    echo "[INFO] Quarantine: $QDIR — $DF_H"

    COUNT="$(wc -l < "$PLAN_FILE" | tr -d ' ')"
    echo "[INFO] Plan: $PLAN_FILE  | Directories: $COUNT"

    # du estimate
    if command -v du >/dev/null 2>&1; then
      du_total_k=0; while IFS= read -r d; do [ -z "$d" ] && continue; kb="$(du -sk -- "$d" 2>/dev/null | awk 'NR==1{print $1}')"; if ! [[ "$kb" =~ ^[0-9]+$ ]]; then kb="$(du -k -- "$d" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"; fi; du_total_k=$((10#${du_total_k:-0}+10#${kb:-0})); done < "$PLAN_FILE"
      du_bytes=$((du_total_k*1024))
      awk -v b="$du_bytes" 'BEGIN{ gb=b/1024/1024/1024; mb=b/1024/1024; if (gb>=1) printf("[INFO] Estimated move size (recursive): %.2f GB\n", gb); else printf("[INFO] Estimated move size (recursive): %.2f MB\n", mb); }'
    fi

    # Confirm
    if ! $FORCE; then
      printf "Proceed to move these directories into:\n  %s\n[y/N]: " "$DEST_ROOT"
      read -r reply || reply=""
      case "${reply,,}" in
        y|yes) ;;
        *) echo "Aborted."; exit 0;;
      esac
    fi

    LOG_FILE="$LOGS_DIR/apply-folder-plan-$TS.log"
    echo "[INFO] Logging to $LOG_FILE"

    idx=0; ok=0; fail=0
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      idx=$((idx+1))
      base="$(basename -- "$src")"
      dest="$DEST_ROOT/$base"
      # Avoid collisions
      if [ -e "$dest" ]; then dest="${dest}-$(date +%s)"; fi
      printf "[WORK] (%d/%d) %s -> %s\n" "$idx" "$COUNT" "$src" "$dest" | tee -a "$LOG_FILE"
      if mv -- "$src" "$dest" 2>>"$LOG_FILE"; then ok=$((ok+1)); echo "[OK] moved" | tee -a "$LOG_FILE"
      else fail=$((fail+1)); echo "[WARN] move failed — see log" | tee -a "$LOG_FILE"; fi
    done < "$PLAN_FILE"

    echo "[INFO] Done. Moved: $ok  | Failed: $fail  | Log: $LOG_FILE"
    echo "[TIP] Review the quarantine at: $DEST_ROOT"
    exit 0
