\
    #!/usr/bin/env bash
    # delete-zero-length.sh — delete zero-byte files using latest hashes CSV (fast) or direct filesystem scan
    # BusyBox/bash safe. Color when TTY. Prompts for confirmation.
    set -Eeuo pipefail
    IFS=$'\n\t'; LC_ALL=C

    ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
    LOGS_DIR="${ROOT_DIR}/logs"
    HASHES_DIR="${ROOT_DIR}/hashes"
    LOCAL_DIR="${ROOT_DIR}/local"
    DEFAULT_DIR="${ROOT_DIR}/default"
    mkdir -p "$LOGS_DIR"

    MODE="csv"           # csv|scan
    INPUT=""             # optional CSV
    FORCE=false
    QUIET=false
    QUARANTINE=false     # if true, move to quarantine instead of delete

    # Colors
    init_colors() {
      if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        CINFO="\033[1;34m"; CWORK="\033[1;36m"; COK="\033[1;32m"; CWARN="\033[1;33m"; CERR="\033[1;31m"; CRESET="\033[0m"
      else
        CINFO=""; CWORK=""; COK=""; CWARN=""; CERR=""; CRESET=""
      fi
    }
    info(){ $QUIET || printf "%b[INFO]%b %s\n" "$CINFO" "$CRESET" "$*"; }
    work(){ $QUIET || printf "%b[WORK]%b %s\n" "$CWORK" "$CRESET" "$*"; }
    ok(){   $QUIET || printf "%b[OK]%b %s\n"   "$COK"   "$CRESET" "$*"; }
    warn(){ $QUIET || printf "%b[WARN]%b %s\n" "$CWARN" "$CRESET" "$*"; }
    err(){  printf "%b[ERROR]%b %s\n" "$CERR" "$CRESET" "$*"; }
    init_colors

    usage() {
      printf "%s\n" \
        "Usage: delete-zero-length.sh [--input CSV] [--scan] [--force] [--quarantine] [--quiet]" \
        "" \
        "If --input not provided, uses latest CSV in hashes/. --scan performs a direct filesystem find (slower)." \
        "By default, files are deleted; use --quarantine to move them into QUARANTINE_DIR for review."
    }

    resolve_quarantine_dir() {
      local raw=""
      if [ -f "$LOCAL_DIR/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$LOCAL_DIR/hasher.conf" | tail -n1 || true)"
      fi
      if [ -z "$raw" ] && [ -f "$DEFAULT_DIR/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$DEFAULT_DIR/hasher.conf" | tail -n1 || true)"
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

    # Parse args
    while [ $# -gt 0 ]; do
      case "$1" in
        --input) INPUT="${2:-}"; shift 2;;
        --scan) MODE="scan"; shift;;
        --force) FORCE=true; shift;;
        --quarantine) QUARANTINE=true; shift;;
        --quiet) QUIET=true; shift;;
        -h|--help) usage; exit 0;;
        *) err "Unknown arg: $1"; usage; exit 2;;
      esac
    done

    # Determine CSV
    if [ "$MODE" = "csv" ]; then
      if [ -z "${INPUT:-}" ]; then
        INPUT="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
      fi
      if [ -z "${INPUT:-}" ] || [ ! -f "$INPUT" ]; then
        warn "No CSV found; falling back to --scan mode."
        MODE="scan"
      fi
    fi

    # Collect candidate paths into a tmp list
    TMP_LIST="$(mktemp -t zero-list.XXXXXX)"
    cleanup(){ rm -f -- "$TMP_LIST" 2>/dev/null || true; }
    trap cleanup EXIT

    if [ "$MODE" = "csv" ]; then
      info "Finding zero-length files from CSV: $INPUT"
      header="$(head -n1 -- "$INPUT" || true)"
      if printf %s "$header" | grep -q $'\t'; then dlm=$'\t'; else dlm=','; fi
      col_idx(){ printf '%s\n' "$1" | awk -v dlm="$2" 'BEGIN{FS=dlm} NR==1{for(i=1;i<=NF;i++){h=tolower($i); gsub(/^[ \t"]+|[ \t"]+$/,"",h); if(h=="path"){p=i} if(h=="size_bytes"){s=i}}} END{print p+0","s+0}' ; }
      idx="$(printf '%s\n' "$header" | col_idx "$header" "$dlm")"
      pidx="${idx%,*}"; sidx="${idx#*,}"
      if [ "$pidx" = "0" ] || [ "$sidx" = "0" ]; then
        err "CSV missing path/size_bytes columns."; exit 2
      fi
      awk -v FS="$dlm" -v p="$pidx" -v s="$sidx" 'NR>1{ if ($s==0) {path=$p; gsub(/^"|"$/,"",path); print path} }' "$INPUT" > "$TMP_LIST"
    else
      info "Scanning filesystem for zero-length files (this may take a while)…"
      # Scope: if a paths file exists, use it; otherwise scan /volume1 (Synology default root) safely
      SCOPE_FILE=""
      for f in "$LOCAL_DIR/paths.txt" "$DEFAULT_DIR/paths.example.txt" "$DEFAULT_DIR/paths.txt"; do
        [ -f "$f" ] && SCOPE_FILE="$f" && break
      done
      if [ -n "$SCOPE_FILE" ]; then
        while IFS= read -r pth; do
          [ -z "$pth" ] && continue
          [ "${pth#\#}" != "$pth" ] && continue
          find "$pth" -type f -size 0 -print >> "$TMP_LIST" 2>/dev/null || true
        done < "$SCOPE_FILE"
      else
        find /volume1 -type f -size 0 -print >> "$TMP_LIST" 2>/dev/null || true
      fi
    fi

    COUNT="$(wc -l < "$TMP_LIST" | tr -d ' ')"
    if [ "${COUNT:-0}" -eq 0 ]; then
      ok "No zero-length files found."
      exit 0
    fi
    info "Zero-length files found: $COUNT"

    # Confirm
    if ! $FORCE; then
      if $QUARANTINE; then
        read -r -p "Move $COUNT zero-length files to quarantine? [y/N]: " a || a=""
      else
        read -r -p "Delete $COUNT zero-length files now? [y/N]: " a || a=""
      fi
      case "${a,,}" in y|yes) ;; *) echo "Aborted."; exit 0;; esac
    fi

    # Prepare quarantine if needed
    if $QUARANTINE; then
      QDIR="$(resolve_quarantine_dir)"
      TS="$(date +%F-%H%M%S)"
      DEST="$QDIR/zero-length-$TS"
      mkdir -p -- "$DEST"
      info "Quarantine: $DEST"
    fi

    LOG_FILE="$LOGS_DIR/delete-zero-length-$(date +%F-%H%M%S).log"
    info "Logging to $LOG_FILE"

    idx=0; okc=0; fail=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      idx=$((idx+1))
      # Re-verify zero size to be safe
      sz="$(stat -c %s -- "$f" 2>/dev/null || stat -f %z -- "$f" 2>/dev/null || echo 1)"
      if [ "${sz:-1}" != "0" ]; then
        continue
      fi
      if $QUARANTINE; then
        base="$(basename -- "$f")"
        tgt="$DEST/$base"
        if mv -- "$f" "$tgt" 2>>"$LOG_FILE"; then okc=$((okc+1)); else fail=$((fail+1)); fi
      else
        if rm -f -- "$f" 2>>"$LOG_FILE"; then okc=$((okc+1)); else fail=$((fail+1)); fi
      fi
      if [ $((idx % 200)) -eq 0 ]; then work "processed $idx/$COUNT"; fi
    done < "$TMP_LIST"

    if $QUARANTINE; then
      ok "Moved zero-length files: $okc | Failed: $fail | Dest: $DEST | Log: $LOG_FILE"
    else
      ok "Deleted zero-length files: $okc | Failed: $fail | Log: $LOG_FILE"
    fi
    exit 0
