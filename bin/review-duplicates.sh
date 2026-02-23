#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs";   mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";     mkdir -p "$VAR_DIR"
LOCAL_DIR="$ROOT_DIR/local"; mkdir -p "$LOCAL_DIR"
EXCEPTIONS_FILE="$LOCAL_DIR/exceptions-hashes.txt"

REPORT_DEFAULT="$LOGS_DIR/duplicate-hashes-latest.txt"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
PLAN_DEFAULT="$LOGS_DIR/review-dedupe-plan-$(date +%F)-$RUN_ID.txt"

REPORT="$REPORT_DEFAULT"
PLAN_OUT="$PLAN_DEFAULT"
PROGRESS_EVERY=1
SHOW_PROGRESS=1
ORDER="size"  # size|sizesmall|name|newest|oldest|shortpath|longpath

is_tty() { [ -t 2 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; }
if is_tty; then
  C1="$(printf '\033[1;36m')"; C2="$(printf '\033[1;33m')"
  COK="$(printf '\033[1;32m')" ; CERR="$(printf '\033[1;31m')"
  CDIM="$(printf '\033[2m')"  ; C0="$(printf '\033[0m')"
else
  C1=""; C2=""; COK=""; CERR=""; CDIM=""; C0=""
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [--from-report PATH] [--plan-out PATH] [--plan PATH]
                        [--every N] [--no-progress]
                        [--order size|sizesmall|name|newest|oldest|shortpath|longpath]
Notes:
  - Groups are shown by BIGGEST POTENTIAL SAVINGS first: (N-1)*size.
  - Inside each group, default order is 'size' (largest first) and sizes are shown.
  - File sizes are always displayed regardless of sort order.
  - You'll be asked how many groups or what percentage to review.
EOF
}

warn()  { printf "%s[WARN]%s %s\n"  "$C2"  "$C0" "$1" >&2; }
info()  { printf "%s[INFO]%s %s\n"  "$COK" "$C0" "$1" >&2; }
error() { printf "%s[ERROR]%s %s\n" "$CERR" "$C0" "$1" >&2; }

# Duration helper for progress
htime(){
  s="${1:-0}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -ge 60 ] 2>/dev/null; then
    m=$((s/60)); r=$((s%60))
    printf "%dm %02ds" "$m" "$r"
  else
    printf "%ds" "$s"
  fi
}

# Global flag: have we warned about size lookup issues?
SIZE_WARNED=0

# Exceptions handling
clean_exceptions_file() {
  EXC_CLEAN="$VAR_DIR/exceptions-cleaned-$$.txt"
  if [ -f "$EXCEPTIONS_FILE" ]; then
    grep -v '^[[:space:]]*#' "$EXCEPTIONS_FILE" 2>/dev/null \
      | sed 's/[[:space:]]//g' \
      | sed '/^$/d' >"$EXC_CLEAN" || true
  else
    : >"$EXC_CLEAN"
  fi
  echo "$EXC_CLEAN"
}

hash_is_exception() {
  h="$1"; exc_file="$2"
  [ -z "$h" ] && return 1
  [ -f "$exc_file" ] || return 1
  grep -qxF "$h" "$exc_file" 2>/dev/null
}

human_size(){
  b="${1:-0}"
  case "$b" in
    -1) printf "??"; return 0 ;;  # unknown / could not stat
    ''|*[!0-9]*) b=0 ;;
  esac
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    printf "%.1fG" "$(awk "BEGIN{print $b/1073741824}")"
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    printf "%.1fM" "$(awk "BEGIN{print $b/1048576}")"
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    printf "%.1fK" "$(awk "BEGIN{print $b/1024}")"
  else
    printf "%dB" "$b"
  fi
}

add_to_exceptions() {
  hash="$1"
  example_size="$2"

  mkdir -p "$(dirname "$EXCEPTIONS_FILE")"
  touch "$EXCEPTIONS_FILE"

  size_hr="$(human_size "$example_size")"

  echo
  printf "You have selected to add this hash to your local exceptions list.\n"
  printf "  Hash: %s\n" "$hash"
  printf "  Example file size: %s\n" "$size_hr"
  printf "You will no longer be prompted for this hash in future runs.\n"

  printf "Proceed and append to %s? [y/N] " "$(basename "$EXCEPTIONS_FILE")"
  if [ -t 0 ]; then read ans; else read ans </dev/tty; fi
  case "$ans" in
    Y|y|yes|YES)
      if grep -qxF "$hash" "$EXCEPTIONS_FILE" 2>/dev/null; then
        info "Hash already present in exceptions list."
      else
        printf "%s\n" "$hash" >>"$EXCEPTIONS_FILE"
        info "Hash added to exceptions list."
      fi
      ;;
    *)
      info "Not adding hash to exceptions list."
      ;;
  esac
}

# Args
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT="${2?}"; shift 2 ;;
    --plan-out|--plan) PLAN_OUT="${2?}"; shift 2 ;;
    --every) PROGRESS_EVERY="${2?}"; shift 2 ;;
    --no-progress) SHOW_PROGRESS=0; shift ;;
    --order) ORDER="${2?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Ignoring unknown arg: $1"; shift ;;
  esac
done

case "$ORDER" in
  size|sizesmall|name|newest|oldest|shortpath|longpath) : ;;
  *) warn "Unknown --order '$ORDER' — falling back to 'size'"; ORDER="size" ;;
esac

[ -r "$REPORT" ] || { error "Report not found: $REPORT"; exit 1; }
touch "$PLAN_OUT" 2>/dev/null || { error "Cannot write plan: $PLAN_OUT"; exit 1; }

# FIX: use awk instead of wc -l to avoid whitespace/padding differences across platforms
count_groups() { awk '/^HASH /{n++} END{print n+0}' "$REPORT" 2>/dev/null || echo 0; }

_progress_bar() {
  [ "$SHOW_PROGRESS" -eq 1 ] || return 0
  is_tty || return 0
  label="$1"; cur="$2"; total="$3"; started="$4"
  [ "$total" -gt 0 ] || total=1
  pct=$(( 100 * cur / total ))
  now=$(date +%s); elapsed=$(( now - started ))
  rem=$(( total - cur ))
  [ "$cur" -gt 0 ] && eta=$(( elapsed * rem / cur )) || eta=0
  barw=40; filled=$(( pct * barw / 100 ))
  i=0; BAR=""
  while [ $i -lt $filled ]; do BAR="${BAR}#"; i=$((i+1)); done
  while [ $i -lt $barw ]; do BAR="${BAR}-"; i=$((i+1)); done
  printf "\r%s[%s]%s %3d%% [%s]  %d/%d  Elapsed %s  ETA %s    " \
    "$C1" "$label" "$C0" "$pct" "$BAR" "$cur" "$total" \
    "$(htime "$elapsed")" "$(htime "$eta")" >&2
}

progress_review() {
  [ "$SHOW_PROGRESS" -eq 1 ] || return 0
  is_tty || return 0
  cur="$1"; total="$2"; files_seen="$3"; started="$4"
  [ "$total" -gt 0 ] || total=1
  pct=$(( 100 * cur / total ))
  now=$(date +%s); elapsed=$(( now - started ))
  rem=$(( total - cur ))
  [ "$cur" -gt 0 ] && eta=$(( elapsed * rem / cur )) || eta=0
  barw=40; filled=$(( pct * barw / 100 ))
  i=0; BAR=""
  while [ $i -lt $filled ]; do BAR="${BAR}#"; i=$((i+1)); done
  while [ $i -lt $barw ]; do BAR="${BAR}-"; i=$((i+1)); done
  printf "\r%s[PROGRESS]%s %3d%% [%s]  Group %d/%d  Reviewed total files: %d  Elapsed %s  ETA %s    " \
    "$C1" "$C0" "$pct" "$BAR" "$cur" "$total" "$files_seen" \
    "$(htime "$elapsed")" "$(htime "$eta")" >&2
}

file_mtime(){
  f="$1"
  stat -c %Y "$f" 2>/dev/null && return 0 || true
  busybox stat -c %Y "$f" 2>/dev/null && return 0 || true
  stat -f %m "$f" 2>/dev/null && return 0 || true
  date -r "$f" +%s 2>/dev/null && return 0 || true
  echo 0
}

file_size(){
  f="$1"
  sz=""
  sz="$(stat -c %s "$f" 2>/dev/null || true)"
  [ -z "$sz" ] && sz="$(busybox stat -c %s "$f" 2>/dev/null || true)"
  [ -z "$sz" ] && sz="$(stat -f %z "$f" 2>/dev/null || true)"
  if [ -z "$sz" ]; then
    sz="$(wc -c <"$f" 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$sz" ]; then
    sz="-1"
    if [ "$SIZE_WARNED" -eq 0 ]; then
      warn "Unable to stat some files (e.g. $f); sizes will show as '??' and potential savings may be approximate."
      SIZE_WARNED=1
    fi
  fi
  printf "%s" "$sz"
}

path_len(){ printf "%s" "$1" | wc -c | awk '{print $1}'; }

order_group(){
  case "$ORDER" in
    newest)    while IFS= read -r p; do [ -n "$p" ] || continue; printf "%s\t%s\n" "$(file_mtime "$p")" "$p"; done | sort -nr -k1,1 | awk -F'\t' '{print $2}';;
    oldest)    while IFS= read -r p; do [ -n "$p" ] || continue; printf "%s\t%s\n" "$(file_mtime "$p")" "$p"; done | sort -n  -k1,1 | awk -F'\t' '{print $2}';;
    size)      while IFS= read -r p; do [ -n "$p" ] || continue; printf "%s\t%s\n" "$(file_size "$p")" "$p"; done | sort -nr -k1,1 | awk -F'\t' '{print $2}';;
    sizesmall) while IFS= read -r p; do [ -n "$p" ] || continue; printf "%s\t%s\n" "$(file_size "$p")" "$p"; done | sort -n  -k1,1 | awk -F'\t' '{print $2}';;
    shortpath) while IFS= read -r p; do [ -n "$p" ] || continue; printf "%s\t%s\n" "$(path_len "$p")" "$p"; done | sort -n  -k1,1 | awk -F'\t' '{print $2}';;
    longpath)  while IFS= read -r p; do [ -n "$p" ] || continue; printf "%s\t%s\n" "$(path_len "$p")" "$p"; done | sort -nr -k1,1 | awk -F'\t' '{print $2}';;
    name|*)    sort;;
  esac
}
ltrim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//'; }

info "Preparing interactive review…"
info "Using report: $REPORT"
info "Plan file: $PLAN_OUT"
info "Order: $ORDER"

TOTAL_GROUPS="$(count_groups)"
[ "$TOTAL_GROUPS" -gt 0 ] || { warn "No groups found (no lines starting with 'HASH ')."; exit 0; }
info "Found $TOTAL_GROUPS groups."

# Scope prompt
MAX_GROUPS="$TOTAL_GROUPS"
echo
echo "How many groups or what percentage to review?"
echo "  - Enter a number (e.g., 250) or a percentage (e.g., 19%)"
echo "  - Press Enter for ALL ($TOTAL_GROUPS groups)"
printf "Review scope: "
if [ -t 0 ]; then read scope; else read scope </dev/tty; fi
case "${scope:-}" in
  *%) pct="$(printf "%s" "$scope" | tr -d ' %')"; case "$pct" in *[!0-9]*|'') pct=100;; esac
       [ "$pct" -lt 1 ] && pct=1; [ "$pct" -gt 100 ] && pct=100
       MAX_GROUPS=$(( (TOTAL_GROUPS * pct + 99) / 100 ))
       info "Will review ~${pct}%% → $MAX_GROUPS of $TOTAL_GROUPS groups.";;
  '') info "Reviewing ALL $TOTAL_GROUPS groups."; MAX_GROUPS="$TOTAL_GROUPS";;
  *)  case "$scope" in *[!0-9]* ) scope="$TOTAL_GROUPS";; esac
       [ "$scope" -lt 1 ] && scope=1; [ "$scope" -gt "$TOTAL_GROUPS" ] && scope="$TOTAL_GROUPS"
       MAX_GROUPS="$scope"; info "Will review first $MAX_GROUPS of $TOTAL_GROUPS groups.";;
esac

# Prepare cleaned exceptions list
EXC_CLEAN="$(clean_exceptions_file)"

# PASS 1: index potential savings
INDEX_FILE="$(mktemp "$VAR_DIR/revindex.XXXXXX")"
trap 'rm -f "$INDEX_FILE" "$TOP_FILE" "$TMP_GROUP" "$ORDERED" 2>/dev/null || true; rm -rf "$CAPDIR" 2>/dev/null || true; rm -f "$EXC_CLEAN" 2>/dev/null || true' EXIT INT TERM

gno=0; in_group=0; N=0; first_path=""; CUR_HASH=""

# FIX: grab_N was only checking start of match; now uses awk for robustness
grab_N(){ echo "$1" | awk 'match($0, /\(N=([0-9]+)\)/, a) {print a[1]} !match($0, /\(N=([0-9]+)\)/, a) {print ""}' 2>/dev/null || echo "$1" | sed -n 's/.*(N=\([0-9][0-9]*\)).*/\1/p'; }
grab_hash(){ echo "$1" | awk '{print $2}'; }

index_started="$(date +%s)"
info "Indexing duplicate groups (potential savings)…"

finish_group_index(){
  if [ "$in_group" -eq 1 ] && [ -n "${first_path:-}" ] && ! hash_is_exception "$CUR_HASH" "$EXC_CLEAN"; then
    sz="$(file_size "$first_path" 2>/dev/null || echo -1)"
    [ -z "$N" ] && N=2
    # If size lookup failed, treat as 0 for potential calculation
    case "$sz" in ''|-1|*[!0-9]*) sz_calc=0 ;; *) sz_calc="$sz" ;; esac
    pot=$(( ( ${N:-2} - 1 ) * ${sz_calc:-0} ))
    # fields: group_no, potential_bytes, N, first_path, hash, base_size
    printf "%d\t%llu\t%d\t%s\t%s\t%s\n" "$gno" "$pot" "${N:-2}" "$first_path" "$CUR_HASH" "$sz" >>"$INDEX_FILE"
  fi
}

# shellcheck disable=SC2162
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HASH\ *)
      finish_group_index
      gno=$((gno+1)); in_group=1; first_path=""; CUR_HASH=""; N="$(grab_N "$line")"; [ -z "$N" ] && N=2
      CUR_HASH="$(grab_hash "$line")"
      _progress_bar "INDEX" "$gno" "$TOTAL_GROUPS" "$index_started"
      ;;
    *)
      if [ "$in_group" -eq 1 ] && [ -z "${first_path:-}" ]; then
        t="$(ltrim "$line")"; case "$t" in /*) first_path="$t" ;; esac
      fi
      ;;
  esac
done <"$REPORT"
finish_group_index
_progress_bar "INDEX" "$gno" "$TOTAL_GROUPS" "$index_started"; printf "\n" >&2

# FIX: removed cat antipattern; sort reads INDEX_FILE directly
TOP_FILE="$(mktemp "$VAR_DIR/revtop.XXXXXX")"
sort -nr -k2,2 "$INDEX_FILE" | head -n "$MAX_GROUPS" >"$TOP_FILE" || true

# FIX: use awk instead of wc -l for reliable line counting
SELECTED_TOTAL="$(awk 'END{print NR}' "$TOP_FILE")"
[ "$SELECTED_TOTAL" -gt 0 ] || { warn "No groups selected after indexing (all may be excluded by exceptions)."; exit 0; }

# Build a fast lookup (space-delimited) and per-group temp files dir
SELECTED_MAP=" "
CAPDIR="$(mktemp -d "$VAR_DIR/revcap.XXXXXX")"
# shellcheck disable=SC2162
while IFS= read -r row || [ -n "$row" ]; do
  g="$(printf "%s" "$row" | awk -F'\t' '{print $1}')"
  [ -n "$g" ] && SELECTED_MAP="$SELECTED_MAP$g "
done <"$TOP_FILE"

# PASS 2A: single linear pass to capture only selected groups to temp files
cap_started="$(date +%s)"
captured=0
info "Capturing selected groups…"
gno=0; in_group=0; cur_gno=0
# shellcheck disable=SC2162
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HASH\ *)
      gno=$((gno+1)); in_group=0; cur_gno="$gno"
      case " $SELECTED_MAP " in
        *" $cur_gno "*) in_group=1; : >"$CAPDIR/$cur_gno"; captured=$((captured+1)) ;;
        *) in_group=0 ;;
      esac
      _progress_bar "CAPTURE" "$captured" "$SELECTED_TOTAL" "$cap_started"
      ;;
    *)
      if [ "$in_group" -eq 1 ]; then
        t="$(ltrim "$line")"; case "$t" in /*) printf "%s\n" "$t" >>"$CAPDIR/$cur_gno" ;; esac
      fi
      ;;
  esac
done <"$REPORT"
_progress_bar "CAPTURE" "$captured" "$SELECTED_TOTAL" "$cap_started"; printf "\n" >&2

# PASS 2B: present groups in savings-desc order using captured files
START_TS="$(date +%s)"; files_seen=0; reviewed=0
TMP_GROUP="$(mktemp "$VAR_DIR/revgrp.XXXXXX")"; ORDERED="$(mktemp "$VAR_DIR/revord.XXXXXX")"

present_group(){
  gno="$1"
  reviewed=$((reviewed+1))
  progress_review "$reviewed" "$SELECTED_TOTAL" "$files_seen" "$START_TS"

  cp "$CAPDIR/$gno" "$TMP_GROUP" 2>/dev/null || : >"$TMP_GROUP"
  cat "$TMP_GROUP" | order_group >"$ORDERED" 2>/dev/null || cp "$TMP_GROUP" "$ORDERED"

  echo; echo
  first="$(head -n1 "$ORDERED" 2>/dev/null || true)"
  base_size=0; Nval=2; group_hash=""
  if [ -n "$first" ]; then
    base_size="$(awk -v g="$gno" -F'\t' '$1==g{print $6}' "$INDEX_FILE" 2>/dev/null | head -n1)"
    case "$base_size" in ''|-1) base_size="$(file_size "$first" 2>/dev/null || echo -1)" ;; esac
  fi
  Nval="$(awk -v g="$gno" -F'\t' '$1==g{print $3}' "$INDEX_FILE" 2>/dev/null | head -n1)"; [ -z "$Nval" ] && Nval=2
  group_hash="$(awk -v g="$gno" -F'\t' '$1==g{print $5}' "$INDEX_FILE" 2>/dev/null | head -n1)"
  case "$base_size" in ''|-1|*[!0-9]*) pot=0 ;; *) pot=$(( (Nval - 1) * base_size )) ;; esac

  printf "%s[Group %d/%d]%s  (order: %s)  potential: %s (N=%d, size=%s)\n" \
    "$C1" "$reviewed" "$SELECTED_TOTAL" "$C0" "$ORDER" \
    "$(human_size "$pot")" "$Nval" "$(human_size "$base_size")"

  # FIX: sizes are ALWAYS shown regardless of ORDER mode.
  # FIX: counter i was not incremented in the old size-ordered branch.
  i=0
  while IFS= read -r fp || [ -n "$fp" ]; do
    i=$((i+1))
    sz="$(file_size "$fp" 2>/dev/null || echo -1)"
    hs="$(human_size "$sz")"
    printf "  %2d) %-8s  %s\n" "$i" "[$hs]" "$fp"
  done <"$ORDERED"

  # FIX: use awk for reliable line count
  files_in_group="$(awk 'END{print NR}' "$ORDERED")"
  [ "$files_in_group" -gt 0 ] || return 0

  # --- SAFER INPUT LOOP ---
  while :; do
    echo
    echo "Choose which file to KEEP:"
    echo "  - Enter the number (e.g., 1) to keep that file (others go to plan)"
    echo "  - s = skip group (decide later)"
    echo "  - A = add this hash to exceptions list and skip this group"
    echo "  - D = delete ALL copies in this group"
    echo "  - q = quit (plan so far is preserved)"
    printf "Your choice: "
    if [ -t 0 ]; then
      if ! IFS= read -r choice; then
        choice="q"
      fi
    else
      if ! IFS= read -r choice </dev/tty; then
        choice="q"
      fi
    fi

    case "$choice" in
      [sS])
        echo "   -> Skipping this group."
        break
        ;;

      [aA])
        add_to_exceptions "$group_hash" "$base_size"
        echo "   -> Group skipped; hash added to exceptions list."
        break
        ;;

      [qQ])
        echo
        info "Quitting interactive review early (plan so far is preserved)."
        progress_review "$reviewed" "$SELECTED_TOTAL" "$files_seen" "$START_TS"
        echo; echo
        info "Plan saved to: $PLAN_OUT"
        exit 0
        ;;

      [dD])
        printf "Please confirm that you wish to delete all copies of this file (this entire group) [y/N] "
        if [ -t 0 ]; then
          if ! IFS= read -r confirm; then
            confirm="n"
          fi
        else
          if ! IFS= read -r confirm </dev/tty; then
            confirm="n"
          fi
        fi
        case "$confirm" in
          [yY])
            # shellcheck disable=SC2162
            while IFS= read -r fp || [ -n "$fp" ]; do
              [ -z "$fp" ] && continue
              printf "DEL|%s\n" "$fp" >>"$PLAN_OUT"
            done <"$ORDERED"
            echo "   -> All copies in this group have been marked for deletion in the plan."
            break
            ;;
          *)
            echo "   -> Delete-all cancelled; please choose again."
            ;;
        esac
        ;;

      *)
        # numeric choice – must be between 1 and $files_in_group
        case "$choice" in
          ''|*[!0-9]*)
            echo "Invalid choice. Please enter a number between 1 and $files_in_group, or s, A, D, q."
            ;;
          *)
            sel="$choice"
            if [ "$sel" -lt 1 ] || [ "$sel" -gt "$files_in_group" ]; then
              echo "Invalid choice. Please enter a number between 1 and $files_in_group, or s, A, D, q."
            else
              # KEEP selected index, DELETE others
              idx=0
              # shellcheck disable=SC2162
              while IFS= read -r fp || [ -n "$fp" ]; do
                [ -z "$fp" ] && continue
                idx=$((idx+1))
                if [ "$idx" -eq "$sel" ]; then
                  printf "KEEP|%s\n" "$fp" >>"$PLAN_OUT"
                else
                  printf "DEL|%s\n" "$fp" >>"$PLAN_OUT"
                fi
              done <"$ORDERED"
              echo "   -> Choice recorded: keeping #$sel, others marked for deletion."
              break
            fi
            ;;
        esac
        ;;
    esac
  done
  # --- END SAFER INPUT LOOP ---

  files_seen=$((files_seen + files_in_group))
  : >"$TMP_GROUP"; : >"$ORDERED"
}

# shellcheck disable=SC2162
while IFS= read -r row || [ -n "$row" ]; do
  g="$(printf "%s" "$row" | awk -F'\t' '{print $1}')"
  [ -s "$CAPDIR/$g" ] && present_group "$g"
done <"$TOP_FILE"

progress_review "$reviewed" "$SELECTED_TOTAL" "$files_seen" "$START_TS"
echo; echo
info "Interactive review complete."
info "Plan saved to: $PLAN_OUT"
exit 0
