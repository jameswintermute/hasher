#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
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
    # FIX (v1.1.9): host-aware fallback instead of hardcoded repo-root path.
    # v1.2.4: default_quarantine_root() now returns an install-relative path
    # ($ROOT_DIR/quarantine-DATE) on every host, including Synology, so the
    # quarantine always lives beside the tool. Set QUARANTINE_DIR in
    # local/hasher.conf to override.
    if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
      . "$ROOT_DIR/lib/host-detect.sh"
      val="$(default_quarantine_root)"
    else
      val="$ROOT_DIR/quarantine-$(date +%F)"
    fi
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
# FIX (v1.1.9): explicit TMPDIR-based form is portable across BSD/GNU mktemp
# (BSD mktemp's '-t' semantics differ from GNU's).
TMP_LIST="$(mktemp "${TMPDIR:-/tmp}/zero-list.XXXXXX")"
cleanup(){ rm -f -- "$TMP_LIST" 2>/dev/null || true; }
trap cleanup EXIT

if [ "$MODE" = "csv" ]; then
  # FIX (v1.3.5 — peer-review item 3): the previous CSV path used
  # `awk -v FS="$dlm"` with fixed field numbers. hasher.sh quotes any path
  # containing a comma, so a zero-length file named e.g. "a, b.txt" had its
  # fields shifted and the size column ($s) pointed at part of the path — the
  # file was silently NOT detected. Two-part fix:
  #   1. Prefer the clean, already-correct report hasher.sh writes during the
  #      run (var/zero-length/zero-length-DATE.txt): one path per line, built
  #      with a quote-aware parser. No CSV parsing needed.
  #   2. If no such report exists, parse the CSV QUOTE-AWARE (RFC4180), the
  #      same approach as find-duplicates.sh, instead of the naive split.
  zreport=""
  # Derive the date tag from the CSV name if it looks like hasher-YYYY-MM-DD-*.csv,
  # else try today; accept any matching report under var/zero-length/.
  csv_base="$(basename -- "$INPUT")"
  date_guess="$(printf '%s\n' "$csv_base" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
  for cand in \
    "$VAR_DIR/zero-length/zero-length-${date_guess}.txt" \
    "$(ls -1t "$VAR_DIR"/zero-length/zero-length-*.txt 2>/dev/null | head -1)"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { zreport="$cand"; break; }
  done

  if [ -n "$zreport" ]; then
    info "Using pre-built zero-length report: $zreport"
    # Plain newline-delimited path list; copy through, skipping blanks/comments.
    grep -vE '^[[:space:]]*(#|$)' "$zreport" > "$TMP_LIST" 2>/dev/null || true
  else
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
  fi
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
    # FIX (v1.1.9): host-aware fallback. /volume1 is Synology-only; on
    # macOS or generic Linux it doesn't exist and find returns nothing.
    if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
      . "$ROOT_DIR/lib/host-detect.sh"
      SCAN_ROOT="$(host_default_scan_root)"
    else
      SCAN_ROOT="/volume1"   # legacy default if lib missing
    fi
    warn "No paths file found; scanning $SCAN_ROOT (override with --input or local/paths.txt)"
    find "$SCAN_ROOT" -type f -size 0 -print >> "$TMP_LIST" 2>/dev/null || true
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
  # FIX (v1.1.9): use tr-based lowercasing instead of bash-4 ${var,,}
  # so this script parses on Synology DSM bash 3.2 and macOS /bin/bash 3.2.
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *) echo "Aborted."; exit 0;;
  esac
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
    # FIX (v1.1.9): build the destination from the full source path,
    # not just basename. Two empty files at /dirA/empty.log and
    # /dirB/empty.log would otherwise both target $DEST/empty.log
    # and the second mv would silently overwrite the first (or fail).
    # Same fix pattern as apply-folder-plan.sh (v1.1.6): strip leading
    # '/' and replace remaining '/' with '__' to encode the full path
    # in a flat, collision-free name.
    slot="$(printf '%s' "$f" | sed 's|^/||; s|/|__|g')"
    tgt="$DEST/$slot"
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
