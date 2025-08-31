#!/bin/bash
# delete-zero-length.sh — verify and delete/quarantine zero-length files from a list
# Now supports hasher.conf-driven exclusions (optional) matching delete-low-value.sh:
#   - Built-in excludes (always available; applied only if enabled): Thumbs.db, .DS_Store, Desktop.ini,
#     and directories #recycle, @eaDir, .snapshot, .AppleDouble (case-insensitive).
#   - Reads ZERO_APPLY_EXCLUDES from hasher.conf (default: false). CLI can override:
#       --apply-excludes  (force enable)
#       --no-excludes     (force disable)
#   - Also reads EXCLUDES_FILE / EXCLUDE_BASENAMES / EXCLUDE_DIRS / EXCLUDE_GLOBS from hasher.conf.
#   - CLI extras: --excludes-file FILE, --exclude PATTERN (repeatable), --list-excludes
#
# Usage:
#   ./delete-zero-length.sh <listfile> [--verify-only] [--force] [--quarantine DIR]
#                           [--apply-excludes|--no-excludes]
#                           [--excludes-file FILE] [--exclude PATTERN] [--list-excludes]
#
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# ── Setup ──────────────────────────────────────────────────────────────────────
LOG_DIR="logs"
ZERO_DIR="zero-length"
mkdir -p "$LOG_DIR" "$ZERO_DIR"

# Run ID (no uuidgen dependency)
if [ -r /proc/sys/kernel/random/uuid ]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$-$RANDOM"
fi

# ── Logging ───────────────────────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO"  "$*"; }
log_warn(){ log "WARN"  "$*"; }
log_error(){ log "ERROR" "$*"; }

# ── Exclusion engine (shared style with delete-low-value.sh) ───────────────────
# Built-in case-insensitive basename excludes
declare -a EX_BASENAMES=( "thumbs.db" ".ds_store" "desktop.ini" )
# Built-in case-insensitive directory substrings to avoid (match anywhere in path)
declare -a EX_SUBSTRINGS=( "/#recycle/" "/@eadir/" "/.snapshot/" "/.appledouble/" )
# User-specified glob patterns (case-insensitive against full paths)
declare -a EX_GLOBS=()

# Lowercase helper
to_lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
has_glob_meta(){ case "$1" in *'*'*|*'?'*|*'['*']'* ) return 0 ;; * ) return 1 ;; esac; }
add_ex_glob(){
  local p_lc="$(to_lc "$1")"
  if has_glob_meta "$p_lc"; then EX_GLOBS+=( "$p_lc" ); else EX_GLOBS+=( "*${p_lc}*" ); fi
}

load_excludes_file(){
  local file="$1"; [ -r "$file" ] || return 1
  local count=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    case "$line" in ""|\#*) continue ;; esac
    add_ex_glob "$line"; count=$((count+1))
  done < "$file"
  log_info "Loaded $count exclude pattern(s) from: $file"
  return 0
}

discover_hasher_excludes(){
  for cand in "excludes.txt" "exclude-paths.txt" "exclude-globs.txt"; do
    if [ -r "$cand" ]; then load_excludes_file "$cand" && return 0; fi
  done
  if [ -r "hasher.conf" ]; then
    local hint=""
    hint="$(awk -F= '/^(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[ \t]*=/{print $2; exit }' hasher.conf | sed 's/^[ \t"'\'' ]*//; s/[ \t"'\'' ]*$//')"
    if [ -n "$hint" ] && [ -r "$hint" ]; then load_excludes_file "$hint" && return 0; fi
  fi
  return 1
}

is_excluded(){
  # $1: path
  local p="$1"; local p_lc; p_lc="$(to_lc "$p")"
  local base; base="$(basename -- "$p")"; local base_lc; base_lc="$(to_lc "$base")"

  # Basename exacts
  for b in "${EX_BASENAMES[@]}"; do [ "$base_lc" = "$b" ] && return 0; done
  # Path substrings
  for s in "${EX_SUBSTRINGS[@]}"; do case "$p_lc" in *"$s"*) return 0 ;; esac; done
  # User globs
  for g in "${EX_GLOBS[@]:-}"; do case "$p_lc" in $g) return 0 ;; esac; done

  return 1
}

# ── Args ──────────────────────────────────────────────────────────────────────
INPUT_LIST=""
FORCE=false
VERIFY_ONLY=false
QUARANTINE_DIR=""
APPLY_EXCLUDES=""   # tri-state: "", true, false
EXCLUDES_FILE_OPT=""
EXTRA_EXCLUDES=()
LIST_EXCLUDES=false

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --force) FORCE=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift ;;
    --apply-excludes) APPLY_EXCLUDES=true ;;
    --no-excludes) APPLY_EXCLUDES=false ;;
    --excludes-file) EXCLUDES_FILE_OPT="${2:-}"; shift ;;
    --exclude) EXTRA_EXCLUDES+=( "${2:-}" ); shift ;;
    --list-excludes) LIST_EXCLUDES=true ;;
    -h|--help)
      cat <<'EOF'
Usage: delete-zero-length.sh <listfile> [options]

Options:
  --verify-only            Only verify and build a plan; do not delete or move
  --force                  Execute deletions/quarantine using the verified plan
  --quarantine DIR         Move files to DIR instead of deleting

  # Exclusions (optional; off by default unless enabled via hasher.conf or --apply-excludes)
  --apply-excludes         Apply hasher/external excludes to zero-length processing
  --no-excludes            Do not apply excludes (overrides config)
  --excludes-file FILE     Load additional case-insensitive glob patterns (one per line)
  --exclude PATTERN        Add an inline exclude glob (may repeat). Matches FULL path, case-insensitive.
  --list-excludes          Print the active exclusion rules and exit

Notes:
  - Exclusion matching is case-insensitive. Plain tokens without *,?,[ are wrapped as *token*.
  - ZERO_APPLY_EXCLUDES in hasher.conf can enable excludes by default for zero-length processing.
EOF
      exit 0 ;;
    *)
      if [ -z "$INPUT_LIST" ]; then INPUT_LIST="${1:-}"; else log_error "Unexpected argument: $1"; exit 2; fi
      ;;
  esac
  shift || true
done

[ -n "$INPUT_LIST" ] || { log_error "No input list provided."; exit 2; }
[ -r "$INPUT_LIST" ]  || { log_error "Input list not readable: $INPUT_LIST"; exit 2; }

SUMMARY_LOG="${LOG_DIR}/delete-zero-length-$(date +'%Y-%m-%d').log"
VERIFIED_PLAN="${ZERO_DIR}/verified-zero-length-$(date +'%Y-%m-%d')-${RUN_ID}.txt"
: > "$VERIFIED_PLAN"

# ── Read config from hasher.conf ──────────────────────────────────────────────
ZERO_APPLY_EXCLUDES=false
if [ -r "hasher.conf" ]; then
  z="$(awk -F= '/^[[:space:]]*ZERO_APPLY_EXCLUDES[[:space:]]*=/{print $2; exit}' hasher.conf | tr -d '\r\n"'\''[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$z" in (true|1|yes|y|on) ZERO_APPLY_EXCLUDES=true ;; esac

  # Excludes file
  cf="$(awk -F= '/^[[:space:]]*(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[[:space:]]*=/{print $2; exit}' hasher.conf | sed 's/^[[:space:]"'\'' ]*//; s/[[:space:]"'\'' ]*$//')"
  [ -z "$EXCLUDES_FILE_OPT" ] && EXCLUDES_FILE_OPT="$cf"

  # Extra basenames
  bline="$(awk -F= '/^[[:space:]]*EXCLUDE_BASENAMES[[:space:]]*=/{print $2; exit}' hasher.conf)"
  if [ -n "$bline" ]; then
    bclean="$(echo "$bline" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"
    IFS=',' read -r -a extra_b <<< "$bclean"
    for x in "${extra_b[@]:-}"; do
      xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$xlc" ] && EX_BASENAMES+=( "$xlc" )
    done
  fi

  # Extra directory substrings
  dline="$(awk -F= '/^[[:space:]]*EXCLUDE_DIRS[[:space:]]*=/{print $2; exit}' hasher.conf)"
  if [ -n "$dline" ]; then
    dclean="$(echo "$dline" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"
    IFS=',' read -r -a extra_d <<< "$dclean"
    for x in "${extra_d[@]:-}"; do
      xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$xlc" ] && EX_SUBSTRINGS+=( "/${xlc}/" )
    done
  fi

  # Extra globs
  gline="$(awk -F= '/^[[:space:]]*EXCLUDE_GLOBS[[:space:]]*=/{print $2; exit}' hasher.conf)"
  if [ -n "$gline" ]; then
    gclean="$(echo "$gline" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"
    IFS=',' read -r -a extra_g <<< "$gclean"
    for x in "${extra_g[@]:-}"; do
      xtrim="$(echo "$x" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$xtrim" ] && add_ex_glob "$xtrim"
    done
  fi
fi

# Decide whether to apply excludes (CLI overrides config)
if [ -z "$APPLY_EXCLUDES" ]; then
  $ZERO_APPLY_EXCLUDES && APPLY_EXCLUDES=true || APPLY_EXCLUDES=false
fi

# Load excludes from files if requested / available
if [ -n "$EXCLUDES_FILE_OPT" ]; then
  load_excludes_file "$EXCLUDES_FILE_OPT" || log_warn "Could not read excludes file: $EXCLUDES_FILE_OPT"
else
  discover_hasher_excludes || true
fi
for pat in "${EXTRA_EXCLUDES[@]:-}"; do add_ex_glob "$pat"; done

if $LIST_EXCLUDES; then
  echo "Active excludes (apply=${APPLY_EXCLUDES}):"
  echo "  Basenames:"; for b in "${EX_BASENAMES[@]}"; do echo "    - $b"; done
  echo "  Dir substrings:"; for s in "${EX_SUBSTRINGS[@]}"; do echo "    - $s"; done
  echo "  Glob patterns:"; for g in "${EX_GLOBS[@]:-}"; do echo "    - $g"; done
  exit 0
fi

# ── Mode banner ───────────────────────────────────────────────────────────────
if $VERIFY_ONLY; then
  log_info "Mode: VERIFY-ONLY (no deletes or moves will occur)"
elif ! $FORCE; then
  hint="delete"; [ -n "$QUARANTINE_DIR" ] && hint="quarantine to '$QUARANTINE_DIR'"
  log_info "Mode: DRY-RUN (will $hint)"
else
  hint="delete"; [ -n "$QUARANTINE_DIR" ] && hint="quarantine to '$QUARANTINE_DIR'"
  log_info "Mode: EXECUTE (will $hint)"
fi

$APPLY_EXCLUDES && log_info "Exclusions: ENABLED (per CLI/config)" || log_info "Exclusions: DISABLED"

log_info "Verifying zero-length files…"
log_info "Input list: $INPUT_LIST"
log_info "Summary log: $SUMMARY_LOG"
log_info "Run-ID: $RUN_ID"

# ── CRLF detection ────────────────────────────────────────────────────────────
has_crlf=false; grep -q $'\r' "$INPUT_LIST" && has_crlf=true

# ── Verification pass ─────────────────────────────────────────────────────────
considered=0; excluded=0; missing=0; not_regular=0; not_zero_now=0; verified=0
: > "$VERIFIED_PLAN"

# Read lines safely (trim trailing CR, skip blanks/comments)
while IFS= read -r rawline || [ -n "$rawline" ]; do
  line=${rawline%$'\r'}
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac

  considered=$((considered+1))

  if $APPLY_EXCLUDES && is_excluded "$line"; then
    excluded=$((excluded+1))
    continue
  fi

  if [ ! -e "$line" ]; then
    missing=$((missing+1)); continue
  fi

  if [ ! -f "$line" ]; then
    not_regular=$((not_regular+1)); continue
  fi

  if [ ! -s "$line" ]; then
    printf '%s\n' "$line" >> "$VERIFIED_PLAN"
    verified=$((verified+1))
  else
    not_zero_now=$((not_zero_now+1))
  fi
done < "$INPUT_LIST"

if $has_crlf; then
  log_warn "Input list has Windows (CRLF) line endings; handled safely during read."
  log_warn "To normalise on disk: sed -i 's/\\r$//' \"$INPUT_LIST\""
fi

if [ "$missing" -gt 0 ] && [ "$missing" -eq "$considered" ]; then
  log_warn "All entries appear missing. Common causes:"
  log_warn "  • CRLF endings in the list (run: sed -i 's/\\r$//' \"$INPUT_LIST\")"
  log_warn "  • Paths moved/renamed after the scan"
fi

log_info "Verification complete."
log_info "  • Input entries considered: $considered"
$APPLY_EXCLUDES && log_info "  • Excluded by rules: $excluded"
log_info "  • Missing paths: $missing"
log_info "  • Not regular files: $not_regular"
log_info "  • No longer zero-length: $not_zero_now"
log_info "  • Verified zero-length now: $verified"
log_info "Verified plan file: $VERIFIED_PLAN"

if $VERIFY_ONLY; then
  printf "[VERIFY-ONLY SUMMARY]\n"
  printf "  Verified zero-length files: %s\n" "$verified"
  printf "  Next: ./delete-zero-length.sh \"%s\"\n" "$INPUT_LIST"
  exit 0
fi

# ── DRY-RUN OR EXECUTE ────────────────────────────────────────────────────────
if ! $FORCE; then
  printf "[DRY-RUN SUMMARY]\n"
  printf "  Verified zero-length files: %s\n" "$verified"
  printf "  Ready to act using the verified plan:\n"
  printf "    Delete:\n"
  printf "      ./delete-zero-length.sh \"%s\" --force%s\n" "$INPUT_LIST" $($APPLY_EXCLUDES && echo " --apply-excludes" || echo "")
  printf "    Quarantine:\n"
  printf "      ./delete-zero-length.sh \"%s\" --force --quarantine \"zero-length/quarantine-$(date +%F)\"%s\n" "$INPUT_LIST" $($APPLY_EXCLUDES && echo " --apply-excludes" || echo "")
  exit 0
fi

# ── Ensure quarantine dir if set ──────────────────────────────────────────────
[ -n "$QUARANTINE_DIR" ] && mkdir -p "$QUARANTINE_DIR"

# ── Execute actions ───────────────────────────────────────────────────────────
acted=0; errs=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  if [ -n "$QUARANTINE_DIR" ]; then
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
