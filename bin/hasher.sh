#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Constants ───────────────────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
ZERO_DIR="zero-length"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"

ALGO="sha256"        # sha256|sha1|sha512|md5|blake2
PATHFILE=""
RUN_IN_BACKGROUND=false
IS_CHILD=false       # set when re-exec'ed under nohup
LOG_LEVEL="info"     # info|warn|error
ZERO_LENGTH_ONLY=false

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
mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$ZERO_DIR"

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

# extra: write directly to background.log (no color)
bglog() {
  local lvl="$1"; shift
  local msg="$*"
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RUN %s] [%s] %s\n' "$ts" "$RUN_ID" "$lvl" "$msg" >> "$BACKGROUND_LOG"
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
          level)         LOG_LEVEL="$val" ;;
          interval|background-interval) PROGRESS_INTERVAL="$val" ;;
          exclude)       EXTRA_EXCLUDES+=("$val") ;;
          __bare__)      : ;;
          *)             : ;;
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
              0|false|no|off) DEFAULT_EXCLUDES=() ;;
              *)              : ;;
            esac
            ;;
          exclude)        EXTRA_EXCLUDES+=("$val") ;;
          __bare__)       EXTRA_EXCLUDES+=("$val") ;;
          *)              : ;;
        esac
        ;;
      *) : ;;
    esac
  done < "$f"

  # reconcile paths after possible dir changes
  mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$ZERO_DIR"
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
          [--exclude PATTERN ...] [--zero-length-only] [--config FILE] [--help]

Options:
  --pathfile FILE    File containing one path (dir or file) per line. Required unless paths are piped.
  --algo ALG         Hash algorithm (default: sha256).
  --output CSV       Output CSV path (default: $OUTPUT).
  --nohup            Re-exec under nohup (background) with logs to $BACKGROUND_LOG.
  --level LEVEL      Log level threshold (info|warn|error). Default: info.
  --interval N       Progress update interval seconds (default: $PROGRESS_INTERVAL).
  --exclude P        Extra exclude pattern(s). Repeatable. (Literal substring match)
  --zero-length-only Scan and output zero-length file list only, then exit (no hashing).
  --config FILE      Load settings from FILE (default: ./hasher.conf if present).
  --help             Show this help.

Behavior:
  * Writes CSV with header to: \$OUTPUT (unless --zero-length-only)
  * Logs: $MAIN_LOG (global), $RUN_LOG (per run), progress to $BACKGROUND_LOG
  * Creates file list at: $FILES_LIST
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pathfile) PATHFILE="${2:-}"; shift ;;
    --algo)     ALGO="${2:-}"; shift ;;
    --output)   OUTPUT="${2:-}"; shift ;;
    --nohup)    RUN_IN_BACKGROUND=true ;;
    --level)    LOG_LEVEL="${2:-}"; shift ;;
    --interval) PROGRESS_INTERVAL="${2:-}"; shift ;;
    --exclude)  EXTRA_EXCLUDES+=("${2:-}"); shift ;;
    --zero-length-only) ZERO_LENGTH_ONLY=true ;;
    --config)   CONFIG_FILE="${2:-}"; shift ;;  # kept to allow nohup propagation
    --child)    IS_CHILD=true ;;                # internal
    -h|--help)  usage; exit 0 ;;
    *) error "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

# ───────────────────────── Nohup Re-exec ───────────────────
if $RUN_IN_BACKGROUND && ! $IS_CHILD; then
  export IS_CHILD=true
  args=( "$0" --child )
  [[ -n "$CONFIG_FILE" ]] && args+=( --config "$CONFIG_FILE" )
  [[ -n "$PATHFILE"   ]] && args+=( --pathfile "$PATHFILE" )
  args+=( --algo "$ALGO" --output "$OUTPUT" --level "$LOG_LEVEL" --interval "$PROGRESS_INTERVAL" )
  for ex in "${EXTRA_EXCLUDES[@]}"; do args+=( --exclude "$ex" ); done
  $ZERO_LENGTH_ONLY && args+=( --zero-length-only )

  nohup "${args[@]}" >>"$BACKGROUND_LOG" 2>&1 < /dev/null &
  bgpid=$!
  echo "Hasher started with nohup (PID $bgpid). Output: ${ZERO_LENGTH_ONLY:+(zero-length-only mode) }$OUTPUT"
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
build_file_list() {
  : > "$FILES_LIST"
  local had_input=false

  if [[ -n "$PATHFILE" ]]; then
    if [[ ! -r "$PATHFILE" ]]; then
      error "Cannot read --pathfile '$PATHFILE'"; exit 1
    fi
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      local path="${raw#"${raw%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
      [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
      if [[ -d "$path" ]]; then
        find "$path" -type f -print0 2>/dev/null
      elif [[ -f "$path" ]]; then
        printf '%s\0' "$path"
      else
        warn "Path does not exist: $path"
      fi
    done < "$PATHFILE" >> "$FILES_LIST".tmp
    had_input=true
  fi

  # If stdin is a pipe, accept paths (NUL- or newline-delimited)
  if [ ! -t 0 ]; then
    had_input=true
    local tmp_in="$FILES_LIST.stdin.tmp"
    cat > "$tmp_in"
    if IFS= read -r -d '' _peek < "$tmp_in"; then
      cat "$tmp_in" >> "$FILES_LIST".tmp
    else
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

  local pre_count=0
  [[ -s "$FILES_LIST".tmp ]] && pre_count=$(tr -cd '\0' < "$FILES_LIST".tmp | wc -c | tr -d ' ')

  # Apply excludes (literal substring match)
  local patterns=("${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}")
  if (( ${#patterns[@]} > 0 )); then
    awk -v RS='\0' -v ORS='\0' -v N="${#patterns[@]}" '
      BEGIN{ for(i=1;i<=N;i++){ pat[i]=ARGV[i]; ARGV[i]="" } }
      { keep=1; for(i=1;i<=N;i++){ if (pat[i] != "" && index($0, pat[i])>0) { keep=0; break } }
        if(keep) printf "%s", $0 }
    ' "${patterns[@]}" "$FILES_LIST".tmp > "$FILES_LIST"
  else
    mv -f -- "$FILES_LIST".tmp "$FILES_LIST"
  fi

  local post_count=0
  [[ -s "$FILES_LIST" ]] && post_count=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
  if (( pre_count > 0 && post_count == 0 && ${#patterns[@]} > 0 )); then
    warn "Exclusion filter removed all $pre_count candidates; using unfiltered list this run. Review [exclusions] in hasher.conf."
    mv -f -- "$FILES_LIST".tmp "$FILES_LIST"
    post_count="$pre_count"
  fi

  rm -f -- "$FILES_LIST".tmp 2>/dev/null || true
}

# ───────────────────────── CSV Helpers ─────────────────────
csv_escape() { local s="$1"; s="${s//\"/\"\"}"; printf '"%s"' "$s"; }

write_csv_header() {
  if [[ ! -s "$OUTPUT" ]]; then
    printf 'path,size_bytes,mtime_epoch,algo,hash\n' > "$OUTPUT"
  fi
}

append_csv_row() {
  local path="$1" size="$2" mtime="$3" algo="$4" hash="$5"
  printf '%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$path")" "$size" "$mtime" "$ALGO" "$hash" >> "$OUTPUT"
}

# ───────────────────────── Progress Tickers ────────────────
T_START=0
hash_progress_pid=0
zero_progress_pid=0
ZERO_PROGRESS_FILE=""

start_hash_progress() {
  T_START=$(date +%s)
  (
    local total=0
    if [[ -s "$FILES_LIST" ]]; then
      total=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
    fi
    while :; do
      sleep "$PROGRESS_INTERVAL" || break
      local now elapsed rows done eta pct
      now=$(date +%s)
      elapsed=$(( now - T_START ))
      if [[ -f "$OUTPUT" ]]; then
        rows=$(wc -l < "$OUTPUT" | tr -d ' ')
        if (( rows > 1 )); then done=$(( rows - 1 )); else done=0; fi
      else
        done=0
      fi
      if (( total > 0 )); then
        pct=$(( done * 100 / total ))
        if (( done > 0 && done < total )); then
          eta=$(( elapsed * (total - done) / done ))
        else
          eta=0
        fi
      else
        pct=0; eta=0
      fi
      printf '[%s] [RUN %s] [PROGRESS] Hashing: [%s%%] %s/%s | elapsed=%02d:%02d:%02d eta=%02d:%02d:%02d\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$done" "$total" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) >> "$BACKGROUND_LOG"
    done
  ) &
  hash_progress_pid=$!
}

stop_hash_progress() {
  if [[ "$hash_progress_pid" -gt 0 ]] && kill -0 "$hash_progress_pid" 2>/dev/null; then
    kill "$hash_progress_pid" 2>/dev/null || true
    wait "$hash_progress_pid" 2>/dev/null || true
  fi
}

start_zero_progress() {
  T_START=$(date +%s)
  ZERO_PROGRESS_FILE="$LOGS_DIR/zero-scan-$RUN_ID.count"
  echo 0 > "$ZERO_PROGRESS_FILE"
  (
    local total=0 count=0 now elapsed eta pct
    if [[ -s "$FILES_LIST" ]]; then
      total=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
    fi
    while :; do
      sleep "$PROGRESS_INTERVAL" || break
      [[ -f "$ZERO_PROGRESS_FILE" ]] && count="$(cat "$ZERO_PROGRESS_FILE" 2>/dev/null || echo 0)" || count=0
      now=$(date +%s)
      elapsed=$(( now - T_START ))
      if (( total > 0 )); then
        pct=$(( count * 100 / total ))
        if (( count > 0 && count < total )); then
          eta=$(( elapsed * (total - count) / count ))
        else
          eta=0
        fi
      else
        pct=0; eta=0
      fi
      printf '[%s] [RUN %s] [PROGRESS] Zero-scan: [%s%%] %s/%s | elapsed=%02d:%02d:%02d eta=%02d:%02d:%02d\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$count" "$total" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) >> "$BACKGROUND_LOG"
    done
  ) &
  zero_progress_pid=$!
}

stop_zero_progress() {
  if [[ "$zero_progress_pid" -gt 0 ]] && kill -0 "$zero_progress_pid" 2>/dev/null; then
    kill "$zero_progress_pid" 2>/dev/null || true
    wait "$zero_progress_pid" 2>/dev/null || true
  fi
  [[ -n "$ZERO_PROGRESS_FILE" ]] && rm -f -- "$ZERO_PROGRESS_FILE" 2>/dev/null || true
}

# Clean shutdown
cleanup() {
  stop_hash_progress
  stop_zero_progress
}
trap cleanup EXIT

# ───────────────────────── Main Hashing ────────────────────
TOTAL=0
DONE=0
FAIL=0

main() {
  info "Run-ID: $RUN_ID"
  [[ -n "$CONFIG_FILE" ]] && info "Config file: $CONFIG_FILE"
  info "Config: ${PATHFILE:+pathfile=$PATHFILE} | Algo: $ALGO | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"
  info "Output CSV: $OUTPUT"
  $ZERO_LENGTH_ONLY && info "Mode: ZERO-LENGTH-ONLY (no hashing)"

  build_file_list

  # Count total
  if [[ -s "$FILES_LIST" ]]; then
    TOTAL=$(tr -cd '\0' < "$FILES_LIST" | wc -c | tr -d ' ')
  else
    TOTAL=0
  fi
  info "Discovered $TOTAL files to scan (post-exclude)."

  # ───── Fast path: zero-length-only (no hashing) ──────────
  if $ZERO_LENGTH_ONLY; then
    local out="$ZERO_DIR/zero-length-$DATE_TAG.txt"
    : > "$out"
    local n=0 m=0 nr=0
    local scanned=0

    bglog INFO "Zero-length-only scan starting: total=$TOTAL, report=$out"

    start_zero_progress
    while IFS= read -r -d '' f; do
      scanned=$((scanned+1)); echo "$scanned" > "$ZERO_PROGRESS_FILE"
      if [[ ! -e "$f" ]]; then
        m=$((m+1))
      elif [[ ! -f "$f" ]]; then
        nr=$((nr+1))
      elif [[ ! -s "$f" ]]; then
        echo "$f" >> "$out"
        n=$((n+1))
      fi
    done < "$FILES_LIST"
    stop_zero_progress

    info  "Zero-length-only scan complete."
    info  "  • Zero-length files now: $n"
    info  "  • Missing paths: $m | Not regular files: $nr"
    info  "  • Report: $out"

    bglog INFO "Zero-length-only scan complete: zero=$n, missing=$m, not_regular=$nr, report=$out"
    bglog INFO "NEXT: Review (dry-run): ./delete-zero-length.sh \"$out\""
    bglog INFO "NEXT: Delete: ./delete-zero-length.sh \"$out\" --force  |  Quarantine: ./delete-zero-length.sh \"$out\" --force --quarantine \"$ZERO_DIR/quarantine-$DATE_TAG\""

    echo
    echo -e "${GREEN}[RECOMMENDED NEXT STEPS]${NC}"
    echo "  1) Review or delete zero-length files (dry-run first):"
    echo "       ./delete-zero-length.sh \"$out\""
    echo "  2) Execute deletion safely (or move to quarantine):"
    echo "       ./delete-zero-length.sh \"$out\" --force"
    echo "       ./delete-zero-length.sh \"$out\" --force --quarantine \"$ZERO_DIR/quarantine-$DATE_TAG\""
    echo
    return
  fi

  # ───── Normal hashing path ───────────────────────────────
  write_csv_header
  start_hash_progress

  local start_ts
  start_ts=$(date +%s)

  while IFS= read -r -d '' f; do
    local size mtime
    size=$(stat -c%s -- "$f" 2>/dev/null || echo -1)
    mtime=$(stat -c%Y -- "$f" 2>/dev/null || echo -1)

    if [[ "$size" -lt 0 || "$mtime" -lt 0 ]]; then
      warn "Stat failed: $f"
      FAIL=$((FAIL+1))
      DONE=$((DONE+1))
      continue
    fi

    local line hash
    if ! line=$("$hash_cmd" -- "$f" 2>/dev/null); then
      warn "Hash failed: $f"
      FAIL=$((FAIL+1))
      DONE=$((DONE+1))
      continue
    fi
    hash="${line%% *}"

    append_csv_row "$f" "$size" "$mtime" "$ALGO" "$hash"
    DONE=$((DONE+1))
  done < "$FILES_LIST"

  local end_ts elapsed sH sM sS
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  sH=$((elapsed/3600)); sM=$((elapsed%3600/60)); sS=$((elapsed%60))

  stop_hash_progress

  info "Completed. Hashed $DONE/$TOTAL files (failures=$FAIL) in $(printf '%02d:%02d:%02d' "$sH" "$sM" "$sS"). CSV: $OUTPUT"

  post_run_reports "$OUTPUT" "$DATE_TAG"
}

# ───────────────────────── Post-run Reports ────────────────
post_run_reports() {
  local csv="$1"
  local date_tag="$2"

  mkdir -p "$LOGS_DIR" "$ZERO_DIR"

  local zero_txt="$ZERO_DIR/zero-length-$date_tag.txt"
  local dupes_txt="$LOGS_DIR/$date_tag-duplicate-hashes.txt"

  # CSV-safe: split each data line from the RIGHT by four commas to get
  # PATH,SIZE,MTIME,ALGO,HASH (only PATH may contain commas).
  if [[ -f "$csv" ]]; then
    awk '
      NR==1 { next } # skip header
      {
        s=$0
        # collect comma positions
        n=0; pos=0
        while ( (i=index(substr(s,pos+1),",")) > 0 ) {
          pos += i; n++; c[n]=pos
        }
        if (n < 4) next
        c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
        path = substr(s,1,c1-1)
        size = substr(s,c1+1,c2-c1-1)
        # mtime = substr(s,c2+1,c3-c2-1)   # not needed here
        # algo  = substr(s,c3+1,c4-c3-1)   # not needed here
        # hash  = substr(s,c4+1)           # not needed here
        # unquote path if quoted; unescape doubled quotes
        if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }
        if (size+0==0) print path
        # clear c[] for next record
        for (k=1;k<=n;k++) delete c[k]
      }
    ' "$csv" > "$zero_txt" || true
  fi

  # Duplicate groups by HASH, with member file list (CSV-safe right split again)
  awk '
    BEGIN{ OFS="," }
    NR==1 { next }
    {
      s=$0
      # collect comma positions
      n=0; pos=0
      while ( (i=index(substr(s,pos+1),",")) > 0 ) {
        pos += i; n++; c[n]=pos
      }
      if (n < 4) next
      c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
      path = substr(s,1,c1-1)
      hash = substr(s,c4+1)

      if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }
      gsub(/^[ \t]+|[ \t]+$/,"",hash)

      if (hash!="") {
        cnt[hash]++; files[hash]=files[hash]"\n"path
      }

      # clear c[] for next record
      for (k=1;k<=n;k++) delete c[k]
    }
    END{
      for (k in cnt) if (cnt[k]>1) {
        print "HASH " k " (" cnt[k] " files):"
        s=files[k]; sub(/^\n/,"",s)
        n=split(s,arr,"\n")
        for (i=1;i<=n;i++) print "  " arr[i]
        print ""
      }
    }
  ' "$csv" > "$dupes_txt" || true

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
  echo "       ./review-duplicates.sh --from-report \"$dupes_txt\" --keep newest"
  echo "  2) Remove zero-length files (dry-run first):"
  echo "       ./delete-zero-length.sh \"$zero_txt\"           # dry-run"
  echo "       ./delete-zero-length.sh \"$zero_txt\" --force   # actually delete or move"
  echo "  3) Duplicates (review then act):"
  echo "       ./find-duplicates.sh"
  echo "       ./review-duplicates.sh --from-report \"$dupes_txt\" --keep newest"
  echo "       # Dry-run action on your latest reviewed plan:"
  echo "       ./delete-duplicates.sh --from-plan \"$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)\""
  echo "       # Execute (move to quarantine or delete):"
  echo "       ./delete-duplicates.sh --from-plan \"$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)\" --force --quarantine \"quarantine-$DATE_TAG\""
  echo "       ./delete-duplicates.sh --from-plan \"$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)\" --force"
  echo
}

# ───────────────────────── Execute ─────────────────────────
main
