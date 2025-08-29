#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder (Review Duplicates)
# Copyright (C) 2025 James Wintermute <jameswinter@protonmail.ch>
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Defaults ─────────────────────────
HASH_DIR="hashes"
DUP_DIR="duplicate-hashes"
LOGS_DIR="logs"
CONFIG_FILE=""

# [logging] defaults (overridden by config)
PROGRESS_INTERVAL=15
LOG_LEVEL="info"    # debug|info|warn|error
XTRACE=false

# [review] defaults (overridden by config)
RV_MODE="interactive"         # interactive|export-only|plan-only|auto
RV_INPUT="latest"             # latest|<filename>
RV_SORT="count_desc"          # count_desc|size_desc|hash_asc
RV_SKIP_ZERO=true             # skip_zero_size
RV_MIN_MB="0.00"              # min_size_mb
RV_INCLUDE_REGEX=""           # include_regex (POSIX ERE)
RV_EXCLUDE_REGEX=""           # exclude_regex (POSIX ERE)
RV_SHOW_SIZES=true            # show_sizes
RV_SHOW_HASH="short"          # short|full
RV_PAUSE_EVERY=0              # pause_every groups (0 = no paging)
RV_AUTO_STRATEGY="none"       # none|keep-largest|keep-newest|keep-regex|keep-shortest-path
RV_AUTO_REGEX_KEEP=""         # regex for keep-regex
RV_REPORT_DIR="$DUP_DIR"      # report_dir
RV_PLAN_DIR="$DUP_DIR"        # plan_dir
RV_REPORT_PREFIX_DATE=true    # report_prefix_date
RV_SAFE_DELETE="rm"           # rm|move
RV_SAFE_DELETE_DIR=""         # required if move
RV_CONFIRM_PHRASE="YES"       # confirm phrase inside plan
RV_DRY_RUN=true               # dry_run (for auto/plan-only)

# runtime
RUN_ID=""
LOG_FILE=""
BACKGROUND_LOG=""
INPUT_FILE=""

# ───────────────────────── Utilities ─────────────────────────
ts(){ date '+%Y-%m-%d %H:%M:%S'; }
gen_run_id(){
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}
lvl_rank(){ case "$1" in debug)echo 10;;info)echo 20;;warn)echo 30;;error)echo 40;;*)echo 20;;esac; }
LOG_RANK="$(lvl_rank "$LOG_LEVEL")"
_log_core(){
  local level="$1"; shift
  local line; line=$(printf '[%s] [RUN %s] [%s] %s\n' "$(ts)" "$RUN_ID" "$level" "$*")
  printf '%s\n' "$line"
  { printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}
log(){ local level="$1"; shift||true; local want; want=$(lvl_rank "$level"); (( want >= LOG_RANK )) && _log_core "$level" "$@"; }
die(){ _log_core ERROR "$*"; exit 1; }

usage(){
  cat <<EOF
Usage:
  $(basename "$0") [--input hashes/hasher-YYYY-MM-DD.csv] [--config hasher.conf]

This tool reads hasher CSVs ("timestamp","path","algo","hash","size_mb"),
groups duplicates by hash, and produces a human report and a safe delete plan.
Behavior is controlled by [review] in hasher.conf (see repo README).

Modes (config [review].mode):
  interactive  : prompts per group
  export-only  : write report + plan, no prompts, no deletions
  plan-only    : write plan only, no report, no prompts
  auto         : choose deletions automatically per group (see auto_strategy)

EOF
}

# ───────────────────────── INI parser ─────────────────────────
parse_ini(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  local section="" line raw key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    raw="${line%%[#;]*}"
    raw="$(echo -n "$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$raw" ]] && continue
    if [[ "$raw" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1],,}"; continue; fi
    case "$section" in
      logging)
        if [[ "$raw" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
          key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
          case "$key" in
            background-interval|progress-interval) [[ "$val" =~ ^[0-9]+$ ]] && PROGRESS_INTERVAL="$val" ;;
            level) LOG_LEVEL="${val,,}"; LOG_RANK="$(lvl_rank "$LOG_LEVEL")" ;;
            xtrace) case "${val,,}" in true|1|yes) XTRACE=true ;; *) XTRACE=false ;; esac ;;
          esac
        fi
        ;;
      review)
        if [[ "$raw" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
          key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
          case "$key" in
            mode) RV_MODE="${val,,}" ;;
            input) RV_INPUT="$val" ;;
            sort) RV_SORT="${val,,}" ;;
            skip_zero_size) case "${val,,}" in true|1|yes) RV_SKIP_ZERO=true ;; *) RV_SKIP_ZERO=false ;; esac ;;
            min_size_mb) RV_MIN_MB="$val" ;;
            include_regex) RV_INCLUDE_REGEX="$val" ;;
            exclude_regex) RV_EXCLUDE_REGEX="$val" ;;
            show_sizes) case "${val,,}" in true|1|yes) RV_SHOW_SIZES=true ;; *) RV_SHOW_SIZES=false ;; esac ;;
            show_hash) RV_SHOW_HASH="${val,,}" ;;
            pause_every) RV_PAUSE_EVERY="${val:-0}"; [[ -z "$RV_PAUSE_EVERY" ]] && RV_PAUSE_EVERY=0 ;;
            auto_strategy) RV_AUTO_STRATEGY="${val,,}" ;;
            auto_regex_keep) RV_AUTO_REGEX_KEEP="$val" ;;
            report_dir) RV_REPORT_DIR="$val" ;;
            plan_dir) RV_PLAN_DIR="$val" ;;
            report_prefix_date) case "${val,,}" in true|1|yes) RV_REPORT_PREFIX_DATE=true ;; *) RV_REPORT_PREFIX_DATE=false ;; esac ;;
            safe_delete) RV_SAFE_DELETE="${val,,}" ;;
            safe_delete_dir) RV_SAFE_DELETE_DIR="$val" ;;
            confirm_phrase) RV_CONFIRM_PHRASE="$val" ;;
            dry_run) case "${val,,}" in true|1|yes) RV_DRY_RUN=true ;; *) RV_DRY_RUN=false ;; esac ;;
          esac
        fi
        ;;
    esac
  done <"$file"
}

# ───────────── CSV → TSV (robust to quotes/commas in path) ─────────────
# Emits: ts \t path \t algo \t hash \t size_mb
csv_to_tsv(){
  awk -v RS='' '
  function push_field() { f[++fc]=field }
  function flush_row() { if (fc){ for(i=1;i<=fc;i++){ printf "%s%s", f[i], (i<fc?"\t":"\n") } fc=0 } }
  {
    gsub(/\r/,"")
    n=split($0,lines,"\n")
    for (li=1; li<=n; li++){
      line=lines[li]; field=""; fc=0; inq=0
      for (i=1;i<=length(line);i++){
        c=substr(line,i,1); nc=(i<length(line)?substr(line,i+1,1):"")
        if (inq){
          if (c=="\"" && nc=="\""){ field=field "\""; i++ }
          else if (c=="\""){ inq=0 }
          else { field=field c }
        } else {
          if (c=="\""){ inq=1 }
          else if (c==","){ push_field(); field="" }
          else { field=field c }
        }
      }
      push_field()
      flush_row()
    }
  }'
}

# ───────────────────────── Arg parsing ─────────────────────────
while (($#)); do
  case "${1:-}" in
    --input)  INPUT_FILE="${2:-}"; shift 2;;
    --config) CONFIG_FILE="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    --*) log WARN "Ignoring unknown flag: $1"; shift;;
    *)   log WARN "Ignoring unexpected argument: $1"; shift;;
  esac
done

# ───────────────────────── Setup ─────────────────────────
mkdir -p "$HASH_DIR" "$DUP_DIR" "$LOGS_DIR"
RUN_ID="$(gen_run_id)"
LOG_FILE="$LOGS_DIR/review-duplicates-$RUN_ID.log"
BACKGROUND_LOG="$LOGS_DIR/review-duplicates.log"
: >"$LOG_FILE"
ln -sfn "$(basename "$LOG_FILE")" "$BACKGROUND_LOG" || true

# load config
if [[ -n "$CONFIG_FILE" ]]; then parse_ini "$CONFIG_FILE"; fi

# optional shell trace
if $XTRACE 2>/dev/null; then
  exec {__xtrace_fd}>>"$LOG_FILE" || true
  if [[ -n "${__xtrace_fd:-}" ]]; then export BASH_XTRACEFD="$__xtrace_fd"; set -x; fi
fi

log INFO "Run-ID: $RUN_ID"
log INFO "Config: ${CONFIG_FILE:-<none>} | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"
log INFO "Review mode: $RV_MODE | Sort: $RV_SORT | Filters: skip_zero=$RV_SKIP_ZERO min_mb=$RV_MIN_MB"

# ───────────────────────── Choose input CSV ─────────────────────────
if [[ -z "$INPUT_FILE" ]]; then
  if [[ "$RV_INPUT" = "latest" ]]; then
    INPUT_FILE="$(ls -t "$HASH_DIR"/hasher-*.csv 2>/dev/null | head -n 1 || true)"
    [[ -n "$INPUT_FILE" ]] || die "No hasher-*.csv files found in '$HASH_DIR'"
    log INFO "Selected latest CSV: $(basename "$INPUT_FILE")"
  else
    if [[ -f "$HASH_DIR/$RV_INPUT" ]]; then
      INPUT_FILE="$HASH_DIR/$RV_INPUT"
    elif [[ -f "$RV_INPUT" ]]; then
      INPUT_FILE="$RV_INPUT"
    else
      die "Configured input not found: $RV_INPUT"
    fi
    log INFO "Selected configured CSV: $(basename "$INPUT_FILE")"
  fi
else
  [[ -f "$INPUT_FILE" ]] || die "Input CSV not found: $INPUT_FILE"
  log INFO "Selected CLI CSV: $(basename "$INPUT_FILE")"
fi

BASENAME="$(basename "$INPUT_FILE")"
DATE_TAG="$(echo "$BASENAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
[[ -n "$DATE_TAG" ]] || DATE_TAG="$(date +'%Y-%m-%d')"

mkdir -p "$RV_REPORT_DIR" "$RV_PLAN_DIR"
REPORT="$RV_REPORT_DIR/${RV_REPORT_PREFIX_DATE:+$DATE_TAG-}duplicate-hashes.txt"
PLAN="$RV_PLAN_DIR/delete-plan.sh"
: >"$REPORT"
: >"$PLAN"
chmod +x "$PLAN"

# plan header with safety/confirmation + helper funcs
cat >"$PLAN" <<'EOS'
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

_confirm() {
  local expect="$1"
  echo "This script will process duplicate deletions."
  read -r -p "Type EXACTLY '${expect}' to proceed: " ans
  [[ "$ans" == "$expect" ]] || { echo "Aborted."; exit 1; }
}
_mkdir_p(){ mkdir -p -- "$1" 2>/dev/null || true; }
_unique_dest(){
  # _unique_dest <dir> <basename> <hashprefix>
  local d="$1" b="$2" h="$3" ext="" name="$b"
  if [[ "$b" == *.* ]]; then ext=".${b##*.}"; name="${b%.*}"; fi
  local cand="$d/${name}_${h}${ext}" n=1
  while [[ -e "$cand" ]]; do
    cand="$d/${name}_${h}(${n})${ext}"; n=$((n+1))
  done
  printf '%s' "$cand"
}
EOS

# Write confirmation line with configured phrase (insert later once we know it)
CONFIRM_LINE="_confirm \"$RV_CONFIRM_PHRASE\""
echo "$CONFIRM_LINE" >>"$PLAN"

# Deletion mode in plan
if [[ "$RV_SAFE_DELETE" = "move" ]]; then
  [[ -n "$RV_SAFE_DELETE_DIR" ]] || log WARN "safe_delete=move set but safe_delete_dir is empty; plan will warn on execution."
  cat >>"$PLAN" <<'EOS'
do_move(){
  local src="$1" dstroot="$2" hashprefix="$3"
  [[ -d "$dstroot" ]] || _mkdir_p "$dstroot"
  local base; base="$(basename -- "$src")"
  local dest; dest="$(_unique_dest "$dstroot" "$base" "$hashprefix")"
  echo "mv -- \"$src\" \"$dest\""
  mv -- "$src" "$dest"
}
EOS
else
  cat >>"$PLAN" <<'EOS'
do_rm(){
  local src="$1"
  echo "rm -f -- \"$src\""
  rm -f -- "$src"
}
EOS
fi

# honor dry-run (auto/plan-only paths)
if $RV_DRY_RUN 2>/dev/null; then
  echo 'echo "[DRY-RUN] No destructive actions will be performed."' >>"$PLAN"
fi

# ───────────────────────── CSV → TSV ─────────────────────────
TSV="$(mktemp)"; trap 'rm -f "$TSV"' EXIT
csv_to_tsv <"$INPUT_FILE" >"$TSV"

# Validate header (optional)
read -r HDR <"$TSV" || true
if ! echo "$HDR" | awk -F'\t' '{exit !($1=="timestamp" && $2=="path" && $3=="algo" && $4=="hash" && $5=="size_mb")}'; then
  log WARN "CSV header unexpected; proceeding anyway."
fi

# Build working rows: hash \t size_mb \t path
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
awk -F'\t' -v skip_zero="$RV_SKIP_ZERO" -v minmb="$RV_MIN_MB" '
NR>1 {
  size=$5+0
  if (skip_zero && size<=0) next
  if (size < minmb) next
  printf "%s\t%.6f\t%s\n", $4, size, $2
}' "$TSV" >"$TMP"

# Apply include/exclude regex filters on path
if [[ -n "$RV_INCLUDE_REGEX" ]]; then
  grep -E "$RV_INCLUDE_REGEX" "$TMP" >"${TMP}.inc" || true
  mv "${TMP}.inc" "$TMP"
fi
if [[ -n "$RV_EXCLUDE_REGEX" ]]; then
  grep -Ev "$RV_EXCLUDE_REGEX" "$TMP" >"${TMP}.exc" || true
  mv "${TMP}.exc" "$TMP"
fi

# Identify duplicate hash groups (2+ occurrences)
mapfile -t DUP_HASHES < <(cut -f1 "$TMP" | sort | uniq -d || true)
(( ${#DUP_HASHES[@]} > 0 )) || { log INFO "No duplicate hashes found after filters."; exit 0; }

# Compute per-group counts and total sizes for sorting
# Emit: hash \t count \t total_size_mb
META="$(mktemp)"; trap 'rm -f "$META"' EXIT
awk -F'\t' '
{ c[$1]++; s[$1]+=$2 }
END { for (h in c) printf "%s\t%d\t%.6f\n", h, c[h], s[h] }
' "$TMP" >"$META"

# Create sorted group list according to RV_SORT
case "$RV_SORT" in
  count_desc) SORTED_HASHES="$(sort -t$'\t' -k2,2nr -k3,3nr "$META" | cut -f1)";;
  size_desc)  SORTED_HASHES="$(sort -t$'\t' -k3,3nr -k2,2nr "$META" | cut -f1)";;
  hash_asc)   SORTED_HASHES="$(sort -t$'\t' -k1,1 "$META" | cut -f1)";;
  *)          SORTED_HASHES="$(cut -f1 "$META")";;
esac
mapfile -t GROUPS <<<"$SORTED_HASHES"
TOTAL_GROUPS=${#GROUPS[@]}

# Report header
{
  echo "# Duplicate Hashes Report"
  echo "# Source file           : $BASENAME"
  echo "# Date of run           : $(ts)"
  echo "# Total duplicate groups: $TOTAL_GROUPS"
  echo "# Filters               : skip_zero=$RV_SKIP_ZERO min_mb=$RV_MIN_MB"
  if [[ -n "$RV_INCLUDE_REGEX" ]]; then echo "# Include regex         : $RV_INCLUDE_REGEX"; fi
  if [[ -n "$RV_EXCLUDE_REGEX" ]]; then echo "# Exclude regex         : $RV_EXCLUDE_REGEX"; fi
  echo "#"
} >>"$REPORT"

short_hash(){ printf '%s' "$1" | cut -c1-12; }

draw_progress(){
  local cur="$1" tot="$2" width=40
  local pct=$(( tot>0 ? (cur*100/tot) : 0 ))
  local filled=$(( tot>0 ? (width*cur/tot) : 0 ))
  local empty=$(( width - filled ))
  printf '['; printf '%0.s#' $(seq 1 $filled); printf '%0.s-' $(seq 1 $empty); printf '] %d / %d (%d%%)\r' "$cur" "$tot" "$pct"
}

# ───────────────────────── Helpers for decisions ─────────────────────────
file_mtime(){
  local f="$1"
  if stat -c %Y "$f" >/dev/null 2>&1; then stat -c %Y "$f"
  elif stat -f %m "$f" >/dev/null 2>&1; then stat -f %m "$f"
  else echo 0
  fi
}
choose_keep_auto(){
  # stdin: lines "path<TAB>size_mb"
  # prints: path_to_keep
  case "$RV_AUTO_STRATEGY" in
    keep-largest)
      awk -F'\t' 'BEGIN{best="";mx=-1} {sz=$2+0;if(sz>mx){mx=sz;best=$1}} END{print best}'
      ;;
    keep-shortest-path)
      awk -F'\t' 'BEGIN{best="";bl=1e9} {l=length($1); if(l<bl){bl=l;best=$1}} END{print best}'
      ;;
    keep-newest)
      # need filesystem mtime; do it in shell
      local newest=0 best="" p sz mt
      while IFS=$'\t' read -r p sz; do
        mt=$(file_mtime "$p")
        if (( mt > newest )); then newest=$mt; best="$p"; fi
      done
      printf '%s\n' "$best"
      ;;
    keep-regex)
      local p sz best=""
      while IFS=$'\t' read -r p sz; do
        if [[ -n "$RV_AUTO_REGEX_KEEP" && "$p" =~ $RV_AUTO_REGEX_KEEP ]]; then best="$p"; break; fi
      done
      if [[ -z "$best" ]]; then
        # fallback to largest
        awk -F'\t' 'BEGIN{best="";mx=-1} {sz=$2+0;if(sz>mx){mx=sz;best=$1}} END{print best}'
      else
        printf '%s\n' "$best"
      fi
      ;;
    *)
      # none -> do not pick automatically
      echo ""
      ;;
  esac
}

append_plan_rm(){
  local path="$1"
  if $RV_DRY_RUN 2>/dev/null; then
    printf 'echo "[DRY-RUN] rm -f -- %q"\n' "$path" >>"$PLAN"
  else
    printf 'do_rm %q\n' "$path" >>"$PLAN"
  fi
}
append_plan_move(){
  local path="$1" hashprefix="$2"
  if [[ -z "$RV_SAFE_DELETE_DIR" ]]; then
    printf 'echo "[WARN] safe_delete_dir is not set; skipping move of %q"\n' "$path" >>"$PLAN"
    return
  fi
  if $RV_DRY_RUN 2>/dev/null; then
    printf 'echo "[DRY-RUN] mv -- %q to %q"\n' "$path" "$RV_SAFE_DELETE_DIR" >>"$PLAN"
  else
    printf 'do_move %q %q %q\n' "$path" "$RV_SAFE_DELETE_DIR" "$hashprefix" >>"$PLAN"
  fi
}

queue_delete(){
  local del_path="$1" hash="$2"
  local hp="$(short_hash "$hash")"
  if [[ "$RV_SAFE_DELETE" = "move" ]]; then append_plan_move "$del_path" "$hp"; else append_plan_rm "$del_path"; fi
}

# ───────────────────────── Main loop ─────────────────────────
COUNT=0
PAUSE_COUNTER=0

for hash in "${GROUPS[@]}"; do
  COUNT=$((COUNT+1))
  draw_progress "$COUNT" "$TOTAL_GROUPS"

  # Build group rows: path \t size_mb
  mapfile -t GROUP < <(awk -F'\t' -v h="$hash" '$1==h {print $3 "\t" $2}' "$TMP")

  # Only proceed if >1 (duplicates)
  (( ${#GROUP[@]} > 1 )) || continue

  # Prepare pretty hash for display
  if [[ "$RV_SHOW_HASH" = "short" ]]; then
    HASH_DISPLAY="$(short_hash "$hash")"
  else
    HASH_DISPLAY="$hash"
  fi

  # AUTO / EXPORT / PLAN-ONLY (no prompts)
  if [[ "$RV_MODE" = "auto" || "$RV_MODE" = "export-only" || "$RV_MODE" = "plan-only" ]]; then
    # choose keep (only in auto; otherwise keep empty -> no deletions selected automatically)
    KEEP=""
    if [[ "$RV_MODE" = "auto" ]]; then
      KEEP="$(printf "%s\n" "${GROUP[@]}" | choose_keep_auto)"
    fi

    # write report section unless plan-only
    if [[ "$RV_MODE" != "plan-only" ]]; then
      {
        echo "Duplicate group #$COUNT"
        echo "Hash: $hash"
        for row in "${GROUP[@]}"; do
          echo "${row%%$'\t'*}"
        done
        echo ""
      } >>"$REPORT"
    fi

    # queue deletions (everything except KEEP; if KEEP empty and not auto, no deletions are queued)
    if [[ -n "$KEEP" ]]; then
      for row in "${GROUP[@]}"; do
        path="${row%%$'\t'*}"
        if [[ "$path" != "$KEEP" ]]; then queue_delete "$path" "$hash"; fi
      done
    fi

    continue
  fi

  # INTERACTIVE
  echo -e "\n────────────────────────────────────────────"
  echo "Group $COUNT of $TOTAL_GROUPS"
  echo "Duplicate hash: $HASH_DISPLAY"
  echo ""
  echo "Options:"
  echo "  S = Skip this group"
  echo "  Q = Quit review (you can resume later)"
  echo ""
  echo "Select the FILE NUMBER TO DELETE (all others will be retained):"
  if $RV_SHOW_SIZES 2>/dev/null; then
    printf "  %-5s | %-10s | %-s\n" "No." "Size(MB)" "File path"
  else
    printf "  %-5s | %-s\n" "No." "File path"
  fi

  idx=0
  for row in "${GROUP[@]}"; do
    idx=$((idx+1))
    path="${row%%$'\t'*}"
    size="${row##*$'\t'}"
    if $RV_SHOW_SIZES 2>/dev/null; then
      printf "  %-5s | %-10s | %s\n" "$idx" "$size" "$path"
    else
      printf "  %-5s | %s\n" "$idx" "$path"
    fi
  done

  read -r -p "Your choice (S, Q or 1-${#GROUP[@]}): " choice
  case "$choice" in
    [Ss]) ;;
    [Qq]) echo ""; break;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#GROUP[@]} )); then
        sel="${GROUP[$((choice-1))]}"
        del_path="${sel%%$'\t'*}"
        queue_delete "$del_path" "$hash"
        log INFO "Queued delete: $del_path"
      else
        log WARN "Invalid choice, skipping group."
      fi
      ;;
  esac

  {
    echo "Duplicate group #$COUNT"
    echo "Hash: $hash"
    for row in "${GROUP[@]}"; do
      echo "${row%%$'\t'*}"
    done
    echo ""
  } >>"$REPORT"

  # paging if configured
  if (( RV_PAUSE_EVERY > 0 )); then
    PAUSE_COUNTER=$((PAUSE_COUNTER+1))
    if (( PAUSE_COUNTER >= RV_PAUSE_EVERY )); then
      read -r -p "Press Enter to continue (or Q to quit): " _ans
      [[ "${_ans,,}" == "q" ]] && break
      PAUSE_COUNTER=0
    fi
  fi
done

echo ""
log INFO "Review complete."
if [[ "$RV_MODE" != "plan-only" ]]; then
  log INFO "Report written to: $REPORT"
fi
log INFO "Deletion plan saved to: $PLAN"

# Append a final reminder of dry-run status
if $RV_DRY_RUN 2>/dev/null; then
  echo 'echo "[DRY-RUN] Completed. No files were deleted."' >>"$PLAN"
else
  echo 'echo "Completed deletions."' >>"$PLAN"
fi

echo "To execute planned deletions, run:"
echo "  $PLAN"

# ── Post-review tips (append near script exit) ─────────────────────────
ts="$(date +'%Y-%m-%d %H:%M:%S')"
echo "[${ts}] [INFO] Review session complete."
echo "  • If you saved/exported a duplicates report, you can act on it:"
echo "      ./deduplicate.sh --from-report logs/$(date +'%Y-%m-%d')-duplicate-hashes.txt"
echo "  • Dry-run first (recommended), then add --force when satisfied."
echo "  • Prefer quarantine moves (default) over delete for safety."
