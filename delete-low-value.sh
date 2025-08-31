\
#!/bin/bash
# delete-low-value.sh — handle low-value tiny files (including zero-size) from a list
# Adds robust exclusion handling to respect hasher-style excludes plus built-ins:
#   - Basename excludes: Thumbs.db, .DS_Store, Desktop.ini (case-insensitive)
#   - Directory excludes: #recycle, @eaDir, .snapshot, .AppleDouble (case-insensitive)
#   - External exclude lists: --excludes-file FILE (or auto-detect: excludes.txt, exclude-paths.txt, exclude-globs.txt)
#   - Optional hasher.conf discovery: will try to locate EXCLUDES_FILE=... if present (without sourcing arbitrary code).
#
# Usage:
#   ./delete-low-value.sh --from-list <file> [--threshold-bytes N] [--force] [--quarantine DIR] [--verify-only]
#                         [--excludes-file FILE] [--exclude PATTERN]... [--list-excludes]
#
# Notes:
#   • Threshold default is 0 (i.e., zero-size only). Set --threshold-bytes 1024 for ≤1KiB, etc.
#   • Exclusion PATTERNs are case-insensitive and match against the FULL PATH (shell glob). If the pattern
#     contains no glob metacharacters (*?[), it will be wrapped as *pattern* for convenience.
#   • Built-in basename excludes (Thumbs.db/.DS_Store/Desktop.ini) are always respected.
#   • CRLF-safe: trims trailing \r when reading the list and any exclude files.
#
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

LOG_DIR="logs"
LOW_DIR="low-value"
mkdir -p "$LOG_DIR" "$LOW_DIR"

# Run ID (no uuidgen dependency)
if [ -r /proc/sys/kernel/random/uuid ]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$-$RANDOM"
fi

# Logging
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO"  "$*"; }
log_warn(){ log "WARN"  "$*"; }
log_error(){ log "ERROR" "$*"; }

# -------------------------------------------------------------------------------------
# Exclusion handling
# -------------------------------------------------------------------------------------
# Built-in case-insensitive basename excludes
declare -a EX_BASENAMES=( "thumbs.db" ".ds_store" "desktop.ini" )
# Built-in case-insensitive directory substrings to avoid (match anywhere in path)
declare -a EX_SUBSTRINGS=( "/#recycle/" "/@eadir/" "/.snapshot/" "/.appledouble/" )

# User-specified / auto-detected glob patterns (case-insensitive against full paths)
declare -a EX_GLOBS=()

EXCLUDES_FILE=""
LIST_EXCLUDES=false

# Lowercase helper
to_lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

has_glob_meta(){
  case "$1" in
    *'*'*|*'?'*|*'['*']'* ) return 0 ;;
    * ) return 1 ;;
  esac
}

add_ex_glob(){
  local p_lc="$(to_lc "$1")"
  if has_glob_meta "$p_lc"; then
    EX_GLOBS+=( "$p_lc" )
  else
    # Wrap in *...* for convenience if no glob metacharacters present
    EX_GLOBS+=( "*${p_lc}*" )
  fi
}

load_excludes_file(){
  local file="$1"
  [ -r "$file" ] || return 1
  local count=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    # Strip comments (#...) but allow inline paths with # by only treating leading # as comment
    case "$line" in ""|\#*) continue ;; esac
    add_ex_glob "$line"
    count=$((count+1))
  done < "$file"
  log_info "Loaded $count exclude pattern(s) from: $file"
  return 0
}

discover_hasher_excludes(){
  # 1) Direct files commonly used
  for cand in "excludes.txt" "exclude-paths.txt" "exclude-globs.txt"; do
    if [ -r "$cand" ]; then
      load_excludes_file "$cand" && return 0
    fi
  done
  # 2) hasher.conf hints: look for EXCLUDES_FILE=... or EXCLUDE_FILE=... or EXCLUDE_LIST=...
  if [ -r "hasher.conf" ]; then
    local hint=""
    hint="$(awk -F= '/^(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[ \t]*=/{gsub(/[ \t]*#/,"",$2); gsub(/^[ \t"]+/,"",$2); gsub(/[" \t]+$/,"",$2); print $2; exit }' hasher.conf || true)"
    if [ -n "$hint" ] && [ -r "$hint" ]; then
      load_excludes_file "$hint" && return 0
    fi
  fi
  return 1
}

is_excluded(){
  # $1: path
  local p="$1"
  local p_lc; p_lc="$(to_lc "$p")"
  local base; base="$(basename -- "$p")"
  local base_lc; base_lc="$(to_lc "$base")"

  # 1) Basename exacts
  for b in "${EX_BASENAMES[@]}"; do
    [ "$base_lc" = "$b" ] && return 0
  done

  # 2) Path substrings
  for s in "${EX_SUBSTRINGS[@]}"; do
    case "$p_lc" in *"$s"*) return 0 ;; esac
  done

  # 3) User glob patterns
  for g in "${EX_GLOBS[@]}"; do
    case "$p_lc" in $g) return 0 ;; esac
  done

  return 1  # not excluded
}

# -------------------------------------------------------------------------------------
# Args
# -------------------------------------------------------------------------------------
LIST=""
THRESHOLD=0
FORCE=false
VERIFY_ONLY=false
QUARANTINE_DIR=""
EXTRA_EXCLUDES=()

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --from-list) LIST="${2:-}"; shift ;;
    --threshold-bytes) THRESHOLD="${2:-0}"; shift ;;
    --force) FORCE=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift ;;
    --excludes-file) EXCLUDES_FILE="${2:-}"; shift ;;
    --exclude) EXTRA_EXCLUDES+=( "${2:-}" ); shift ;;
    --list-excludes) LIST_EXCLUDES=true ;;
    -h|--help)
      cat <<'EOF'
Usage: delete-low-value.sh --from-list <file> [options]

Options:
  --threshold-bytes N     Treat files of size <= N bytes as "low-value" (default: 0)
  --verify-only           Only verify and build a plan; do not delete or move
  --force                 Execute deletions/quarantine using the verified plan
  --quarantine DIR        Move files to DIR instead of deleting
  --excludes-file FILE    Load additional case-insensitive glob patterns (one per line)
  --exclude PATTERN       Add an inline exclude glob (may repeat). Matches full path.
  --list-excludes         Print the active exclusion rules and exit
  -h, --help              Show this help

Notes:
  - Exclusion matching is case-insensitive. If a pattern has no *,?,[, it is wrapped as *pattern*.
  - Built-in excludes always apply: basenames (Thumbs.db, .DS_Store, Desktop.ini) and dirs (#recycle, @eaDir, .snapshot, .AppleDouble).
  - The script will attempt to auto-discover excludes from hasher setups (excludes.txt / hasher.conf).
EOF
      exit 0
      ;;
    *) log_error "Unknown argument: $1"; exit 2 ;;
  esac
  shift || true
done

[ -n "$LIST" ] || { log_error "Missing --from-list"; exit 2; }
[ -r "$LIST" ] || { log_error "List not readable: $LIST"; exit 2; }

# Load excludes: explicit > auto-discovered; then inline extras
if [ -n "$EXCLUDES_FILE" ]; then
  if ! load_excludes_file "$EXCLUDES_FILE"; then
    log_warn "Could not read excludes file: $EXCLUDES_FILE"
  fi
else
  discover_hasher_excludes || log_info

# Read config keys from hasher.conf (without sourcing)
if [ -r "hasher.conf" ]; then
  # Numeric threshold
  val="$(awk -F= '/^[[:space:]]*LOW_VALUE_THRESHOLD_BYTES[[:space:]]*=/{print $2; exit}' hasher.conf | tr -d '\r\n"'\''[:space:]')"
  case "$val" in (''|*[!0-9]*) ;; (*) THRESHOLD="${THRESHOLD:-$val}";; esac

  # EXCLUDES_FILE
  cf="$(awk -F= '/^[[:space:]]*(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[[:space:]]*=/{print $2; exit}' hasher.conf | sed 's/^[[:space:]"'\'']*//; s/[[:space:]"'\'']*$//')"
  if [ -z "$EXCLUDES_FILE" ] && [ -n "$cf" ]; then
    EXCLUDES_FILE="$cf"
    load_excludes_file "$EXCLUDES_FILE" || log_warn "Could not read excludes file referenced in hasher.conf: $EXCLUDES_FILE"
  fi

  # EXCLUDE_BASENAMES (comma-separated)
  bline="$(awk -F= '/^[[:space:]]*EXCLUDE_BASENAMES[[:space:]]*=/{print $2; exit}' hasher.conf)"
  if [ -n "$bline" ]; then
    bclean="$(echo "$bline" | tr -d '\r\n' | sed 's/^["'\'']\|["'\'']$//g')"
    IFS=',' read -r -a extra_b <<< "$bclean"
    for x in "${extra_b[@]}"; do
      xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$xlc" ] && EX_BASENAMES+=( "$xlc" )
    done
  fi

  # EXCLUDE_DIRS (comma-separated)
  dline="$(awk -F= '/^[[:space:]]*EXCLUDE_DIRS[[:space:]]*=/{print $2; exit}' hasher.conf)"
  if [ -n "$dline" ]; then
    dclean="$(echo "$dline" | tr -d '\r\n' | sed 's/^["'\'']\|["'\'']$//g')"
    IFS=',' read -r -a extra_d <<< "$dclean"
    for x in "${extra_d[@]}"; do
      xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$xlc" ] && EX_SUBSTRINGS+=( "/${xlc}/" )
    done
  fi

  # EXCLUDE_GLOBS (comma-separated)
  gline="$(awk -F= '/^[[:space:]]*EXCLUDE_GLOBS[[:space:]]*=/{print $2; exit}' hasher.conf)"
  if [ -n "$gline" ]; then
    gclean="$(echo "$gline" | tr -d '\r\n' | sed 's/^["'\'']\|["'\'']$//g')"
    IFS=',' read -r -a extra_g <<< "$gclean"
    for x in "${extra_g[@]}"; do
      xtrim="$(echo "$x" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$xtrim" ] && add_ex_glob "$xtrim"
    done
  fi
fi
 "No external excludes file detected; using built-ins only."
fi
for pat in "${EXTRA_EXCLUDES[@]:-}"; do
  add_ex_glob "$pat"
done

if $LIST_EXCLUDES; then
  echo "Active excludes:"
  echo "  Basenames:"
  for b in "${EX_BASENAMES[@]}"; do echo "    - $b"; done
  echo "  Path substrings:"
  for s in "${EX_SUBSTRINGS[@]}"; do echo "    - $s"; done
  echo "  Glob patterns:"
  for g in "${EX_GLOBS[@]:-}"; do echo "    - $g"; done
  exit 0
fi

SUMMARY_LOG="${LOG_DIR}/delete-low-value-$(date +'%Y-%m-%d').log"
VERIFIED_PLAN="${LOW_DIR}/verified-low-value-$(date +'%Y-%m-%d')-${RUN_ID}.txt"
: > "$VERIFIED_PLAN"

# Mode banner
if $VERIFY_ONLY; then
  log_info "Mode: VERIFY-ONLY (no deletes or moves will occur)"
elif ! $FORCE; then
  hint="delete"
  [ -n "$QUARANTINE_DIR" ] && hint="quarantine to '$QUARANTINE_DIR'"
  log_info "Mode: DRY-RUN (will $hint)"
else
  hint="delete"
  [ -n "$QUARANTINE_DIR" ] && hint="quarantine to '$QUARANTINE_DIR'"
  log_info "Mode: EXECUTE (will $hint)"
fi

log_info "Threshold: <= ${THRESHOLD} bytes"
log_info "Input list: $LIST"
log_info "Summary log: $SUMMARY_LOG"
log_info "Run-ID: $RUN_ID"

# CRLF-safe reader + verification
considered=0; missing=0; not_regular=0; too_big=0; verified=0; excluded=0

get_size_bytes() {
  if command -v stat >/dev/null 2>&1; then
    stat -c %s -- "$1" 2>/dev/null || stat --format=%s -- "$1" 2>/dev/null
  else
    wc -c < "$1" | tr -d ' '
  fi
}

while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%$'\r'}"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  considered=$((considered+1))

  # Exclusions first
  if is_excluded "$line"; then
    excluded=$((excluded+1))
    continue
  fi

  if [ ! -e "$line" ]; then
    missing=$((missing+1)); continue
  fi
  if [ ! -f "$line" ]; then
    not_regular=$((not_regular+1)); continue
  fi

  sz="$(get_size_bytes "$line" || echo 999999999)"
  case "$sz" in (*[!0-9]*|'') sz=999999999 ;; esac

  if [ "$sz" -le "$THRESHOLD" ]; then
    printf '%s\n' "$line" >> "$VERIFIED_PLAN"
    verified=$((verified+1))
  else
    too_big=$((too_big+1))
  fi
done < "$LIST"

log_info "Verification complete."
log_info "  • Considered: $considered"
log_info "  • Excluded by rules: $excluded"
log_info "  • Missing: $missing"
log_info "  • Not regular files: $not_regular"
log_info "  • Over threshold: $too_big"
log_info "  • Verified <= threshold: $verified"
log_info "Verified plan file: $VERIFIED_PLAN"

if $VERIFY_ONLY; then
  printf "[VERIFY-ONLY SUMMARY]\\n"
  printf "  Verified low-value files: %s\\n" "$verified"
  printf "  Next: ./delete-low-value.sh --from-list \"%s\"\\n" "$LIST"
  exit 0
fi

if ! $FORCE; then
  printf "[DRY-RUN SUMMARY]\\n"
  printf "  Verified low-value files: %s\\n" "$verified"
  printf "  Ready to act using the verified plan:\\n"
  printf "    Delete:\\n"
  printf "      ./delete-low-value.sh --from-list \"%s\" --force\\n" "$LIST"
  printf "    Quarantine:\\n"
  printf "      ./delete-low-value.sh --from-list \"%s\" --force --quarantine \"low-value/quarantine-$(date +%F)\"\\n" "$LIST"
  exit 0
fi

# Execute
[ -n "$QUARANTINE_DIR" ] && mkdir -p "$QUARANTINE_DIR"
acted=0; errs=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  if [ -n "$QUARANTINE_DIR" ] ; then
    dest="${QUARANTINE_DIR%/}/$(basename "$path")"
    if mv -f -- "$path" "$dest" 2>>"$SUMMARY_LOG"; then
      log_info "Quarantined: $path -> $dest"; acted=$((acted+1))
    else
      log_error "Failed to quarantine: $path"; errs=$((errs+1))
    fi
  else
    if rm -f -- "$path" 2>>"$SUMMARY_LOG"; then
      log_info "Deleted: $path"; acted=$((acted+1))
    else
      log_error "Failed to delete: $path"; errs=$((errs+1))
    fi
  fi
done < "$VERIFIED_PLAN"

log_info "Execution complete. Acted on: $acted, errors: $errs"
exit 0
