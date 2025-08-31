#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#!/bin/bash
# delete-low-value.sh — handle low-value tiny files (including zero-size) from a list
# Exclusions: Thumbs.db/.DS_Store/Desktop.ini and dirs #recycle/@eaDir/.snapshot/.AppleDouble (case-insensitive).
# Auto-load excludes via EXCLUDES_FILE or hasher.conf. Supports --exclude and --list-excludes.
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# Path/layout discovery
. "$(dirname "$0")/lib_paths.sh" 2>/dev/null || true

LOG_DIR="$LOG_DIR"; LOW_DIR="$LOW_DIR"
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
if [ -r /proc/sys/kernel/random/uuid ]; then RUN_ID="$(cat /proc/sys/kernel/random/uuid)"; else RUN_ID="$(date +%s)-$$-$RANDOM"; fi
log(){ printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO" "$*"; }; log_warn(){ log "WARN" "$*"; }; log_error(){ log "ERROR" "$*"; }

LIST=""; THRESHOLD=0; FORCE=false; VERIFY_ONLY=false; QUARANTINE_DIR=""
EXCLUDES_FILE=""; EXTRA_EXCLUDES=(); LIST_EXCLUDES=false

to_lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
has_glob_meta(){ case "$1" in *'*'*|*'?'*|*'['*']'* ) return 0 ;; * ) return 1 ;; esac; }

declare -a EX_BASENAMES=( "thumbs.db" ".ds_store" "desktop.ini" )
declare -a EX_SUBSTRINGS=( "/#recycle/" "/@eadir/" "/.snapshot/" "/.appledouble/" )
declare -a EX_GLOBS=()

add_ex_glob(){ local p="$(to_lc "$1")"; if has_glob_meta "$p"; then EX_GLOBS+=( "$p" ); else EX_GLOBS+=( "*${p}*" ); fi; }
load_excludes_file(){ local f="$1"; [ -r "$f" ] || return 1; local n=0; while IFS= read -r raw || [ -n "$raw" ]; do l="${raw%$'\r'}"; case "$l" in ""|\#*) continue ;; esac; add_ex_glob "$l"; n=$((n+1)); done < "$f"; log_info "Loaded $n excludes from: $f"; }
discover_hasher_excludes(){
  for c in "$EXCLUDES_FILE_CANDIDATE" "excludes.txt" "exclude-paths.txt" "exclude-globs.txt"; do [ -r "$c" ] && { load_excludes_file "$c"); return 0; }; done
  if [ -r "$CONF_FILE" ]; then cf="$(awk -F= '/^(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[ \t]*=/{print $2; exit }' "$CONF_FILE" | sed 's/^[ \t"'\'' ]*//; s/[ \t"'\'' ]*$//')"; [ -n "$cf" ] && [ -r "$cf" ] && { load_excludes_file "$cf"; return 0; }; fi
  return 1
}
is_excluded(){
  local p="$1"; local plc="$(to_lc "$p")"; local b="$(basename -- "$p")"; local blc="$(to_lc "$b")"
  for x in "${EX_BASENAMES[@]}"; do [ "$blc" = "$x" ] && return 0; done
  for s in "${EX_SUBSTRINGS[@]}"; do case "$plc" in *"$s"*) return 0 ;; esac; done
  for g in "${EX_GLOBS[@]:-}"; do case "$plc" in $g) return 0 ;; esac; done
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-list) LIST="${2:-}"; shift ;;
    --threshold-bytes) THRESHOLD="${2:-0}"; shift ;;
    --force) FORCE=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift ;;
    --excludes-file) EXCLUDES_FILE="${2:-}"; shift ;;
    --exclude) EXTRA_EXCLUDES+=( "${2:-}" ); shift ;;
    --list-excludes) LIST_EXCLUDES=true ;;
    -h|--help) cat <<'EOF'
Usage: delete-low-value.sh --from-list <file> [options]
  --threshold-bytes N     Treat files of size <= N bytes as "low-value" (default: 0)
  --verify-only           Only verify and build a plan; do not delete or move
  --force                 Execute deletions/quarantine using the verified plan
  --quarantine DIR        Move files to DIR instead of deleting
  --excludes-file FILE    Load additional case-insensitive glob patterns (one per line)
  --exclude PATTERN       Add an inline exclude glob (may repeat). Matches full path.
  --list-excludes         Print the active exclusion rules and exit
EOF
      exit 0 ;;
    *) log_error "Unknown arg: $1"; exit 2 ;;
  esac; shift || true
done
[ -n "$LIST" ] || { log_error "Missing --from-list"; exit 2; }
[ -r "$LIST" ] || { log_error "List not readable: $LIST"; exit 2; }

if [ -r "$CONF_FILE" ]; then
  v="$(awk -F= '/^[[:space:]]*LOW_VALUE_THRESHOLD_BYTES[[:space:]]*=/{print $2; exit}' "$CONF_FILE" | tr -d '\r\n"'\''[:space:]')"; case "$v" in (''|*[!0-9]*) ;; (*) THRESHOLD="${THRESHOLD:-$v}";; esac
  cf="$(awk -F= '/^[[:space:]]*(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[[:space:]]*=/{print $2; exit}' "$CONF_FILE" | sed 's/^[[:space:]"'\'' ]*//; s/[[:space:]"'\'' ]*$//')"; [ -z "$EXCLUDES_FILE" ] && EXCLUDES_FILE="$cf"
  b="$(awk -F= '/^[[:space:]]*EXCLUDE_BASENAMES[[:space:]]*=/{print $2; exit}' "$CONF_FILE")"; if [ -n "$b" ]; then bcl="$(echo "$b" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"; IFS=',' read -r -a arr <<< "$bcl"; for x in "${arr[@]}"; do xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$xlc" ] && EX_BASENAMES+=( "$xlc" ); done; fi
  d="$(awk -F= '/^[[:space:]]*EXCLUDE_DIRS[[:space:]]*=/{print $2; exit}' "$CONF_FILE")"; if [ -n "$d" ]; then dcl="$(echo "$d" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"; IFS=',' read -r -a arr <<< "$dcl"; for x in "${arr[@]}"; do xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$xlc" ] && EX_SUBSTRINGS+=( "/${xlc}/" ); done; fi
  g="$(awk -F= '/^[[:space:]]*EXCLUDE_GLOBS[[:space:]]*=/{print $2; exit}' "$CONF_FILE")"; if [ -n "$g" ]; then gcl="$(echo "$g" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"; IFS=',' read -r -a arr <<< "$gcl"; for x in "${arr[@]}"; do xt="$(echo "$x" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$xt" ] && add_ex_glob "$xt"; done; fi
fi
[ -n "$EXCLUDES_FILE" ] && load_excludes_file "$EXCLUDES_FILE" or None
# fallback discovery
if [ -z "$EXCLUDES_FILE" ]; 
  # deliberately try local/default candidates, then common names
  : # EXCLUDES_FILE_CANDIDATE is baked by lib_paths.sh
fi
# always try discovery (no-op if already loaded)
for c in "$EXCLUDES_FILE_CANDIDATE" "excludes.txt" "exclude-paths.txt" "exclude-globs.txt"; do
  [ -r "$c" ] && load_excludes_file "$c"
done
for p in "${EXTRA_EXCLUDES[@]:-}"; do add_ex_glob "$p"; done
if $LIST_EXCLUDES; then
  echo "Active excludes:"; echo "  Basenames:"; for b in "${EX_BASENAMES[@]}"; do echo "    - $b"; done
  echo "  Dir substrings:"; for s in "${EX_SUBSTRINGS[@]}"; do echo "    - $s"; done
  echo "  Glob patterns:"; for g in "${EX_GLOBS[@]:-}"; do echo "    - $g"; done; exit 0
fi

SUMMARY_LOG="$LOG_DIR/delete-low-value-$(date +'%Y-%m-%d').log"
VERIFIED_PLAN="$LOW_DIR/verified-low-value-$(date +'%Y-%m-%d')-${RUN_ID}.txt"; : > "$VERIFIED_PLAN"

if $VERIFY_ONLY; then log_info "Mode: VERIFY-ONLY (no actions)"; elif ! $FORCE; then log_info "Mode: DRY-RUN (no changes)"; else log_info "Mode: EXECUTE"; fi
log_info "Threshold: <= ${THRESHOLD} bytes"; log_info "Input list: $LIST"; log_info "Summary log: $SUMMARY_LOG"; log_info "Run-ID: $RUN_ID"

considered=0; missing=0; not_regular=0; too_big=0; verified=0; excluded=0
get_size_bytes(){ if command -v stat >/dev/null 2>&1; then stat -c %s -- "$1" 2>/dev/null || stat --format=%s -- "$1" 2>/dev/null; else wc -c < "$1" | tr -d ' '; fi; }

while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%$'\r'}"; [ -z "$line" ] && continue; case "$line" in \#*) continue ;; esac
  considered=$((considered+1))
  if is_excluded "$line"; then excluded=$((excluded+1)); continue; fi
  if [ ! -e "$line" ]; then missing=$((missing+1)); continue; fi
  if [ ! -f "$line" ]; then not_regular=$((not_regular+1)); continue; fi
  sz="$(get_size_bytes "$line" || echo 999999999)"; case "$sz" in (*[!0-9]*|'') sz=999999999 ;; esac
  if [ "$sz" -le "$THRESHOLD" ]; then printf '%s\n' "$line" >> "$VERIFIED_PLAN"; verified=$((verified+1)); else too_big=$((too_big+1)); fi
done < "$LIST"

log_info "Verification complete."
log_info "  • Considered: $considered"
log_info "  • Excluded by rules: $excluded"
log_info "  • Missing: $missing"
log_info "  • Not regular files: $not_regular"
log_info "  • Over threshold: $too_big"
log_info "  • Verified <= threshold: $verified"
log_info "Verified plan file: $VERIFIED_PLAN"

if $VERIFY_ONLY; then printf "[VERIFY-ONLY SUMMARY]\n  Verified low-value files: %s\n" "$verified"; exit 0; fi
if ! $FORCE; then printf "[DRY-RUN SUMMARY]\n  Verified low-value files: %s\n" "$verified"; exit 0; fi

[ -n "$QUARANTINE_DIR" ] && mkdir -p "$QUARANTINE_DIR"
acted=0; errs=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  if [ -n "$QUARANTINE_DIR" ]; then dest="${QUARANTINE_DIR%/}/$(basename "$path")"; mv -f -- "$path" "$dest" 2>>"$SUMMARY_LOG" && { log_info "Quarantined: $path -> $dest"; acted=$((acted+1)); } || { log_error "Failed to quarantine: $path"; errs=$((errs+1)); }
  else rm -f -- "$path" 2>>"$SUMMARY_LOG" && { log_info "Deleted: $path"; acted=$((acted+1)); } || { log_error "Failed to delete: $path"; errs=$((errs+1)); }
  fi
done < "$VERIFIED_PLAN"
log_info "Execution complete. Acted on: $acted, errors: $errs"
exit 0
