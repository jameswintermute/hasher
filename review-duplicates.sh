#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder (Review Duplicates)
# Copyright (C) 2025 James Wintermute <jameswinter@protonmail.ch>
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────────────────────── Paths & Defaults ─────────────────────────
HASH_DIR="hashes"
DUP_DIR="duplicate-hashes"
LOGS_DIR="logs"
CONFIG_FILE=""                 # optional --config hasher.conf

# Logging config (overridden by [logging] in hasher.conf)
PROGRESS_INTERVAL=15           # reuse as heartbeat spacing for long phases
LOG_LEVEL="info"               # debug|info|warn|error
XTRACE=false

# runtime
RUN_ID=""
LOG_FILE=""
BACKGROUND_LOG=""

# ───────────────────────── Utilities ─────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

gen_run_id() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else printf '%s-%s-%s' "$(date +'%Y%m%d-%H%M%S')" "$$" "$RANDOM"
  fi
}

lvl_rank(){ case "$1" in debug) echo 10;; info) echo 20;; warn) echo 30;; error) echo 40;; *) echo 20;; esac; }
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
  $(basename "$0") [--input hasher-YYYY-MM-DD.csv] [--config hasher.conf]

If --input is omitted, you'll be prompted to pick a recent CSV in '$HASH_DIR'.

Config:
  Reads [logging] level, xtrace, background-interval from hasher.conf (if provided).
EOF
}

# INI parser (subset)
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
    esac
  done <"$file"
}

# ───────────────────────── Args ─────────────────────────
INPUT_FILE=""
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

# config
if [[ -n "$CONFIG_FILE" ]]; then parse_ini "$CONFIG_FILE"; fi
# Optional xtrace
if $XTRACE 2>/dev/null; then
  exec {__xtrace_fd}>>"$LOG_FILE" || true
  if [[ -n "${__xtrace_fd:-}" ]]; then export BASH_XTRACEFD="$__xtrace_fd"; set -x; fi
fi

log INFO "Run-ID: $RUN_ID"
log INFO "Config: ${CONFIG_FILE:-<none>} | Level: $LOG_LEVEL | Interval: ${PROGRESS_INTERVAL}s"

# ───────────────── CSV helpers (robust quoted CSV) ─────────────────
# Our CSV columns are: "timestamp","path","algo","hash","size_mb"
# This awk emits TAB-separated fields: ts \t path \t algo \t hash \t size
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

# ───────────────────────── Input selection ─────────────────────────
if [[ -z "$INPUT_FILE" ]]; then
  log INFO "Scanning most recent CSV hash files in '$HASH_DIR'..."
  mapfile -t FILES < <(ls -t "$HASH_DIR"/hasher-*.csv 2>/dev/null | head -n 10 || true)
  if (( ${#FILES[@]} == 0 )); then die "No hasher-*.csv files found in '$HASH_DIR'"; fi

  echo ""
  echo "Select a CSV hash file to process:"
  for i in "${!FILES[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "$(basename "${FILES[$i]}")"
  done
  echo ""
  read -r -p "Enter file number or filename: " selection
  if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection>=1 && selection<=${#FILES[@]} )); then
    INPUT_FILE="${FILES[$((selection-1))]}"
  elif [[ -f "$HASH_DIR/$selection" ]]; then
    INPUT_FILE="$HASH_DIR/$selection"
  else
    die "Invalid selection."
  fi
fi

[[ -f "$INPUT_FILE" ]] || die "Input CSV not found: $INPUT_FILE"
BASENAME="$(basename "$INPUT_FILE")"
log INFO "Selected file: $BASENAME"

DATE_TAG="$(echo "$BASENAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
DATE_TAG="${DATE_TAG:-$(date +'%Y-%m-%d')}"
REPORT="$DUP_DIR/${DATE_TAG}-duplicate-hashes.txt"
PLAN="$DUP_DIR/delete-plan.sh"
: >"$REPORT"
: >"$PLAN"
chmod +x "$PLAN"

# write plan header
cat >"$PLAN" <<'EOS'
#!/bin/bash
# Delete-plan generated by review-duplicates.sh
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C
echo "This script will delete the selected duplicate files."
read -r -p "Type YES to proceed: " ans
[[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
EOS

# ───────────────────────── Extract duplicates ─────────────────────────
log INFO "Scanning for duplicate hashes (CSV-safe)…"

# Convert CSV to TSV then awk-group by hash (field 4), skipping size_mb==0.00
# Build a temp file with: hash \t size_mb \t path
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
TSV="$(mktemp)"; trap 'rm -f "$TSV"' EXIT

csv_to_tsv <"$INPUT_FILE" >"$TSV"

# Validate header (optional)
# Expected header row:
# timestamp  path  algo  hash  size_mb
read -r HDR <"$TSV" || true
if ! echo "$HDR" | awk -F'\t' '{exit !($1=="timestamp" && $2=="path" && $3=="algo" && $4=="hash" && $5=="size_mb")}'; then
  log WARN "CSV header unexpected; proceeding anyway."
fi

# Generate rows for non-zero size
awk -F'\t' 'NR>1 { if ($5+0 > 0) printf "%s\t%s\t%s\n", $4, $5, $2 }' "$TSV" >"$TMP"

# Count duplicates groups and files
# dup_groups: hashes that occur 2+ times
# dup_files: total rows for those hashes
mapfile -t DUP_GROUPS < <(cut -f1 "$TMP" | sort | uniq -d || true)
if (( ${#DUP_GROUPS[@]} == 0 )); then
  log INFO "No duplicate hashes found (non-zero size)."
  exit 0
fi

DUP_FILE_COUNT=$(awk -F'\t' 'NR==FNR{d[$1]=1; next} d[$1]{c++} END{print c+0}' <(printf "%s\n" "${DUP_GROUPS[@]}") "$TMP")
log INFO "Found ${#DUP_GROUPS[@]} duplicate groups across $DUP_FILE_COUNT files."

{
  echo "# Duplicate Hashes Report"
  echo "# Source file           : $BASENAME"
  echo "# Date of run           : $(ts)"
  echo "# Total duplicate groups: ${#DUP_GROUPS[@]}"
  echo "# Total duplicate files : $DUP_FILE_COUNT"
  echo "#"
} >>"$REPORT"

# ───────────────────────── Interactive review ─────────────────────────
COUNT=0
TOTAL_HASHES=${#DUP_GROUPS[@]}

draw_progress(){
  local cur="$1" tot="$2" width=40
  local pct=$(( tot>0 ? (cur*100/tot) : 0 ))
  local filled=$(( tot>0 ? (width*cur/tot) : 0 ))
  local empty=$(( width - filled ))
  local bar=""
  printf -v bar '%*s' "$filled" ""; bar=${bar// /#}
  local dash=""; printf -v dash '%*s' "$empty" ""; dash=${dash// /-}
  printf '[%s%s] %d / %d groups (%d%%)\r' "$bar" "$dash" "$cur" "$tot" "$pct"
}

log INFO "Starting interactive review…"
for hash in "${DUP_GROUPS[@]}"; do
  COUNT=$((COUNT+1))
  draw_progress "$COUNT" "$TOTAL_HASHES"

  # Gather this group's files (keep original order stable)
  # TMP rows: hash \t size_mb \t path
  mapfile -t GROUP < <(awk -F'\t' -v h="$hash" '$1==h {print $3 "\t" $2}' "$TMP")

  # If only one file (shouldn't happen since groups are 2+), skip
  (( ${#GROUP[@]} > 1 )) || continue

  echo -e "\n────────────────────────────────────────────"
  echo "Group $COUNT of $TOTAL_HASHES"
  echo "Duplicate hash: $hash"
  echo ""
  echo "Options:"
  echo "  S = Skip this group"
  echo "  Q = Quit review (you can resume later)"
  echo ""
  echo "Select the FILE NUMBER TO DELETE (all others will be retained):"
  printf "  %-5s | %-10s | %-s\n" "No." "Size(MB)" "File path"
  idx=0
  for row in "${GROUP[@]}"; do
    idx=$((idx+1))
    path="${row%%$'\t'*}"
    size="${row##*$'\t'}"
    printf "  %-5s | %-10s | %s\n" "$idx" "$size" "$path"
  done

  read -r -p "Your choice (S, Q or 1-${#GROUP[@]}): " choice
  case "$choice" in
    [Ss]) continue;;
    [Qq]) echo ""; break;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#GROUP[@]} )); then
        sel="${GROUP[$((choice-1))]}"
        del_path="${sel%%$'\t'*}"
        printf 'rm -f -- %q\n' "$del_path" >>"$PLAN"
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

  # heartbeat pacing (optional)
  sleep 0 2>/dev/null || true
done

echo ""
log INFO "Review complete."
log INFO "Report written to: $REPORT"
log INFO "Deletion plan saved to: $PLAN"
echo "To execute planned deletions, run:"
echo "  $PLAN"
