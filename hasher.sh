#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute <jameswinter@protonmail.ch>
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Constants ───────────────────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"

ALGO="sha256"        # sha256|sha1|sha512|md5|blake2
PATHFILE=""
RUN_IN_BACKGROUND=false
IS_CHILD=false       # set when re-exec'ed under nohup
LOG_LEVEL="info"     # info|warn|error

# Progress interval (seconds) for background.log
PROGRESS_INTERVAL=15

# Default excludes (kept minimal; comment out if undesired)
DEFAULT_EXCLUDES=( "#recycle" "@eaDir" ".DS_Store" "lost+found" )

# ───────────────────────── Colors ──────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───────────────────────── Setup ───────────────────────────
mkdir -p "$HASHES_DIR" "$LOGS_DIR"

# Run ID
if command -v uuidgen >/dev/null 2>&1; then
  RUN_ID="$(uuidgen)"
elif [[ -r /proc/sys/kernel/random/uuid ]]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$"
fi

MAIN_LOG="$LOGS_DIR/hasher.log"
RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
FILES_LIST="$LOGS_DIR/files-$RUN_ID.lst"
BACKGROUND_LOG="$LOGS_DIR/background.log"

# ───────────────────────── Logging ─────────────────────────
_log() {
  local lvl="$1"; shift
  local msg="$*"
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [RUN $RUN_ID] [$lvl] $msg"
  # console
  case "$lvl" in
    INFO)  echo -e "${GREEN}$line${NC}";;
    WARN)  echo -e "${YELLOW}$line${NC}";;
    ERROR) echo -e "${RED}$line${NC}";;
    *)     echo "$line";;
  esac
  # logs
  printf '%s\n' "$line" >> "$MAIN_LOG"
  printf '%s\n' "$line" >> "$RUN_LOG"
}

info()  { _log "INFO"  "$*"; }
warn()  { _log "WARN"  "$*"; }
error() { _log "ERROR" "$*"; }

# ───────────────────────── Arg Parsing ─────────────────────
usage() {
  cat <<EOF
Usage: $0 [--pathfile FILE] [--algo sha256|sha1|sha512|md5|blake2] [--output CSV]
          [--nohup] [--level info|warn|error] [--interval SECONDS]
          [--exclude PATTERN ...] [--help]

Options:
  --pathfile FILE    File containing one path (dir or file) per line. Required unless paths are piped.
  --algo ALG         Hash algorithm (default: sha256).
  --output CSV       Output CSV path (default: $OUTPUT).
  --nohup            Re-exec under nohup (background) with logs to $BACKGROUND_LOG.
  --level LEVEL      Log level threshold (info|warn|error). Default: info.
  --interval N       Progress update interval seconds (default: $PROGRESS_INTERVAL).
  --exclude P        Extra exclude pattern(s). Repeatable. (Literal substring match)
  --help             Show this help.

Behavior:
  * Writes CSV with header to: \$OUTPUT
  * Logs: $MAIN_LOG (global), $RUN_LOG (per run), progress to $BACKGROUND_LOG
  * Creates file list at: $FILES_LIST
EOF
}

EXTRA_EXCLUDES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pathfile) PATHFILE="$2"; shift ;;
    --algo)     ALGO="$2"; shift ;;
    --output)   OUTPUT="$2"; shift ;;
    --nohup)    RUN_IN_BACKGROUND=true ;;
    --level)    LOG_LEVEL="$2"; shift ;;
    --interval) PROGRESS_INTERVAL="$2"; shift ;;
    --exclude)  EXTRA_EXCLUDES+=("$2"); shift ;;
    --child)    IS_CHILD=true ;;          # internal
    -h|--help)  usage; exit 0 ;;
    *) error "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# ───────────────────────── Nohup Re-exec ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  # Re-exec under nohup; keep environment + mark as child
  export IS_CHILD=true
  # shellcheck disable=SC2046
  nohup "$0" --child \
    ${PATHFILE:+--pathfile "$PATHFILE"} \
    --algo "$ALGO" \
    --output "$OUTPUT" \
    --level "$LOG_LEVEL" \
    --interval "$PROGRESS_INTERVAL" \
    $(for ex in "${EXTRA_EXCLUDES[@]}"; do printf -- "--exclude %q " "$ex"; done) \
    >>"$BACKGROUND_LOG" 2>&1 < /dev/null &
  bgpid=$!
  echo "Hasher started with nohup (PID $bgpid). Output: $OUTPUT"
  exit 0
fi

# ───────────────────────── Hash Tool Map ───────────────────
hash_cmd=""
case "$ALGO" in
  sha256) hash_cmd="sha256sum" ;;
  sha1)   hash_cmd="sha1sum"   ;;
  sha512) hash_cmd="sha512sum" ;;
  md5)    hash_cmd="md5sum"    ;;
  blake2)
    if command -v b2sum >/dev/null 2>&1; then
      hash_cmd="b2sum"
    else
      error "blake2 requested but 'b2sum' not found"; exit 1
    fi
    ;;
  *) error "Unsupported --algo '$ALGO'"; exit 1 ;;
esac

command -v "$hash_cmd" >/dev/null 2>&1 || { error "Required tool '$hash_cmd' not found in PATH"; exit 1; }

# ───────────────────────── Build File List ─────────────────
# Accepts: PATHFILE with dirs/files; comments (#) and blanks ignored.
build_file_list() {
  : > "$FILES_LIST"
  local had_input=false

  if [[ -n "$PATHFILE" ]]; then
    if [[ ! -r "$PATHFILE" ]]; then
      error "Cannot read --pathfile '$PATHFILE'"; exit 1
    fi
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      # trim
      local path="${raw#"${raw%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
      [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
      if [[ -d "$path" ]]; then
        find "$path" -type f -print0
      elif [[ -f "$path" ]]; then
        printf '%s\0' "$path"
      else
        warn "Path does not exist: $path"
      fi
    done < "$PATHFILE" >> "$FILES_LIST".tmp
    had_input=true
  fi

  # If stdin is a pipe, also accept paths (null-terminated or newline)
  if [ ! -t 0 ]; then
    had_input=true
    # Try to detect NULs; if none, convert newlines
    if grep -qP '\x00' <(dd bs=1024 count=1 2>/dev/null); then
      cat >> "$FILES_LIST".tmp
    else
      while IFS= read -r p || [[ -n "$p" ]]; do
        [[ -z "$p" ]] && continue
        printf '%s\0' "$p"
      done >> "$FILES_LIST".tmp
    fi
  fi

  if ! $had_input; then
    error "No input paths provided. Use --pathfile or pipe paths."; exit 2
  fi

  # Apply excludes (substring match)
  # Merge default and extra patterns
  local patterns=("${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}")
  if (( ${#patterns[@]} > 0 )); then
    # Read NUL list, filter lines that DO NOT contain any pattern
    awk -v RS='\0' -v ORS='\0' -v N="${#patterns[@]}" '
      BEGIN{
        for(i=1;i<=N;i++) pat[i]=ARGV[i];
        ARGC=1
      }
      {
        keep=1
        for(i=1;i<=N;i++){
          if(index($0, pat[i])>0){ keep=0; break }
        }
        if(keep) printf "%s", $0
      }
    ' "${patterns[@]}" "$FILES_LIST".tmp > "$FILES_LIST"
  else
    mv -f -- "$FILES_LIST".tmp "$FILES_LIST"
  fi
  rm -f -- "$FILES_LIST".tmp 2>/dev/null || true
}

# ───────────────────────── CSV Helpers ─────────────────────
csv_escape() {
  # Escape CSV field by double-quoting and doubling internal quotes
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

write_csv_header() {
  if [[ ! -s "$OUTPUT" ]]; then
    printf 'path,size_bytes,mtime_epoch,algo,hash\n' > "$OUTPUT"
  fi
}

append_csv_row() {
  local path="$1" size="$2" mtime="$3" algo="$4" hash="$5"
  printf '%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$path")" \
    "$size" \
    "$mtime" \
    "$algo" \
    "$hash" >> "$OUTPUT"
}

# ───────────────────────── Progress Ticker ─────────────────
T_START=0
hash_progress_pid=0
TOTAL=0
DONE=0
FAIL=0

start_progress() {
  T_START=$(date +%s)
  (
    while :; do
      sleep "$PROGRESS_INTERVAL" || break
      local now elapsed eta pct
      now=$(date +%s)
      elapsed=$(( now - T_START ))
      if (( DONE > 0 )); then
        # ETA heuristic
        if (( DONE < TOTAL && TOTAL > 0 )); then
          eta=$(( (elapsed * (TOTAL - DONE)) / DONE ))
        else
          eta=0
        fi
      else
        eta=0
      fi
      if (( TOTAL > 0 )); then
        pct=$(( DONE * 100 / TOTAL ))
      else
        pct=0
      fi
      printf '[%s] [RUN %s] [PROGRESS] Hashing: [%s%%] %s/%s | elapsed=%02d:%02d:%02d eta=%02d:%02d:%02d\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$DONE" "$TOTAL" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) >> "$BACKGROUND_LOG"
    done
  ) &
  hash_progress_pid=$!
}

stop_progress() {
  if [[ "$hash_progress_pid" -gt 0 ]] && kill -0 "$hash_progress_pid" 2>/dev/null; then
    kill "$hash_progress_pid" 2>/dev/null || true
    wait "$hash_progress_pid" 2>/dev/null || true
  fi
}

# Clean shutdown
cleanup() {
  stop_progress
}
trap cleanup EXIT

# ───────────────────────── Main Hashing ────────────────────
main() {
  info "Run-ID: $RUN_ID"
  info "Config: ${PATHFILE:+pathfile=$PATHFILE} | Algo: $ALGO | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"
  info "Output CSV: $OUTPUT"

  build_file_list

  # Count total
  if [[ -s "$FILES_LIST" ]]; then
    TOTAL=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
  else
    TOTAL=0
  fi
  info "Discovered $TOTAL files to hash (post-exclude)."

  write_csv_header
  start_progress

  # Iterate 0-terminated list to handle any filename safely
  local start_ts
  start_ts=$(date +%s)

  # Read in chunks for portability
  # shellcheck disable=SC2034
  while IFS= read -r -d '' f; do
    # Stat size & mtime
    local size mtime
    size=$(stat -c%s -- "$f" 2>/dev/null || echo -1)
    mtime=$(stat -c%Y -- "$f" 2>/dev/null || echo -1)

    if [[ "$size" -lt 0 || "$mtime" -lt 0 ]]; then
      warn "Stat failed: $f"
      FAIL=$((FAIL+1))
      DONE=$((DONE+1))
      continue
    fi

    # Compute hash
    local line hash
    if ! line=$("$hash_cmd" -- "$f" 2>/dev/null); then
      warn "Hash failed: $f"
      FAIL=$((FAIL+1))
      DONE=$((DONE+1))
      continue
    fi
    hash="${line%% *}"  # first field up to first space

    append_csv_row "$f" "$size" "$mtime" "$ALGO" "$hash"
    DONE=$((DONE+1))
  done < "$FILES_LIST"

  local end_ts elapsed sH sM sS
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  sH=$((elapsed/3600)); sM=$((elapsed%3600/60)); sS=$((elapsed%60))

  stop_progress

  info "Completed. Hashed $DONE/$TOTAL files (failures=$FAIL) in $(printf '%02d:%02d:%02d' "$sH" "$sM" "$sS"). CSV: $OUTPUT"

  # ── Minimal addition: post-run reports + next steps ──────
  post_run_reports "$OUTPUT" "$DATE_TAG"
}

# ───────────────────────── Post-run Reports ────────────────
# Minimal, self-contained; header-agnostic; logs “next steps”.
post_run_reports() {
  local csv="$1"  # OUTPUT CSV
  local date_tag="$2"

  mkdir -p "$LOGS_DIR"

  local zero_txt="$LOGS_DIR/zero-length-$date_tag.txt"
  local dupes_txt="$LOGS_DIR/$date_tag-duplicate-hashes.txt"

  # Zero-length list from CSV (detect size column)
  if [[ -f "$csv" ]]; then
    awk -F',' '
      NR==1 {
        for (i=1;i<=NF;i++) h[tolower($i)]=i
        next
      }
      {
        sizecol = (h["size_bytes"] ? h["size_bytes"] : (h["size"] ? h["size"] : 0))
        pathcol = (h["path"] ? h["path"] : (h["filepath"] ? h["filepath"] : 1))
        if (sizecol>0) {
          if ($sizecol+0==0) print $pathcol
        } else {
          # fallback: last col is size? If 0, print first col
          if ($(NF)+0==0) print $1
        }
      }
    ' "$csv" | sed '/^\s*$/d' > "$zero_txt" || true
  fi

  # Duplicate report (group by a likely hash column)
  awk -F',' '
    BEGIN{ OFS="," }
    NR==1 {
      for (i=1;i<=NF;i++) { low=tolower($i); h[low]=i }
      next
    }
    {
      hashcol = (h["hash"] ? h["hash"] :
                (h["sha256"] ? h["sha256"] :
                (h["sha1"] ? h["sha1"] :
                (h["sha512"] ? h["sha512"] :
                (h["md5"] ? h["md5"] : 0)))))
      pathcol = (h["path"] ? h["path"] : (h["filepath"] ? h["filepath"] : 1))
      if (hashcol==0) next
      hash=$hashcol; path=$pathcol
      gsub(/^[ \t]+|[ \t]+$/,"",hash)
      gsub(/^[ \t]+|[ \t]+$/,"",path)
      if (hash!="") { count[hash]++; files[hash]=files[hash]"\n"path }
    }
    END{
      for (k in count) if (count[k]>1) {
        print "HASH " k " (" count[k] " files):"
        s=files[k]; sub(/^\n/,"",s)
        n=split(s,arr,"\n")
        for (i=1;i<=n;i++) print "  " arr[i]
        print ""
      }
    }
  ' "$csv" > "$dupes_txt" || true

  # Counts
  local zero_count=0 dupe_groups=0 dupe_files=0
  [[ -s "$zero_txt" ]] && zero_count=$(wc -l < "$zero_txt" | tr -d ' ')
  if [[ -s "$dupes_txt" ]]; then
    dupe_groups=$(grep -c '^HASH ' "$dupes_txt" || true)
    dupe_files=$(grep -v '^$' "$dupes_txt" | grep -v '^HASH ' | sed 's/^[[:space:]]\+//' | sed '/^$/d' | wc -l | tr -d ' ' || true)
  fi

  echo
  info "Run complete. Summary:"
  info "  • CSV written to: $csv"
  info "  • Zero-length files: $zero_count (see: $zero_txt)"
  info "  • Duplicate groups: $dupe_groups (files involved: $dupe_files) (see: $dupes_txt)"
  echo
  echo -e "${GREEN}[RECOMMENDED NEXT STEPS]${NC}"
  echo "  1) Review duplicates interactively:"
  echo "       ./review-duplicates.sh"
  echo "  2) Remove zero-length files (dry-run first):"
  echo "       ./delete-zero-length.sh \"$zero_txt\"           # dry-run"
  echo "       ./delete-zero-length.sh \"$zero_txt\" --force   # actually delete or move"
  echo "  3) Deduplicate safely (move extras to quarantine; dry-run by default):"
  echo "       ./deduplicate.sh --from-report \"$dupes_txt\" --keep newest --quarantine quarantine-$DATE_TAG"
  echo
}

# ───────────────────────── Execute ─────────────────────────
main
