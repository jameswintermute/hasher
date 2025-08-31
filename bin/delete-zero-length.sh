#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#!/bin/bash
# delete-zero-length.sh — verify and delete/quarantine zero-length files from a list
# Supports hasher.conf-driven exclusions (optional). CRLF-safe. --verify-only / --force / --quarantine.
set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

# Path/layout discovery
. "$(dirname "$0")/lib_paths.sh" 2>/dev/null || true

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
if [ -r /proc/sys/kernel/random/uuid ]; then RUN_ID="$(cat /proc/sys/kernel/random/uuid)"; else RUN_ID="$(date +%s)-$$-$RANDOM"; fi
log(){ printf "[%s] [RUN %s] [%s] %s\n" "$(ts)" "$RUN_ID" "$1" "$2"; }
log_info(){ log "INFO" "$*"; }; log_warn(){ log "WARN" "$*"; }; log_error(){ log "ERROR" "$*"; }

INPUT_LIST=""; FORCE=false; VERIFY_ONLY=false; QUARANTINE_DIR=""
APPLY_EXCLUDES=""; EXCLUDES_FILE_OPT=""; EXTRA_EXCLUDES=(); LIST_EXCLUDES=false

to_lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
has_glob_meta(){ case "$1" in *'*'*|*'?'*|*'['*']'* ) return 0 ;; * ) return 1 ;; esac; }

declare -a EX_BASENAMES=( "thumbs.db" ".ds_store" "desktop.ini" )
declare -a EX_SUBSTRINGS=( "/#recycle/" "/@eadir/" "/.snapshot/" "/.appledouble/" )
declare -a EX_GLOBS=()

add_ex_glob(){ local p="$(to_lc "$1")"; if has_glob_meta "$p"; then EX_GLOBS+=( "$p" ); else EX_GLOBS+=( "*${p}*" ); fi; }
load_excludes_file(){ local f="$1"; [ -r "$f" ] || return 1; local n=0; while IFS= read -r raw || [ -n "$raw" ]; do l="${raw%$'\r'}"; case "$l" in ""|\#*) continue ;; esac; add_ex_glob "$l"; n=$((n+1)); done < "$f"; log_info "Loaded $n excludes from: $f"; }
discover_hasher_excludes(){
  for c in "$EXCLUDES_FILE_CANDIDATE" "excludes.txt" "exclude-paths.txt" "exclude-globs.txt"; do [ -r "$c" ] && { load_excludes_file "$c"; return 0; }; done
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
    --force) FORCE=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift ;;
    --apply-excludes) APPLY_EXCLUDES=true ;;
    --no-excludes) APPLY_EXCLUDES=false ;;
    --excludes-file) EXCLUDES_FILE_OPT="${2:-}"; shift ;;
    --exclude) EXTRA_EXCLUDES+=( "${2:-}" ); shift ;;
    --list-excludes) LIST_EXCLUDES=true ;;
    -h|--help) cat <<'EOF'
Usage: delete-zero-length.sh <listfile> [options]
  --verify-only            Only verify and build a plan; do not delete or move
  --force                  Execute deletions/quarantine using the verified plan
  --quarantine DIR         Move files to DIR instead of deleting
  --apply-excludes         Apply hasher/external excludes to zero-length processing
  --no-excludes            Do not apply excludes (overrides config)
  --excludes-file FILE     Load additional case-insensitive glob patterns (one per line)
  --exclude PATTERN        Add an inline exclude glob (may repeat). Matches FULL path, case-insensitive.
  --list-excludes          Print the active exclusion rules and exit
EOF
      exit 0 ;;
    *)
      if [ -z "$INPUT_LIST" ]; then INPUT_LIST="${1:-}"; else log_error "Unexpected argument: $1"; exit 2; fi ;;
  esac; shift || true
done
[ -n "$INPUT_LIST" ] || { log_error "No input list provided."; exit 2; }
[ -r "$INPUT_LIST" ]  || { log_error "Input list not readable: $INPUT_LIST"; exit 2; }

SUMMARY_LOG="$LOG_DIR/delete-zero-length-$(date +'%Y-%m-%d').log"
VERIFIED_PLAN="$ZERO_DIR/verified-zero-length-$(date +'%Y-%m-%d')-${RUN_ID}.txt"; : > "$VERIFIED_PLAN"

ZERO_APPLY_EXCLUDES=false
if [ -r "$CONF_FILE" ]; then
  z="$(awk -F= '/^[[:space:]]*ZERO_APPLY_EXCLUDES[[:space:]]*=/{print $2; exit}' "$CONF_FILE" | tr -d '\r\n"'\''[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$z" in (true|1|yes|y|on) ZERO_APPLY_EXCLUDES=true ;; esac
  cf="$(awk -F= '/^[[:space:]]*(EXCLUDES_FILE|EXCLUDE_FILE|EXCLUDE_LIST)[[:space:]]*=/{print $2; exit}' "$CONF_FILE" | sed 's/^[[:space:]"'\'' ]*//; s/[[:space:]"'\'' ]*$//')"
  [ -z "$EXCLUDES_FILE_OPT" ] && EXCLUDES_FILE_OPT="$cf"
  b="$(awk -F= '/^[[:space:]]*EXCLUDE_BASENAMES[[:space:]]*=/{print $2; exit}' "$CONF_FILE")"
  if [ -n "$b" ]; then bcl="$(echo "$b" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"; IFS=',' read -r -a arr <<< "$bcl"; for x in "${arr[@]:-}"; do xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$xlc" ] && EX_BASENAMES+=( "$xlc" ); done; fi
  d="$(awk -F= '/^[[:space:]]*EXCLUDE_DIRS[[:space:]]*=/{print $2; exit}' "$CONF_FILE")"
  if [ -n "$d" ]; then dcl="$(echo "$d" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"; IFS=',' read -r -a arr <<< "$dcl"; for x in "${arr[@]:-}"; do xlc="$(echo "$x" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$xlc" ] && EX_SUBSTRINGS+=( "/${xlc}/" ); done; fi
  g="$(awk -F= '/^[[:space:]]*EXCLUDE_GLOBS[[:space:]]*=/{print $2; exit}' "$CONF_FILE")"
  if [ -n "$g" ]; then gcl="$(echo "$g" | tr -d '\r\n' | sed 's/^["'\'' ]\|["'\'' ]$//g')"; IFS=',' read -r -a arr <<< "$gcl"; for x in "${arr[@]:-}"; do xt="$(echo "$x" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$xt" ] && add_ex_glob "$xt"; done; fi
fi

if [ -z "$APPLY_EXCLUDES" ]; then $ZERO_APPLY_EXCLUDES && APPLY_EXCLUDES=true || APPLY_EXCLUDES=false; fi
if [ -n "$EXCLUDES_FILE_OPT" ]; then load_excludes_file "$EXCLUDES_FILE_OPT" || log_warn "Could not read excludes: $EXCLUDES_FILE_OPT"; else discover_hasher_excludes || true; fi
for p in "${EXTRA_EXCLUDES[@]:-}"; do add_ex_glob "$p"; done
if $LIST_EXCLUDES; then
  echo "Active excludes (apply=${APPLY_EXCLUDES}):"; echo "  Basenames:"; for b in "${EX_BASENAMES[@]}"; do echo "    - $b"; done
  echo "  Dir substrings:"; for s in "${EX_SUBSTRINGS[@]}"; do echo "    - $s"; done
  echo "  Glob patterns:"; for g in "${EX_GLOBS[@]:-}"; do echo "    - $g"; done; exit 0
fi

if $VERIFY_ONLY; then log_info "Mode: VERIFY-ONLY (no actions)"; elif ! $FORCE; then log_info "Mode: DRY-RUN (no changes)"; else log_info "Mode: EXECUTE"; fi
$APPLY_EXCLUDES && log_info "Exclusions: ENABLED (per CLI/config)" || log_info "Exclusions: DISABLED"
log_info "Verifying zero-length files…"; log_info "Input list: $INPUT_LIST"; log_info "Summary log: $SUMMARY_LOG"; log_info "Run-ID: $RUN_ID"

has_crlf=false; grep -q $'\r' "$INPUT_LIST" && has_crlf=true
considered=0; excluded=0; missing=0; not_regular=0; not_zero_now=0; verified=0
: > "$VERIFIED_PLAN"

while IFS= read -r rawline || [ -n "$rawline" ]; do
  line=${rawline%$'\r'}; [ -z "$line" ] && continue; case "$line" in \#*) continue ;; esac
  considered=$((considered+1))
  if $APPLY_EXCLUDES && is_excluded "$line"; then excluded=$((excluded+1)); continue; fi
  [ -e "$line" ] || { missing=$((missing+1)); continue; }
  [ -f "$line" ] || { not_regular=$((not_regular+1)); continue; }
  if [ ! -s "$line" ]; then printf '%s\n' "$line" >> "$VERIFIED_PLAN"; verified=$((verified+1)); else not_zero_now=$((not_zero_now+1)); fi
done < "$INPUT_LIST"

$has_crlf && { log_warn "Input list has Windows (CRLF) endings; handled during read."; log_warn "To normalise: sed -i 's/\\r$//' \"$INPUT_LIST\""; }
if [ "$missing" -gt 0 ] && [ "$missing" -eq "$considered" ]; then log_warn "All entries missing — possible CRLF or moved paths."; fi

log_info "Verification complete."
log_info "  • Input entries considered: $considered"
$APPLY_EXCLUDES && log_info "  • Excluded by rules: $excluded"
log_info "  • Missing paths: $missing"
log_info "  • Not regular files: $not_regular"
log_info "  • No longer zero-length: $not_zero_now"
log_info "  • Verified zero-length now: $verified"
log_info "Verified plan file: $VERIFIED_PLAN"

if $VERIFY_ONLY; then printf "[VERIFY-ONLY SUMMARY]\n  Verified zero-length files: %s\n" "$verified"; exit 0; fi
if ! $FORCE; then printf "[DRY-RUN SUMMARY]\n  Verified zero-length files: %s\n" "$verified"; exit 0; fi

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
