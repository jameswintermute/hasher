#!/usr/bin/env bash
# delete-zero-length.sh — verify & delete/move zero-length files
# Dry-run by default. Can quarantine instead of deleting.
# Adds summary-by-path (top groups) for context.
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ────────────── Defaults ──────────────
LOGS_DIR="logs"
ZERO_DIR="zero-length"
DATE_TAG="$(date +'%Y-%m-%d')"
SUMMARY_LOG="$LOGS_DIR/delete-zero-length-$DATE_TAG.log"
RUN_ID="$( (command -v uuidgen >/dev/null 2>&1 && uuidgen) || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$$" )"

FORCE=false
ASSUME_YES=false
QUARANTINE_DIR=""
GROUP_DEPTH=2     # how many leading path components to group by (e.g. /vol/share = 2)
TOP_N=10          # how many top groups to print in console
SHOW_PATH_SUMMARY=true

# ────────────── Colors ──────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() {
  local lvl="$1"; shift; local msg="$*"
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RUN %s] [%s] %s\n' "$ts" "$RUN_ID" "$lvl" "$msg" | tee -a "$SUMMARY_LOG" >&2
}

usage() {
cat <<EOF
Usage: $0 [<pathlist.txt>] [--force] [--quarantine DIR] [--yes]
          [--group-depth N] [--top N] [--no-path-summary] [-h|--help]

Behavior:
  • Dry-run by default. Verifies input list, writes a verified plan, shows a
    summary (including top directories by count), and prints a ready-to-run cmd.
  • With --force, acts immediately on the newly generated verified plan.
  • Use --quarantine DIR with --force to move files under DIR (preserves path)
    instead of deleting.

Examples:
  # Auto-pick latest report (prefers verified-*.txt, else zero-length-*.txt, else logs/zero-length-*.txt)
  $0

  # Use explicit input (dry-run):
  $0 "zero-length/zero-length-$DATE_TAG.txt"

  # Act now (delete) using auto-picked input:
  $0 --force

  # Act now (quarantine) preserving path under the given directory:
  $0 "zero-length/zero-length-$DATE_TAG.txt" --force --quarantine "zero-length/quarantine-$DATE_TAG"

Options:
  --force                 Actually delete/move verified files (otherwise dry-run)
  --quarantine DIR        Move verified files into DIR (preserve absolute path under DIR)
  -y, --yes               Assume "yes" to confirmations (useful for non-interactive)
  --group-depth N         Group summary by first N path components (default: $GROUP_DEPTH)
  --top N                 Show top N groups in console (default: $TOP_N)
  --no-path-summary       Skip path grouping summary
  -h, --help              Show this help
EOF
}

# ────────────── Arg parsing ──────────────
INPUT_FILE="${1:-}"
if [[ "${INPUT_FILE:-}" == "--"* || "${INPUT_FILE:-}" == "-h" || -z "${INPUT_FILE:-}" ]]; then
  INPUT_FILE=""
fi
if [[ -n "${INPUT_FILE:-}" ]]; then shift || true; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --quarantine) QUARANTINE_DIR="${2:-}"; shift ;;
    -y|--yes) ASSUME_YES=true ;;
    --group-depth) GROUP_DEPTH="${2:-2}"; shift ;;
    --top) TOP_N="${2:-10}"; shift ;;
    --no-path-summary) SHOW_PATH_SUMMARY=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${YELLOW}Unknown option: $1${NC}" >&2; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOGS_DIR" "$ZERO_DIR"

# ────────────── Helpers ──────────────
count_lines() { [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0; }
short_id() { local s="$1"; s="${s%.txt}"; s="${s##*-}"; printf '%s' "${s:0:8}"; }
first_date_in_name() { printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1 || true; }

pick_reports() {
  # newest first; limit 10
  local list=()
  mapfile -t list < <(ls -1t zero-length/verified-zero-length-*.txt 2>/dev/null | head -n 10 || true)
  if (( ${#list[@]} == 0 )); then
    mapfile -t list < <(ls -1t zero-length/zero-length-*.txt 2>/dev/null | head -n 10 || true)
  else
    # also include raw zero-length and logs if room (helpful if verified empty)
    local raw; mapfile -t raw < <(ls -1t zero-length/zero-length-*.txt 2>/dev/null | head -n 10 || true)
    list+=("${raw[@]}")
  fi
  if (( ${#list[@]} == 0 )); then
    mapfile -t list < <(ls -1t logs/zero-length-*.txt 2>/dev/null | head -n 10 || true)
  else
    local zlog; mapfile -t zlog < <(ls -1t logs/zero-length-*.txt 2>/dev/null | head -n 10 || true)
    list+=("${zlog[@]}")
  fi

  # unique + cap at 10
  awk 'BEGIN{FS="\n"}{print}' <<<"${list[*]}" | awk '!seen[$0]++' | head -n 10
}

# ────────────── Input selection ──────────────
if [[ -z "${INPUT_FILE:-}" ]]; then
  mapfile -t CANDIDATES < <(pick_reports)
  if (( ${#CANDIDATES[@]} == 0 )); then
    log ERROR "No report files found (expected zero-length/verified-*.txt or zero-length-*.txt or logs/zero-length-*.txt)."
    exit 1
  fi

  echo "Select input report (showing ${#CANDIDATES[@]} of ${#CANDIDATES[@]} most recent):"
  i=1
  for f in "${CANDIDATES[@]}"; do
    typ="raw"; src="zero-length"
    base="$(basename "$f")"
    date="$(first_date_in_name "$base")"
    cnt="$(count_lines "$f")"
    if [[ "$base" == verified-zero-length-* ]]; then typ="verified"; src="zero-length"; sid="$(short_id "$base")"; printf "  %2d) %-9s • %s • zero-length • id=%s  (%d entries)\n" "$i" "$typ" "$date" "$sid" "$cnt"
    elif [[ "$f" == logs/* ]]; then typ="raw"; src="logs"; printf "  %2d) %-9s • %s • logs         (%d entries)\n" "$i" "$typ" "$date" "$cnt"
    else printf "  %2d) %-9s • %s • zero-length  (%d entries)\n" "$i" "$typ" "$date" "$cnt"
    fi
    i=$((i+1))
  done

  if $ASSUME_YES; then sel=1
  else
    read -r -p "Enter number [1-${#CANDIDATES[@]}] (default 1): " sel || true
    sel="${sel:-1}"
  fi

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#CANDIDATES[@]} )); then
    log ERROR "Invalid selection."; exit 2
  fi
  INPUT_FILE="${CANDIDATES[$((sel-1))]}"
  log INFO "Auto-selected input: $INPUT_FILE"
  if ! $ASSUME_YES; then
    read -r -p "Use \"$INPUT_FILE\"? [Y/n] " yn || true
    case "${yn,,}" in n|no) echo "Aborted."; exit 0;; esac
  fi
fi

if [[ ! -r "$INPUT_FILE" ]]; then
  log ERROR "Cannot read input list: $INPUT_FILE"
  exit 1
fi

# ────────────── Verify input → write verified plan ──────────────
MODE="DRY-RUN"; $FORCE && MODE="EXECUTE"
log INFO "Mode: $MODE ${FORCE:+(will ${QUARANTINE_DIR:+move to quarantine}${QUARANTINE_DIR:+" "}"$QUARANTINE_DIR"${QUARANTINE_DIR:+" "}||delete)}"
log INFO "Verifying zero-length files…"
log INFO "Input list: $INPUT_FILE"
log INFO "Summary log: $SUMMARY_LOG"
log INFO "Run-ID: $RUN_ID"

VERIFIED="$ZERO_DIR/verified-zero-length-$DATE_TAG-$RUN_ID.txt"
: > "$VERIFIED"

total_in=0
missing=0
notreg=0
notzero=0
verified_now=0

# progress printing cadence
STEP=200

while IFS= read -r f || [[ -n "$f" ]]; do
  [[ -z "$f" ]] && continue
  total_in=$((total_in+1))
  if (( total_in % STEP == 0 )); then
    printf '\rVerifying… %d checked' "$total_in" >&2
  fi

  if [[ ! -e "$f" ]]; then
    missing=$((missing+1))
    continue
  fi
  if [[ ! -f "$f" ]]; then
    notreg=$((notreg+1))
    continue
  fi
  if [[ -s "$f" ]]; then
    notzero=$((notzero+1))
    continue
  fi
  printf '%s\n' "$f" >> "$VERIFIED"
  verified_now=$((verified_now+1))
done < "$INPUT_FILE"
printf '\r' >&2 || true

log INFO "Verification complete."
log INFO "  • Input entries considered: $total_in"
log INFO "  • Missing paths: $missing"
log INFO "  • Not regular files: $notreg"
log INFO "  • No longer zero-length: $notzero"
log INFO "  • Verified zero-length now: $verified_now"
log INFO "Verified plan file: $VERIFIED"

# ────────────── Summary by path (top groups) ──────────────
if $SHOW_PATH_SUMMARY && (( verified_now > 0 )); then
  SUMMARY_TSV="$LOGS_DIR/delete-zero-length-summary-$DATE_TAG-$RUN_ID.tsv"
  awk -v d="$GROUP_DEPTH" -F'/' '
    BEGIN{OFS="/"}
    {
      if ($0=="") next
      k=""; c=0
      for (i=1;i<=NF;i++){
        if($i=="") continue
        c++
        if (c<=d) { k=k "/" $i } else { break }
      }
      count[k]++
    }
    END{
      for (k in count) printf "%s\t%d\n", k, count[k]
    }
  ' "$VERIFIED" | sort -k2,2nr > "$SUMMARY_TSV" || true

  log INFO "Summary by path (depth=$GROUP_DEPTH) written to: $SUMMARY_TSV"

  echo -e "${GREEN}Top $TOP_N groups (depth=$GROUP_DEPTH):${NC}"
  i=0
  while IFS=$'\t' read -r path cnt; do
    i=$((i+1))
    pct=$(( cnt * 100 / verified_now ))
    printf "  %2d) %-50s  %6d files  (%3d%%)\n" "$i" "$path" "$cnt" "$pct"
    (( i>=TOP_N )) && break || true
  done < "$SUMMARY_TSV"
  echo
fi

# If dry-run, print ready-to-run
if ! $FORCE; then
  echo -e "${GREEN}[DRY-RUN SUMMARY]${NC}"
  echo "  Verified zero-length files: $verified_now"
  echo "  Ready to act using the verified plan:"
  echo "    Delete:"
  echo "      $0 \"$VERIFIED\" --force"
  echo "    Quarantine:"
  echo "      $0 \"$VERIFIED\" --force --quarantine \"$ZERO_DIR/quarantine-$DATE_TAG\""
  exit 0
fi

# ────────────── Execute (delete or quarantine) ──────────────
act_delete=0
act_move=0
act_fail=0

if [[ -n "$QUARANTINE_DIR" ]]; then
  mkdir -p "$QUARANTINE_DIR"
fi

if ! $ASSUME_YES; then
  echo
  if [[ -n "$QUARANTINE_DIR" ]]; then
    read -r -p "Move $verified_now files to quarantine \"$QUARANTINE_DIR\"? [y/N] " yn || true
  else
    read -r -p "Permanently delete $verified_now files? [y/N] " yn || true
  fi
  case "${yn,,}" in y|yes) : ;; *) echo "Aborted."; exit 0;; esac
fi

while IFS= read -r f || [[ -n "$f" ]]; do
  [[ -z "$f" ]] && continue
  if [[ -n "$QUARANTINE_DIR" ]]; then
    rel="${f#/}"                    # strip leading slash
    dest="$QUARANTINE_DIR/$rel"
    mkdir -p "$(dirname "$dest")" || { act_fail=$((act_fail+1)); continue; }
    if mv -n -- "$f" "$dest" 2>/dev/null; then
      act_move=$((act_move+1))
    else
      act_fail=$((act_fail+1))
    fi
  else
    if rm -f -- "$f" 2>/dev/null; then
      act_delete=$((act_delete+1))
    else
      act_fail=$((act_fail+1))
    fi
  fi
done < "$VERIFIED"

echo
log INFO "Execution complete."
if [[ -n "$QUARANTINE_DIR" ]]; then
  log INFO "  • Moved to quarantine: $act_move"
else
  log INFO "  • Deleted: $act_delete"
fi
log INFO "  • Failed actions: $act_fail"
log INFO "  • Verified plan was: $VERIFIED"
if [[ -n "$QUARANTINE_DIR" ]]; then
  log INFO "Quarantine root: $QUARANTINE_DIR"
fi

echo -e "${GREEN}Done.${NC}"
