#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Root dir ────────────────────────
# FIX: all dirs were relative ("hashes", "logs", "zero-length") which broke
# direct CLI calls from outside the repo root. Now all paths are anchored
# to ROOT_DIR so hasher.sh works correctly regardless of working directory.
ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# ───────────────────────── Constants ───────────────────────
HASHES_DIR="$ROOT_DIR/hashes"
LOGS_DIR="$ROOT_DIR/logs"
VAR_DIR="$ROOT_DIR/var"
# FIX: ZERO_DIR moved from repo root into var/ to consolidate working files
ZERO_DIR="$VAR_DIR/zero-length"
# v1.3.3: hasher.sh owns its own pidfile (same path the launcher checks),
# written at start of main() and removed by the cleanup trap. This replaces
# the launcher's broken "( wait $bgpid; clear_pidfile ) &" subshell, which
# cleared the pidfile almost immediately because a subshell cannot wait on a
# sibling process.
HASHER_PIDFILE="$VAR_DIR/hasher.pid"

# DATE_TAG is kept for human-facing daily reports
DATE_TAG="$(date +'%Y-%m-%d')"
# CSV_TAG adds time (SMB-safe; no colon) to avoid same-day collisions
CSV_TAG="$(date +'%F-%H%M')"
OUTPUT="$HASHES_DIR/hasher-$CSV_TAG.csv"

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

# Parallel hashing workers (v1.2.0). 1 = serial (historical behaviour).
# Overridable via --jobs N, HASH_JOBS env, or [performance] jobs in hasher.conf.
# Precedence: --jobs flag > hasher.conf > HASH_JOBS env > default (1).
HASH_JOBS="${HASH_JOBS:-1}"

# Default excludes (kept minimal; comment out if undesired)
DEFAULT_EXCLUDES=( "#recycle" "@eaDir" ".DS_Store" "lost+found" )
EXTRA_EXCLUDES=()

# ───────────────────────── Colors ──────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───────────────────────── Platform Shims ──────────────────
# Detect BSD stat (macOS) vs GNU stat (Linux/BusyBox/Synology)
# and sha256sum vs shasum -a 256, so hasher runs on both platforms
# without requiring GNU coreutils to be installed via Brew.
if stat -c "%s" /dev/null >/dev/null 2>&1; then
  # GNU stat (Linux, BusyBox, Synology DSM)
  _stat_size()  { stat -c "%s" -- "$1"; }
  _stat_mtime() { stat -c "%Y" -- "$1"; }
else
  # BSD stat (macOS)
  _stat_size()  { stat -f "%z" -- "$1"; }
  _stat_mtime() { stat -f "%m" -- "$1"; }
fi

# Detect sha256sum vs shasum (macOS ships shasum, not sha256sum)
_resolve_hash_cmd() {
  local algo="$1"
  case "$algo" in
    sha256)
      if command -v sha256sum >/dev/null 2>&1; then
        echo "sha256sum"
      elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 256"
      else
        echo ""
      fi
      ;;
    sha1)
      if command -v sha1sum >/dev/null 2>&1; then
        echo "sha1sum"
      elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 1"
      else
        echo ""
      fi
      ;;
    sha512)
      if command -v sha512sum >/dev/null 2>&1; then
        echo "sha512sum"
      elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 512"
      else
        echo ""
      fi
      ;;
    md5)
      if command -v md5sum >/dev/null 2>&1; then
        echo "md5sum"
      elif command -v md5 >/dev/null 2>&1; then
        echo "md5 -r"   # macOS md5 with -r gives same "hash  path" format
      else
        echo ""
      fi
      ;;
    blake2)
      if command -v b2sum >/dev/null 2>&1; then
        echo "b2sum"
      else
        echo ""
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

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
# Auto-load local/hasher.conf if present and no --config provided
if [[ -z "$CONFIG_FILE" && -f "$ROOT_DIR/local/hasher.conf" ]]; then
  CONFIG_FILE="$ROOT_DIR/local/hasher.conf"
elif [[ -z "$CONFIG_FILE" && -f "$ROOT_DIR/default/hasher.conf" ]]; then
  CONFIG_FILE="$ROOT_DIR/default/hasher.conf"
fi

# ───────────────────────── Human-friendly time ─────────────
human_dur() {
  local s="${1:-0}"
  case "$s" in
    ''|*[!0-9]*) s=0 ;;
  esac
  local h=$((s/3600))
  local m=$(((s%3600)/60))
  if (( h > 0 )); then
    printf "%dh %02dm" "$h" "$m"
  elif (( m > 0 )); then
    printf "%dm" "$m"
  else
    printf "%ds" "$s"
  fi
}

# ───────────────────────── Run ID ──────────────────────────
if command -v uuidgen >/dev/null 2>&1; then
  RUN_ID="$(uuidgen)"
elif [[ -r /proc/sys/kernel/random/uuid ]]; then
  RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
else
  RUN_ID="$(date +%s)-$$"
fi

# Derived paths
MAIN_LOG="$LOGS_DIR/hasher.log"
RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
# FIX: FILES_LIST moved from logs/ to var/ — it's a working/temp file, not a log
FILES_LIST="$VAR_DIR/files-$RUN_ID.lst"
BACKGROUND_LOG="$LOGS_DIR/background.log"

# ───────────────────────── Setup dirs ──────────────────────
mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$VAR_DIR" "$ZERO_DIR"

# ───────────────────────── Logging ─────────────────────────
_log() {
  local lvl="$1"; shift
  local msg="$*"
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [RUN $RUN_ID] [$lvl] $msg"
  case "$lvl" in
    INFO)  echo -e "${GREEN}$line${NC}";;
    WARN)  echo -e "${YELLOW}$line${NC}";;
    ERROR) echo -e "${RED}$line${NC}";;
    *)     echo "$line";;
  esac
  printf '%s\n' "$line" >> "$MAIN_LOG"
  printf '%s\n' "$line" >> "$RUN_LOG"
}

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
#              exclude=PATTERN  (or bare line "PATTERN" with no '=' )
# Other sections/keys are ignored without warnings.
load_config() {
  local f="$1"
  [[ -f "$f" ]] || { warn "Config not found: $f (ignoring)"; return; }

  local section=""

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" || "${line:0:1}" == ";" ]] && continue

    if [[ "$line" =~ ^\[[^][]+\]$ ]]; then
      section="${line:1:${#line}-2}"
      section="$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]')"
      continue
    fi

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
      "performance")
        case "$key" in
          # v1.2.0: parallel hashing worker count
          jobs|hash-jobs|hash_jobs) HASH_JOBS="$val" ;;
          *)                        : ;;
        esac
        ;;
      *) : ;;
    esac
  done < "$f"

  # reconcile paths after possible dir changes
  mkdir -p "$HASHES_DIR" "$LOGS_DIR" "$VAR_DIR" "$ZERO_DIR"
  MAIN_LOG="$LOGS_DIR/hasher.log"
  RUN_LOG="$LOGS_DIR/hasher-$RUN_ID.log"
  FILES_LIST="$VAR_DIR/files-$RUN_ID.lst"
  BACKGROUND_LOG="$LOGS_DIR/background.log"

  # re-derive default OUTPUT if still using default pattern or blank
  if [[ -z "$OUTPUT" \
     || "$OUTPUT" == "$ROOT_DIR/hashes/hasher-$DATE_TAG.csv" \
     || "$OUTPUT" == "$ROOT_DIR/hashes/hasher-$CSV_TAG.csv" ]]; then
    OUTPUT="$HASHES_DIR/hasher-$CSV_TAG.csv"
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
  --config FILE      Load settings from FILE (default: local/hasher.conf if present).
  --help             Show this help.

Behavior:
  * Writes CSV with header to: \$OUTPUT (unless --zero-length-only)
  * Logs: $MAIN_LOG (global), $RUN_LOG (per run), progress to $BACKGROUND_LOG
  * Working files: $VAR_DIR
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
    --jobs)     HASH_JOBS="${2:-1}"; shift ;;
    --exclude)  EXTRA_EXCLUDES+=("${2:-}"); shift ;;
    --zero-length-only) ZERO_LENGTH_ONLY=true ;;
    --config)   CONFIG_FILE="${2:-}"; shift ;;
    --child)    IS_CHILD=true ;;
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
  args+=( --algo "$ALGO" --output "$OUTPUT" --level "$LOG_LEVEL" --interval "$PROGRESS_INTERVAL" --jobs "$HASH_JOBS" )
  # FIX (v1.1.10): "${arr[@]}" on an empty array errors under set -u in
  # bash 3.2 (Apple's stock /bin/bash) and 4.0–4.3. The :- guard is the
  # portable form for safe-on-empty array iteration. Same fix as line ~425.
  for ex in "${EXTRA_EXCLUDES[@]:-}"; do
    [[ -n "$ex" ]] && args+=( --exclude "$ex" )
  done
  $ZERO_LENGTH_ONLY && args+=( --zero-length-only )

  nohup "${args[@]}" >>"$BACKGROUND_LOG" 2>&1 < /dev/null &
  bgpid=$!
  echo "Hasher started with nohup (PID $bgpid). Output: ${ZERO_LENGTH_ONLY:+(zero-length-only mode) }$OUTPUT"
  exit 0
fi

# ───────────────────────── Hash Tool Map ───────────────────
# Use platform-aware resolver (supports both GNU and BSD/macOS toolchains)
hash_cmd_str="$(_resolve_hash_cmd "$ALGO")"
if [[ -z "$hash_cmd_str" ]]; then
  case "$ALGO" in
    blake2) error "blake2 requested but 'b2sum' not found in PATH"; exit 1 ;;
    *)      error "No hash tool found for algo '$ALGO' (tried sha256sum, shasum, md5sum, md5)"; exit 1 ;;
  esac
fi
# Split into array so multi-word commands (e.g. "shasum -a 256") work correctly
read -ra hash_cmd <<< "$hash_cmd_str"
# Verify the resolved command is actually callable
command -v "${hash_cmd[0]}" >/dev/null 2>&1 || { error "Hash tool '${hash_cmd[0]}' not found in PATH"; exit 1; }

# ───────────────────────── Build File List ─────────────────
build_file_list() {
  : > "$FILES_LIST"
  local had_input=false
  # FIX (v1.1.10): track how many pathfile entries actually resolved to
  # something on disk. Previously, if every path in paths.txt was missing
  # (e.g. the external disk wasn't mounted), each one warned, the script
  # continued, found 0 files post-exclude, and reported "Hashed 0/0" as
  # if it had succeeded. That looked like a hang or a silent failure.
  # We now exit non-zero with a clear message when no paths were valid.
  local pathfile_seen=0     # non-blank, non-comment lines in paths.txt
  local pathfile_valid=0    # of those, how many were a readable dir or file

  if [[ -n "$PATHFILE" ]]; then
    if [[ ! -r "$PATHFILE" ]]; then
      error "Cannot read --pathfile '$PATHFILE'"; exit 1
    fi
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      local path="${raw#"${raw%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
      [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
      pathfile_seen=$((pathfile_seen + 1))
      if [[ -d "$path" ]]; then
        # FIX (v1.1.11): find can return non-zero on paths that pass [[ -d ]]
        # but can't actually be walked. The most common trigger is the macOS
        # phantom-mount-point pattern: an unmounted external volume leaves
        # an empty stub directory under /Volumes/ that satisfies [[ -d ]]
        # but I/O-errors when find descends into it. BSD find also returns
        # 1 on permission-denied subtrees. Without the '|| true' guard,
        # set -e kills the script silently with no error reaching the log
        # — which is exactly what users have hit. The 2>/dev/null suppresses
        # the noise on stderr; we capture failure into a flag and warn.
        local find_status=0
        find "$path" -type f -print0 2>/dev/null || find_status=$?
        if [[ "$find_status" -ne 0 ]]; then
          warn "find failed on '$path' (exit $find_status) — possibly an unmounted volume stub or unreadable subtree. Skipping."
        else
          pathfile_valid=$((pathfile_valid + 1))
        fi
      elif [[ -f "$path" ]]; then
        printf '%s\0' "$path"
        pathfile_valid=$((pathfile_valid + 1))
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

  # FIX (v1.1.10): fail loudly when paths.txt was provided but every path
  # listed in it is missing or unreadable. Stdin-piped invocations bypass
  # this check (we can't tell a legitimately-empty stream from an
  # all-missing one, and stdin is the advanced path).
  if [[ "$pathfile_seen" -gt 0 && "$pathfile_valid" -eq 0 ]]; then
    error "All $pathfile_seen path(s) listed in '$PATHFILE' are missing or unreadable."
    error "Common causes: external drive not mounted, typo in volume name, NAS share not connected."
    error "Check 'ls /Volumes' (macOS), 'ls /mnt' or 'ls /media' (Linux), or 'ls /volume1' (Synology)."
    exit 3
  fi

  local pre_count=0
  [[ -s "$FILES_LIST".tmp ]] && pre_count=$(tr -cd '\0' < "$FILES_LIST".tmp | wc -c | tr -d ' ')

  # Apply excludes (literal substring match)
  # FIX (v1.1.10): "${EXTRA_EXCLUDES[@]}" raises 'unbound variable' under
  # set -u on bash 3.2 (Apple stock /bin/bash, Synology DSM) when the
  # array is empty, even though the array IS declared at top of file.
  # The :- guard makes empty-array expansion safe. The trailing filter
  # then drops the empty-string sentinel that the :- expansion produces.
  local raw_patterns=("${DEFAULT_EXCLUDES[@]:-}" "${EXTRA_EXCLUDES[@]:-}")
  local patterns=()
  for _p in "${raw_patterns[@]}"; do
    [[ -n "$_p" ]] && patterns+=("$_p")
  done
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
  local f="$OUTPUT"
  local dir; dir="$(dirname "$f")"
  mkdir -p "$dir"
  if [[ ! -e "$f" || ! -s "$f" ]]; then
    printf 'path,size_bytes,mtime_epoch,algo,hash\n' > "$f"
    return
  fi
  local first; first="$(head -n1 "$f" 2>/dev/null || echo)"
  if [[ "$first" != "path,size_bytes,mtime_epoch,algo,hash" ]]; then
    local tmp="$f.tmp.$$"
    { printf 'path,size_bytes,mtime_epoch,algo,hash\n'; cat "$f"; } > "$tmp" && mv -f -- "$tmp" "$f"
  fi
}

append_csv_row() {
  local path="$1" size="$2" mtime="$3" algo="$4" hash="$5"
  printf '%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$path")" "$size" "$mtime" "$algo" "$hash" >> "$OUTPUT"
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
      printf '[%s] [RUN %s] [PROGRESS] Hashing: [%s%%] %s/%s | elapsed=%02d:%02d:%02d (%s) eta=%02d:%02d:%02d (%s)\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$done" "$total" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        "$(human_dur "$elapsed")" \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) \
        "$(human_dur "$eta")" >> "$BACKGROUND_LOG"
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
  # FIX: ZERO_PROGRESS_FILE moved from logs/ to var/ — it's a transient counter, not a log
  ZERO_PROGRESS_FILE="$VAR_DIR/zero-scan-$RUN_ID.count"
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
      printf '[%s] [RUN %s] [PROGRESS] Zero-scan: [%s%%] %s/%s | elapsed=%02d:%02d:%02d (%s) eta=%02d:%02d:%02d (%s)\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" "$RUN_ID" "$pct" "$count" "$total" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        "$(human_dur "$elapsed")" \
        $((eta/3600)) $((eta%3600/60)) $((eta%60)) \
        "$(human_dur "$eta")" >> "$BACKGROUND_LOG"
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

cleanup() {
  stop_hash_progress
  stop_zero_progress
  # Clean up any leftover working files for this run
  rm -f -- "$FILES_LIST" "$FILES_LIST.tmp" "$FILES_LIST.stdin.tmp" 2>/dev/null || true
  # v1.3.3: hasher.sh now OWNS its pidfile. Remove it on exit (any exit:
  # success, error, or signal) so the duplicate-run guard reflects reality.
  # Only remove it if it still holds OUR pid — avoids deleting a pidfile a
  # newer run may have written if PIDs were somehow reused.
  if [ -n "${HASHER_PIDFILE:-}" ] && [ -f "$HASHER_PIDFILE" ]; then
    _pf="$(cat "$HASHER_PIDFILE" 2>/dev/null || true)"
    [ "$_pf" = "$$" ] && rm -f -- "$HASHER_PIDFILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ───────────────────────── Main Hashing ────────────────────
TOTAL=0
DONE=0
FAIL=0

main() {
  # v1.3.3: claim the pidfile for this process. mkdir -p in case var/ is fresh.
  mkdir -p "$VAR_DIR" 2>/dev/null || true
  printf '%s\n' "$$" > "$HASHER_PIDFILE" 2>/dev/null || true
  info "Run-ID: $RUN_ID"
  [[ -n "$CONFIG_FILE" ]] && info "Config file: $CONFIG_FILE"
  info "Config: ${PATHFILE:+pathfile=$PATHFILE} | Algo: $ALGO | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"
  info "Output CSV: $OUTPUT"
  info "Working dir: $VAR_DIR"
  $ZERO_LENGTH_ONLY && info "Mode: ZERO-LENGTH-ONLY (no hashing)"

  build_file_list

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
    bglog INFO "NEXT: Review (dry-run): bin/delete-zero-length.sh --report \"$out\" --dry-run"
    bglog INFO "NEXT: Delete: bin/delete-zero-length.sh --report \"$out\" --force"

    echo
    echo -e "${GREEN}[RECOMMENDED NEXT STEPS]${NC}"
    echo "  1) Review what would be affected (no changes made):"
    echo "       bin/delete-zero-length.sh --report \"$out\" --dry-run"
    echo "  2) Delete, or move to quarantine instead of deleting:"
    echo "       bin/delete-zero-length.sh --report \"$out\" --force"
    echo "       bin/delete-zero-length.sh --report \"$out\" --force --quarantine"
    echo
    return
  fi

  # ───── Normal hashing path ───────────────────────────────
  write_csv_header
  start_hash_progress

  local start_ts
  start_ts=$(date +%s)

  # PARALLEL HASHING (v1.2.0)
  # ─────────────────────────
  # HASH_JOBS controls worker parallelism. 1 = serial (identical to the
  # historical behaviour). >1 fans the file list out to N workers via xargs,
  # each doing stat+hash and emitting a CSV row. Rationale: the serial loop
  # forks 3 processes per file (two stat, one hash binary); on large
  # small-file corpora (photo libraries) this fork overhead — not the hashing
  # itself — dominates wall-clock. Parallelism recovers most of it on
  # multi-core NAS units and SSD/SHR arrays. Single-spindle HDD users should
  # keep HASH_JOBS low (1-2) to avoid seek thrashing; that's why the default
  # is a conservative cap rather than full nproc.
  #
  # Atomicity: each worker writes one CSV row per file via a single printf.
  # POSIX guarantees writes up to PIPE_BUF (>=512, 4096 on Linux) to a pipe
  # are atomic, and a CSV row is well under that, so rows from concurrent
  # workers do not interleave. Failure rows are emitted to stderr-channel as
  # a sentinel the parent counts.

  local jobs="${HASH_JOBS:-1}"
  # sanitise: must be a positive integer
  case "$jobs" in (''|*[!0-9]*) jobs=1 ;; esac
  [[ "$jobs" -lt 1 ]] && jobs=1

  if [[ "$jobs" -gt 1 ]]; then
    info "Parallel hashing enabled: $jobs workers."
  fi

  # The worker: reads ONE file path as $1, stats + hashes it, prints a CSV row
  # on success, or a FAIL sentinel line (prefixed with the NUL-safe marker) on
  # failure. Exported into the environment for `bash -c` invocation by xargs.
  # We pass ALGO and the hash command through the environment.
  _hash_worker() {
    local f="$1"
    local size mtime line hash
    size=$(_stat_size "$f" 2>/dev/null || echo -1)
    mtime=$(_stat_mtime "$f" 2>/dev/null || echo -1)
    if [[ "$size" -lt 0 || "$mtime" -lt 0 ]]; then
      printf '\037FAIL\037stat\t%s\n' "$f"   # \037 = unit separator, unlikely in paths
      return 0
    fi
    if ! line=$("${hash_cmd[@]}" -- "$f" 2>/dev/null); then
      printf '\037FAIL\037hash\t%s\n' "$f"
      return 0
    fi
    hash="${line%% *}"
    # csv_escape inline (worker runs in a subshell that has the function)
    local esc="${f//\"/\"\"}"
    printf '"%s",%s,%s,%s,%s\n' "$esc" "$size" "$mtime" "$ALGO" "$hash"
  }
  export -f _hash_worker _stat_size _stat_mtime 2>/dev/null || true
  export ALGO
  # hash_cmd is an array; export its serialised form and rebuild in workers
  export HASH_CMD_STR="${hash_cmd[*]}"

  # Stream: NUL-delimited file list → xargs → workers → tee into a post-processor
  # that splits CSV rows (to $OUTPUT) from FAIL sentinels (counted).
  local fail_file="$VAR_DIR/hash-fails.$$"
  : > "$fail_file"

  if [[ "$jobs" -gt 1 ]]; then
    # Parallel path via xargs -P. We invoke a tiny bash -c per file that
    # rebuilds the hash_cmd array from HASH_CMD_STR and calls the worker.
    # -n 1 keeps the per-file granularity (simplest correct mapping); the
    # fork cost of bash -c is offset by the parallelism for large corpora.
    xargs -0 -P "$jobs" -n 1 bash -c '
      read -ra hash_cmd <<< "$HASH_CMD_STR"
      _hash_worker "$1"
    ' _ < "$FILES_LIST" \
    | while IFS= read -r row; do
        case "$row" in
          $'\037'FAIL$'\037'*)
            printf '%s\n' "$row" >> "$fail_file"
            ;;
          *)
            printf '%s\n' "$row" >> "$OUTPUT"
            ;;
        esac
      done
  else
    # Serial path: preserve exact historical behaviour, no bash -c overhead.
    while IFS= read -r -d '' f; do
      local out
      out="$(_hash_worker "$f")"
      case "$out" in
        $'\037'FAIL$'\037'*)
          printf '%s\n' "$out" >> "$fail_file"
          ;;
        *)
          printf '%s\n' "$out" >> "$OUTPUT"
          ;;
      esac
    done < "$FILES_LIST"
  fi

  # Tally results
  local hashed_rows fail_rows
  hashed_rows=$(( $(wc -l < "$OUTPUT" 2>/dev/null || echo 1) - 1 ))   # minus header
  [[ "$hashed_rows" -lt 0 ]] && hashed_rows=0
  fail_rows=$(wc -l < "$fail_file" 2>/dev/null | tr -d ' ' || echo 0)
  [[ -z "$fail_rows" ]] && fail_rows=0

  # Emit per-failure warnings (kept concise; full list is in the fail file)
  if [[ "$fail_rows" -gt 0 ]]; then
    while IFS= read -r fl; do
      local kind path
      kind="${fl#$'\037'FAIL$'\037'}"; kind="${kind%%$'\t'*}"
      path="${fl#*$'\t'}"
      # portable: don't use bash-4 ${kind^}; just print the kind as-is
      warn "$kind failed: $path"
    done < "$fail_file"
  fi
  rm -f -- "$fail_file" 2>/dev/null || true

  DONE=$(( hashed_rows + fail_rows ))
  FAIL="$fail_rows"

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

  if [[ -f "$csv" ]]; then
    awk '
      NR==1 { next }
      {
        s=$0
        n=0; pos=0
        while ( (i=index(substr(s,pos+1),",")) > 0 ) {
          pos += i; n++; c[n]=pos
        }
        if (n < 4) next
        c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
        path = substr(s,1,c1-1)
        size = substr(s,c1+1,c2-c1-1)
        if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }
        if (size+0==0) print path
        for (k=1;k<=n;k++) delete c[k]
      }
    ' "$csv" > "$zero_txt" || true
  fi

  awk '
    BEGIN{ OFS="," }
    NR==1 { next }
    {
      s=$0
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
  echo "  1) Find duplicate folders (highest value, lowest risk):"
  echo "       bin/find-duplicate-folders.sh --input \"$csv\""
  echo "  2) Find and review duplicate files:"
  echo "       bin/find-duplicates.sh --input \"$csv\""
  echo "       bin/review-duplicates.sh --from-report \"$dupes_txt\""
  echo "  3) Remove zero-length files (review first, no changes):"
  echo "       bin/delete-zero-length.sh --report \"$zero_txt\" --dry-run"
  echo "       bin/delete-zero-length.sh --report \"$zero_txt\" --force"
  echo
}

# ───────────────────────── Execute ─────────────────────────
main
