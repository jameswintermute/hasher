#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute <jameswintermute@protonmail.ch>
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

# Optional config (CLI can override)
CONFIG_FILE=""

# Progress interval (seconds) for background.log
PROGRESS_INTERVAL=15

# Default excludes (kept minimal; comment out if undesired)
DEFAULT_EXCLUDES=( "#recycle" "@eaDir" ".DS_Store" "lost+found" )
EXTRA_EXCLUDES=()

# ───────────────────────── Colors ──────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───────────────────────── Pre-scan for --config ───────────
if (( "$#" > 0 )); then
  i=1
  while (( i <= $# )); do
    eval _arg="\${$i}"
    if [[ "$_arg" == "--config" ]]; then
      j=$((i+1)); eval CONFIG_FILE="\${$j}"
      break
    fi
    i=$((i+1))
  done
fi
# Auto-load ./hasher.conf if present and no --config provided
if [[ -z "$CONFIG_FILE" && -f "./hasher.conf" ]]; then
  CONFIG_FILE="./hasher.conf"
fi

# ───────────────────────── Run ID ──────────────────────────
if command -v uuidgen >/dev/null 2>&1; then
  RUN_ID="$(uuidgen)"
elif [[ -r /proc/sys/kernel/random/uuid ]]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$"
fi

# Derived paths (will be reconciled by load_config if config changes dirs)
MAIN_LOG="$LOGS_DIR/hasher.log"
RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
FILES_LIST="$LOGS_DIR/files-$RUN_ID.lst"
BACKGROUND_LOG="$LOGS_DIR/background.log"

# ───────────────────────── Setup dirs ──────────────────────
mkdir -p "$HASHES_DIR" "$LOGS_DIR"

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

# ───────────────────────── Config loader ───────────────────
# INI-aware. Supported:
#   [setup]    algo, pathfile, output, hashes_dir, logs_dir
#   [logging]  level, background-interval, xtrace
#   [exclusions]
#              inherit-defaults=true|false
#              exclude=PATTERN  (or bare line "PATTERN" with no '=')
# Other sections/keys are ignored without warnings.
load_config() {
  local f="$1"
  [[ -f "$f" ]] || { warn "Config not found: $f (ignoring)"; return; }

  local section=""
  local inherit_defaults="true"

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    # trim
    local line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" || "${line:0:1}" == ";" ]] && continue

    # section?
    if [[ "$line" =~ ^\[[^][]+\]$ ]]; then
      section="${line:1:${#line}-2}"
      section="$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]')"
      continue
    fi

    # key=value or bare value
    local key val
    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"; val="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"; key="${key#"${key%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"; val="${val#"${val%%[![:space:]]*}"}"
      [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]] && val="${val:1:-1}"
      [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]] && val="${val:1:-1}"
      key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    else
      key="__bare__"
      val="$line"
    fi

    case "$section" in
      ""|"setup")
        case "$key" in
          algo)          ALGO="$val" ;;
          pathfile)      PATHFILE="$val" ;;
          output)        OUTPUT="$val" ;;
          hashes_dir)    HASHES_DIR="$val" ;;
          logs_dir)      LOGS_DIR="$val" ;;
          level)         LOG_LEVEL="$val" ;;              # allow in root
          interval|background-interval) PROGRESS_INTERVAL="$val" ;;
          exclude)       EXTRA_EXCLUDES+=("$val") ;;
          __bare__)      : ;;                             # ignore bare in root/setup
          *)             : ;;                             # ignore unknown, no warning
        esac
        ;;
      "logging")
        case "$key" in
          level)         LOG_LEVEL="$val" ;;
          background-interval|interval) PROGRESS_INTERVAL="$val" ;;
          xtrace)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              1|true|yes|on) set -x ;;
            esac
            ;;
          *)             : ;;
        esac
        ;;
      "exclusions")
        case "$key" in
          inherit-defaults)
            v="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
            case "$v" in
              0|false|no|off) inherit_defaults="false" ;;
              *)              inherit_defaults="true" ;;
            esac
            ;;
          exclude)        EXTRA_EXCLUDES+=("$val") ;;
          __bare__)       EXTRA_EXCLUDES+=("$val") ;;   # each bare line is a pattern
          *)              : ;;
        esac
        ;;
      # other sections accepted silently
      *)
        : 
        ;;
    esac
  done < "$f"

  # Handle inherit-defaults=false
  if [[ "$inherit_defaults" == "false" ]]; then
    DEFAULT_EXCLUDES=()
  fi

  # reconcile paths after possible dir changes
  mkdir -p "$HASHES_DIR" "$LOGS_DIR"
  MAIN_LOG="$LOGS_DIR/hasher.log"
  RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
  FILES_LIST="$LOGS_DIR/files-$RUN_ID.lst"
  BACKGROUND_LOG="$LOGS_DIR/background.log"

  # re-derive default OUTPUT if still using default pattern or blank
  if [[ "$OUTPUT" == "hashes/hasher-$DATE_TAG.csv" || -z "$OUTPUT" ]]; then
    OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"
  fi
}

# Apply config early (before arg parsing), if set
[[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"

# ───────────────────────── Arg Parsing ─────────────────────
usage() {
  cat <<EOF
Usage: $0 [--pathfile FILE] [--algo sha256|sha1|sha512|md5|blake2] [--output CSV]
          [--nohup] [--level info|warn|error] [--interval SECONDS]
          [--exclude PATTERN ...] [--config FILE] [--help]

Options:
  --pathfile FILE    File containing one path (dir or file) per line. Required unless paths are piped.
  --algo ALG         Hash algorithm (default: sha256).
  --output CSV       Output CSV path (default: $OUTPUT).
  --nohup            Re-exec under nohup (background) with logs to $BACKGROUND_LOG.
  --level LEVEL      Log level threshold (info|warn|error). Default: info.
  --interval N       Progress update interval seconds (default: $PROGRESS_INTERVAL).
  --exclude P        Extra exclude pattern(s). Repeatable. (Literal substring match)
  --config FILE      Load settings from FILE (default: ./hasher.conf if present).
  --help             Show this help.

Behavior:
  * Writes CSV with header to: \$OUTPUT
  * Logs: $MAIN_LOG (global), $RUN_LOG (per run), progress to $BACKGROUND_LOG
  * Creates file list at: $FILES_LIST
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pathfile) PATHFILE="$2"; shift ;;
    --algo)     ALGO="$2"; shift ;;
    --output)   OUTPUT="$2"; shift ;;
    --nohup)    RUN_IN_BACKGROUND=true ;;
    --level)    LOG_LEVEL="$2"; shift ;;
    --interval) PROGRESS_INTERVAL="$2"; shift ;;
    --exclude)  EXTRA_EXCLUDES+=("$2"); shift ;;
    --config)   CONFIG_FILE="${2:-}"; shift ;;  # kept to allow nohup propagation
    --child)    IS_CHILD=true ;;          # internal
    -h|--help)  usage; exit 0 ;;
    *) error "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# ───────────────────────── Nohup Re-exec ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  export IS_CHILD=true
  # Build args safely with an array (IFS excludes spaces)
  args=( "$0" --child )
  [[ -n "$CONFIG_FILE" ]] && args+=( --config "$CONFIG_FILE" )
  [[ -n "$PATHFILE" ]]    && args+=( --pathfile "$PATHFILE" )
  args+=( --algo "$ALGO" --output "$OUTPUT" --level "$LOG_LEVEL" --interval "$PROGRESS_INTERVAL" )
  for ex in "${EXTRA_EXCLUDES[@]}"; do args+=( --exclude "$ex" ); done

  nohup "${args[@]}" >>"$BACKGROUND_LOG" 2>&1 < /dev/null &
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

  # If stdin is a pipe, also accept paths (NUL- or newline-delimited) — portable check
  if [ ! -t 0 ]; then
    had_input=true
    local tmp_in="$FILES_LIST.stdin.tmp"
    # Buffer stdin to a temp file so probing doesn't consume the stream
    cat > "$tmp_in"
    # Probe: read with -d '' (NUL delimiter); success ⇒ contains at least one NUL
    if IFS= read -r -d '' _peek < "$tmp_in"; then
      # NUL-delimited: append as-is
      cat "$tmp_in" >> "$FILES_LIST".tmp
    else
      # newline-delimited: convert to NUL-delimited
      while IFS= read -r p || [[ -n "$p" ]]; do
        [[ -z "$p" ]] && continue
        printf '%s\0' "$p"
      done < "$tmp_in" >> "$FILES_LIST".tmp
    fi
    rm -f -- "$tmp_in" 2>/dev/null || true
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
        # Capture pattern args, then clear them from ARGV so remaining ARGV
        # (the files list) is still read as input.
        for(i=1;i<=N;i++){
          pat[i]=ARGV[i]
          ARGV[i]=""
        }
      }
      {
        keep=1
        for(i=1;i<=N;i++){
          if (pat[i] != "" && index($0, pat[i])>0) { keep=0; break }
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
  [[ -n "$CONFIG_FILE" ]] && info "Config file: $CONFIG_FILE"
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

  # Zero-length list from CSV (detect size column) — POSIX-safe blank filtering
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
    ' "$csv" | grep -v '^[[:space:]]*$' > "$zero_txt" || true
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
