\
    #!/usr/bin/env bash
    # apply-folder-plan.sh — move duplicate folders listed in the plan to QUARANTINE_DIR
    # Extras:
    #  • If plan contains metadata cache dirs (@eaDir, .AppleDouble), offer to delete them instead of moving
    #  • Colorized output when TTY (no extra deps); plain text when redirected
    set -Eeuo pipefail
    IFS=$'\n\t'; LC_ALL=C

    ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
    LOGS_DIR="${ROOT_DIR}/logs"
    mkdir -p "$LOGS_DIR"

    PLAN_FILE=""
    FORCE=false
    DELETE_METADATA=false

    # Color helper
    init_colors() {
      if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        CINFO="\033[1;34m"; CWORK="\033[1;36m"; COK="\033[1;32m"; CWARN="\033[1;33m"; CERR="\033[1;31m"; CRESET="\033[0m"
      else
        CINFO=""; CWORK=""; COK=""; CWARN=""; CERR=""; CRESET=""
      fi
    }
    info(){ printf "%b[INFO]%b %s\n" "$CINFO" "$CRESET" "$*"; }
    work(){ printf "%b[WORK]%b %s\n" "$CWORK" "$CRESET" "$*"; }
    ok(){   printf "%b[OK]%b %s\n"   "$COK"   "$CRESET" "$*"; }
    warn(){ printf "%b[WARN]%b %s\n" "$CWARN" "$CRESET" "$*"; }
    err(){  printf "%b[ERROR]%b %s\n" "$CERR" "$CRESET" "$*"; }

    init_colors

    usage() {
      printf "%s\n" \
        "Usage: apply-folder-plan.sh [--plan <file>] [--force] [--delete-metadata]" \
        "  --plan FILE         Plan file (one directory per line). Defaults to latest duplicate-folders plan in logs/" \
        "  --force             Do not ask for confirmation." \
        "  --delete-metadata   Delete metadata cache dirs (@eaDir, .AppleDouble) instead of moving them."
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --plan) PLAN_FILE="${2:-}"; shift 2;;
        --force) FORCE=true; shift;;
        --delete-metadata) DELETE_METADATA=true; shift;;
        -h|--help) usage; exit 0;;
        *) err "Unknown arg: $1"; usage; exit 2;;
      esac
    done

    if [ -z "${PLAN_FILE:-}" ]; then
      PLAN_FILE="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "${PLAN_FILE:-}" ] || [ ! -s "$PLAN_FILE" ]; then
      err "No plan file found. Run 'Find duplicate folders' first."
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
    info "Quarantine: $QDIR — $DF_H"

    COUNT="$(wc -l < "$PLAN_FILE" | tr -d ' ')"
    info "Plan: $PLAN_FILE  | Directories: $COUNT"

    # Count metadata entries in plan
    META_COUNT="$(grep -Ec '/(@eaDir|\.AppleDouble)(/|$)' "$PLAN_FILE" || true)"
    if [ "${META_COUNT:-0}" -gt 0 ] && ! $DELETE_METADATA; then
      printf "%s" "$(printf "%b[INFO]%b " "$CINFO" "$CRESET")"
      read -r -p "Found $META_COUNT metadata cache dirs in plan (@eaDir, .AppleDouble). Delete them instead of moving? [y/N]: " reply || reply=""
      case "${reply,,}" in y|yes) DELETE_METADATA=true;; esac
    fi

    # du estimate
    if command -v du >/dev/null 2>&1; then
      du_total_k=0
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        kb="$(du -sk -- "$d" 2>/dev/null | awk 'NR==1{print $1}')"
        if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
          kb="$(du -k -- "$d" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
        fi
        du_total_k=$((10#${du_total_k:-0}+10#${kb:-0}))
      done < "$PLAN_FILE"
      du_bytes=$((du_total_k*1024))
      awk -v b="$du_bytes" 'BEGIN{ gb=b/1024/1024/1024; mb=b/1024/1024; if (gb>=1) printf("[INFO] Estimated move size (recursive): %.2f GB\n", gb); else printf("[INFO] Estimated move size (recursive): %.2f MB\n", mb); }'
    fi

    # Confirm
    if ! $FORCE; then
      printf "%s" "$(printf "%b[INFO]%b " "$CINFO" "$CRESET")"
      printf "Proceed to %s directories into:\n  %s\n[y/N]: " "$([ "$DELETE_METADATA" = true ] && echo "move+delete" || echo "move")" "$DEST_ROOT"
      read -r reply || reply=""
      case "${reply,,}" in
        y|yes) ;;
        *) echo "Aborted."; exit 0;;
      esac
    fi

    LOG_FILE="$LOGS_DIR/apply-folder-plan-$TS.log"
    info "Logging to $LOG_FILE"

    idx=0; ok=0; fail=0; removed=0
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      idx=$((idx+1))
      base="$(basename -- "$src")"
      if [ "$DELETE_METADATA" = true ] && printf '%s\n' "$src" | grep -Eq '/(@eaDir|\.AppleDouble)(/|$)'; then
        work "($idx/$COUNT) delete metadata: $src"
        if rm -rf -- "$src" 2>>"$LOG_FILE"; then removed=$((removed+1)); ok "deleted"; else warn "delete failed — see log"; fail=$((fail+1)); fi
        continue
      fi
      dest="$DEST_ROOT/$base"
      [ -e "$dest" ] && dest="${dest}-$(date +%s)"
      work "($idx/$COUNT) $src -> $dest"
      if mv -- "$src" "$dest" 2>>"$LOG_FILE"; then ok "moved"; else warn "move failed — see log"; fail=$((fail+1)); fi
    done < "$PLAN_FILE"

    info "Done. Moved: $ok  | Deleted metadata: $removed  | Failed: $fail  | Log: $LOG_FILE"
    info "Review quarantine: $DEST_ROOT"
    exit 0
