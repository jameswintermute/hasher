#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"

# v1.3.19: source awk NUL-safety detection
if [ -r "$ROOT_DIR/lib/awk-detect.sh" ]; then
  . "$ROOT_DIR/lib/awk-detect.sh"
  hasher_detect_awk_nul_safety
fi
LOGS_DIR="${ROOT_DIR}/logs"
HASHES_DIR="${ROOT_DIR}/hashes"
LOCAL_DIR="${ROOT_DIR}/local"
DEFAULT_DIR="${ROOT_DIR}/default"
VAR_DIR="${ROOT_DIR}/var"
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
    "Usage: delete-zero-length.sh [--input CSV] [--report FILE] [--scan] [--dry-run] [--force] [--quarantine] [--quiet]" \
    "" \
    "If --input not provided, uses latest CSV in hashes/. --scan performs a direct filesystem find (slower)." \
    "By default, files are deleted; use --quarantine to move them into QUARANTINE_DIR for review."
}

# FIX (v1.3.8 — recheck concern 4): use the SHARED resolve_quarantine_dir() from
# lib/host-detect.sh rather than a private copy that ignored an exported
# QUARANTINE_DIR environment variable. Source the helper here; the call site
# uses the shared function (with a graceful fallback if the helper is missing).
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT_DIR/lib/host-detect.sh"
fi

# Parse args
REPORT=""            # explicit pre-built zero-length report (newline path list)
DRYRUN=false         # if true, list what would be acted on and exit (no changes)
while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT="${2:-}"; shift 2;;
    --report) REPORT="${2:-}"; shift 2;;
    --scan) MODE="scan"; shift;;
    --force) FORCE=true; shift;;
    --dry-run) DRYRUN=true; shift;;
    --quarantine) QUARANTINE=true; shift;;
    --quiet) QUIET=true; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

# Determine mode of input.
# FIX (v1.3.7 — cross-check concern 2): an explicit --input ALWAYS parses that
# CSV. A pre-built zero-length report is used ONLY when the user explicitly
# passes --report FILE. We no longer auto-select a report behind an --input,
# because daily reports (zero-length-DATE.txt) cannot be reliably matched to
# per-run CSVs (hasher-DATE-HHMM.csv) and an unrelated same-day report could be
# acted on instead of the requested CSV.
if [ -n "$REPORT" ]; then
  if [ ! -f "$REPORT" ]; then err "Report not found: $REPORT"; exit 2; fi
  MODE="report"
fi

# Determine CSV (only when not using an explicit report)
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
TMP_LIST="$(mktemp "${TMPDIR:-/tmp}/zero-list.XXXXXX")"
cleanup(){ rm -f -- "$TMP_LIST" 2>/dev/null || true; }
trap cleanup EXIT

if [ "$MODE" = "report" ]; then
  info "Using explicit zero-length report: $REPORT"
  grep -vE '^[[:space:]]*(#|$)' "$REPORT" > "$TMP_LIST" 2>/dev/null || true
elif [ "$MODE" = "csv" ]; then
  # The CSV is parsed QUOTE-AWARE (RFC4180) — hasher.sh quotes any path
  # containing a comma, so a fixed-field split would mis-read the size column
  # for comma-named files and silently miss them (the v1.3.5 bug).
  info "Finding zero-length files from CSV (quote-aware): $INPUT"
  header="$(head -n1 -- "$INPUT" || true)"
  if printf %s "$header" | grep -q $'\t'; then dlm=$'\t'; else dlm=','; fi
    col_idx(){ printf '%s\n' "$1" | awk -v dlm="$2" 'BEGIN{FS=dlm} NR==1{for(i=1;i<=NF;i++){h=tolower($i); gsub(/^[ \t"]+|[ \t"]+$/,"",h); if(h=="path"){p=i} if(h=="size_bytes"){s=i}}} END{print p+0","s+0}' ; }
    idx="$(printf '%s\n' "$header" | col_idx "$header" "$dlm")"
    pidx="${idx%,*}"; sidx="${idx#*,}"
    if [ "$pidx" = "0" ] || [ "$sidx" = "0" ]; then
      err "CSV missing path/size_bytes columns."; exit 2
    fi
    awk -v ch="$pidx" -v cs="$sidx" -v DELIM="$dlm" '
      # Quote-aware RFC4180 splitter (comma delimiter); plain split otherwise.
      function csv_split(s, sep,   i,c,nf,cur,inq,n) {
        n=length(s); nf=0; cur=""; inq=0;
        if (sep != ",") { nf=split(s,A,sep); for(i=1;i<=nf;i++) F[i]=A[i]; return nf; }
        for (i=1;i<=n;i++) {
          c=substr(s,i,1);
          if (inq) {
            if (c=="\"") { if (substr(s,i+1,1)=="\"") { cur=cur "\""; i++ } else inq=0 }
            else cur=cur c
          } else {
            if (c=="\"") inq=1; else if (c==sep) { F[++nf]=cur; cur="" } else cur=cur c
          }
        }
        F[++nf]=cur; return nf;
      }
      NR==1 { next }
      {
        nf=csv_split($0, DELIM);
        path=(ch<=nf?F[ch]:""); size=(cs<=nf?F[cs]:"");
        sub(/^[ \t\r\n]+/,"",size); sub(/[ \t\r\n]+$/,"",size);
        if (size+0==0 && path!="") print path;
      }
    ' "$INPUT" > "$TMP_LIST"
else
  info "Scanning filesystem for zero-length files (this may take a while)…"
  # v1.3.18 (peer-review finding #1): use -print0 (NUL-delimited) during
  # discovery and filter out any candidate whose path contains TAB/LF/CR
  # before converting to the newline-delimited TMP_LIST. Previously -print
  # emitted raw newlines; a path such as $'evil\nother.txt' would be split
  # into two "candidates" and the second half might collide with an
  # unrelated real file.
  SCAN_NUL="$TMP_LIST.nul"
  : > "$SCAN_NUL"
  SKIP_ZL="${TMP_LIST%.txt}-skipped-delimiter.log"
  : > "$SKIP_ZL"
  # Scope: if a paths file exists, use it; otherwise scan /volume1 (Synology default root) safely
  # v1.3.20 (Mary's Mac): apply host prune-args so macOS system dirs like
  # .Spotlight-V100 don't cause BSD find to exit non-zero here either.
  # host-detect.sh may already be sourced above; guard for that.
  # v1.3.20 patch: bash 3.2 (macOS stock) needs the file-mediated
  # collection pattern and array-length branching used in hasher.sh.
  if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
    . "$ROOT_DIR/lib/host-detect.sh"
  fi
  ZL_PRUNE=()
  if command -v host_find_prune_args >/dev/null 2>&1; then
    _zltmp="${TMP_LIST%.txt}.prune.$$"
    host_find_prune_args > "$_zltmp" 2>/dev/null || true
    if [ -s "$_zltmp" ]; then
      while IFS= read -r _a || [ -n "$_a" ]; do
        [ -n "$_a" ] && ZL_PRUNE[${#ZL_PRUNE[@]}]="$_a"
      done < "$_zltmp"
    fi
    rm -f -- "$_zltmp" 2>/dev/null || true
  fi
  SCOPE_FILE=""
  for f in "$LOCAL_DIR/paths.txt" "$DEFAULT_DIR/paths.example.txt" "$DEFAULT_DIR/paths.txt"; do
    [ -f "$f" ] && SCOPE_FILE="$f" && break
  done
  if [ -n "$SCOPE_FILE" ]; then
    while IFS= read -r pth; do
      [ -z "$pth" ] && continue
      [ "${pth#\#}" != "$pth" ] && continue
      if [ ${#ZL_PRUNE[@]} -gt 0 ]; then
        find "$pth" "${ZL_PRUNE[@]}" -type f -size 0 -print0 >> "$SCAN_NUL" 2>/dev/null || true
      else
        find "$pth" -type f -size 0 -print0 >> "$SCAN_NUL" 2>/dev/null || true
      fi
    done < "$SCOPE_FILE"
  else
    # FIX (v1.1.9): host-aware fallback. /volume1 is Synology-only; on
    # macOS or generic Linux it doesn't exist and find returns nothing.
    SCAN_ROOT="$(host_default_scan_root 2>/dev/null || echo /volume1)"
    warn "No paths file found; scanning $SCAN_ROOT (override with --input or local/paths.txt)"
    if [ ${#ZL_PRUNE[@]} -gt 0 ]; then
      find "$SCAN_ROOT" "${ZL_PRUNE[@]}" -type f -size 0 -print0 >> "$SCAN_NUL" 2>/dev/null || true
    else
      find "$SCAN_ROOT" -type f -size 0 -print0 >> "$SCAN_NUL" 2>/dev/null || true
    fi
  fi
  SAFE_NUL="$TMP_LIST.safe.nul"
  # v1.3.19 (peer-review finding #1): use the lib helper (auto-selects bash
  # fallback on BusyBox).
  hasher_nul_filter_delim "$SCAN_NUL" "$SKIP_ZL" > "$SAFE_NUL"
  skipped_zl=$(wc -l < "$SKIP_ZL" 2>/dev/null | tr -d ' ')
  if [ "${skipped_zl:-0}" -gt 0 ]; then
    warn "Skipped $skipped_zl zero-length candidate(s) whose paths contain TAB/LF/CR."
    warn "  See: $SKIP_ZL"
  else
    rm -f -- "$SKIP_ZL" 2>/dev/null || true
  fi
  tr '\0' '\n' < "$SAFE_NUL" >> "$TMP_LIST"
  rm -f -- "$SCAN_NUL" "$SAFE_NUL" 2>/dev/null || true
fi

COUNT="$(wc -l < "$TMP_LIST" | tr -d ' ')"
if [ "${COUNT:-0}" -eq 0 ]; then
  ok "No zero-length files found."
  exit 0
fi
info "Zero-length files found: $COUNT"

# v1.3.7 (concern 4): --dry-run lists what WOULD be acted on and exits with no
# prompt and no changes. Pairs with the corrected hasher.sh recommendations.
if $DRYRUN; then
  if $QUARANTINE; then
    info "[DRY-RUN] Would move $COUNT zero-length file(s) to quarantine. No changes made."
  else
    info "[DRY-RUN] Would delete $COUNT zero-length file(s). No changes made."
  fi
  echo "----- files that would be affected -----"
  cat "$TMP_LIST"
  echo "----------------------------------------"
  exit 0
fi

# Confirm
if ! $FORCE; then
  if $QUARANTINE; then
    read -r -p "Move $COUNT zero-length files to quarantine? [y/N]: " a || a=""
  else
    read -r -p "Delete $COUNT zero-length files now? [y/N]: " a || a=""
  fi
  # FIX (v1.1.9): use tr-based lowercasing instead of bash-4 ${var,,}
  # so this script parses on Synology DSM bash 3.2 and macOS /bin/bash 3.2.
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *) echo "Aborted."; exit 0;;
  esac
fi

# Prepare quarantine if needed
if $QUARANTINE; then
  if command -v resolve_quarantine_dir >/dev/null 2>&1; then
    QDIR="$(resolve_quarantine_dir)"
  else
    QDIR="${QUARANTINE_DIR:-$ROOT_DIR/quarantine-$(date +%F)}"
  fi
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
    # FIX (v1.1.9): build the destination from the full source path,
    # v1.3.20 (peer-review recheck finding #5): mirror the source directory
    # hierarchy under $DEST rather than encoding with `s|/|__|g`. The old
    # encoding was NOT reversible: `/a/b__c` and `/a__b/c` both flattened
    # to `a__b__c`, and the second mv silently replaced the first while
    # the tool still reported "2 files moved". Use the same pattern that
    # delete-duplicates.sh has used since v1.3.5: build the destination
    # by joining $DEST with the source's absolute path (giving
    # `$DEST/a/b/file`), and disambiguate collisions with `.dup{n}` suffix
    # rather than silent overwrite. Two files with truly identical source
    # paths cannot exist simultaneously, so any collision here indicates
    # a re-run or manual copy — surface it, don't hide it.
    case "$f" in
      /*) tgt="$DEST$f" ;;
      *)  tgt="$DEST/$f" ;;
    esac
    tgt_dir=$(dirname "$tgt")
    mkdir -p "$tgt_dir"
    if [ -e "$tgt" ]; then
      n=1
      while [ -e "${tgt}.dup${n}" ]; do n=$((n+1)); done
      warn "Quarantine target exists; using ${tgt}.dup${n}"
      tgt="${tgt}.dup${n}"
    fi
    if mv -- "$f" "$tgt" 2>>"$LOG_FILE" && [ ! -e "$f" ]; then okc=$((okc+1)); else fail=$((fail+1)); fi
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
# v1.3.23 (peer-review recheck finding #4): return non-zero when any
# operation failed so cron/automation can detect incomplete cleanup.
# Convention: 0 = all succeeded; 1 = one or more failures; 2 = invalid
# input or safety refusal (already used earlier in the script).
if [ "${fail:-0}" -gt 0 ]; then
  exit 1
fi
exit 0
