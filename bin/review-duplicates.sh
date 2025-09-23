#!/bin/sh
# review-duplicates.sh — top-savings-first interactive reviewer (streaming, BusyBox-safe)
# Hasher — NAS File Hasher & Duplicate Finder (GPLv3)
# Internals optimized: capture selected groups in one pass, no re-scan per group
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs"; mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";  mkdir -p "$VAR_DIR"

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
  - You'll be asked how many groups or what percentage to review.
EOF
}

warn()  { printf "%s[WARN]%s %s\n"  "$C2"  "$C0" "$1" >&2; }
info()  { printf "%s[INFO]%s %s\n"  "$COK" "$C0" "$1" >&2; }
error() { printf "%s[ERROR]%s %s\n" "$CERR" "$C0" "$1" >&2; }

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

count_groups() { grep -c '^HASH ' "$REPORT" 2>/dev/null || echo 0; }
htime(){ s="${1:-0}"; [ "$s" -ge 60 ] 2>/dev/null && { m=$((s/60)); r=$((s%60)); printf "%dm %02ds" "$m" "$r"; } || printf "%ds" "$s"; }

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
  i=0; BAR=""; while [ $i -lt $filled ]; do BAR="${BAR}#"; i=$((i+1)); done
  while [ $i -lt $barw ]; do BAR="${BAR}-"; i=$((i+1)); done
  printf "\r%s[%s]%s %3d%% [%s]  %d/%d  Elapsed %s  ETA %s    " \
    "$C1" "$label" "$C0" "$pct" "$BAR" "$cur" "$total" "$(htime "$elapsed")" "$(htime "$eta")" >&2
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
  i=0; BAR=""; while [ $i -lt $filled ]; do BAR="${BAR}#"; i=$((i+1)); done
  while [ $i -lt $barw ]; do BAR="${BAR}-"; i=$((i+1)); done
  printf "\r%s[PROGRESS]%s %3d%% [%s]  Group %d/%d  Files %d  Elapsed %s  ETA %s    " \
    "$C1" "$C0" "$pct" "$BAR" "$cur" "$total" "$files_seen" "$(htime "$elapsed")" "$(htime "$eta")" >&2
}

file_mtime(){ f="$1"; stat -c %Y "$f" 2>/dev/null && return 0 || true; busybox stat -c %Y "$f" 2>/dev/null && return 0 || true; stat -f %m "$f" 2>/dev/null && return 0 || true; date -r "$f" +%s 2>/dev/null && return 0 || true; echo 0; }
file_size(){ f="$1"; stat -c %s "$f" 2>/dev/null && return 0 || true; busybox stat -c %s "$f" 2>/dev/null && return 0 || true; stat -f %z "$f" 2>/dev/null && return 0 || true; wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0; }
path_len(){ printf "%s" "$1" | wc -c | tr -d ' '; }
human_size(){ b="${1:-0}"; if [ "$b" -ge 1073741824 ] 2>/dev/null; then printf "%.1fG" "$(awk "BEGIN{print $b/1073741824}")"; elif [ "$b" -ge 1048576 ] 2>/dev/null; then printf "%.1fM" "$(awk "BEGIN{print $b/1048576}")"; elif [ "$b" -ge 1024 ] 2>/dev/null; then printf "%.1fK" "$(awk "BEGIN{print $b/1024}")"; else printf "%dB" "$b"; fi; }
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

# PASS 1: index potential savings
INDEX_FILE="$(mktemp "$VAR_DIR/revindex.XXXXXX")"
trap 'rm -f "$INDEX_FILE" "$TOP_FILE" "$TMP_GROUP" "$ORDERED" "$CAPDIR"/* 2>/dev/null || true; rmdir "$CAPDIR" 2>/dev/null || true' EXIT INT TERM

gno=0; in_group=0; N=0; first_path=""
grab_N(){ echo "$1" | sed -n 's/.*(N=\([0-9][0-9]*\)).*/\1/p'; }

index_started="$(date +%s)"
info "Indexing duplicate groups (potential savings)…"

finish_group_index(){
  if [ "$in_group" -eq 1 ] && [ -n "${first_path:-}" ]; then
    sz="$(file_size "$first_path" 2>/dev/null || echo 0)"; [ -z "$N" ] && N=2; [ -z "$sz" ] && sz=0
    pot=$(( ( ${N:-2} - 1 ) * ${sz:-0} ))
    printf "%d\t%llu\t%d\t%s\n" "$gno" "$pot" "${N:-2}" "$first_path" >>"$INDEX_FILE"
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HASH\ *)
      finish_group_index
      gno=$((gno+1)); in_group=1; first_path=""; N="$(grab_N "$line")"; [ -z "$N" ] && N=2
      _progress_bar "INDEX" "$gno" "$TOTAL_GROUPS" "$index_started"
      ;;
    *)
      if [ "$in_group" -eq 1 ] && [ -z "${first_path:-}" ]; then
        t="$(ltrim "$line")"; case "$t" in /*) first_path="$t" ;; esac
      fi
      ;;
  esac
done <"$REPORT"
finish_group_index; _progress_bar "INDEX" "$gno" "$TOTAL_GROUPS" "$index_started"; printf "\n" >&2

# Pick top MAX_GROUPS
TOP_FILE="$(mktemp "$VAR_DIR/revtop.XXXXXX")"
cat "$INDEX_FILE" | sort -nr -k2,2 | head -n "$MAX_GROUPS" >"$TOP_FILE" || true
SELECTED_TOTAL="$(wc -l <"$TOP_FILE" | tr -d ' ')"
[ "$SELECTED_TOTAL" -gt 0 ] || { warn "No groups selected after indexing."; exit 0; }

# Build a fast lookup (space-delimited) and per-group temp files dir
SELECTED_MAP=" "
CAPDIR="$(mktemp -d "$VAR_DIR/revcap.XXXXXX")"
while IFS= read -r row; do
  g="$(printf "%s" "$row" | awk -F'\t' '{print $1}')"
  [ -n "$g" ] && SELECTED_MAP="$SELECTED_MAP$g "
done <"$TOP_FILE"

# PASS 2A: single linear pass to capture only selected groups to temp files
cap_started="$(date +%s)"
captured=0
info "Capturing selected groups…"
gno=0; in_group=0; cur_gno=0
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
  reviewed=$((reviewed+1))
  progress_review "$reviewed" "$SELECTED_TOTAL" "$files_seen" "$START_TS"

  cp "$CAPDIR/$1" "$TMP_GROUP" 2>/dev/null || : >"$TMP_GROUP"
  cat "$TMP_GROUP" | order_group >"$ORDERED" 2>/dev/null || cp "$TMP_GROUP" "$ORDERED"

  echo; echo
  first="$(head -n1 "$ORDERED" 2>/dev/null || true)"
  base_size=0; Nval=2
  [ -n "$first" ] && base_size="$(file_size "$first" 2>/dev/null || echo 0)"
  Nval="$(awk -v g="$1" -F'\t' '$1==g{print $3}' "$INDEX_FILE" 2>/dev/null | head -n1)"; [ -z "$Nval" ] && Nval=2
  pot=$(( (Nval - 1) * base_size ))
  printf "%s[Group %d/%d]%s  (order: %s)  potential: %s (N=%d, size=%s)\n" \
    "$C1" "$reviewed" "$SELECTED_TOTAL" "$C0" "$ORDER" "$(human_size "$pot")" "$Nval" "$(human_size "$base_size")"

  i=0
  if [ "$ORDER" = "size" ] || [ "$ORDER" = "sizesmall" ]; then
    while IFS= read -r fp; do
      i=$((i+1)); sz="$(file_size "$fp" 2>/dev/null || echo 0)"; hs="$(human_size "$sz")"
      printf "  %2d) %-8s  %s\n" "$i" "[$hs]" "$fp"
    done <"$ORDERED"
  else
    while IFS= read -r fp; do i=$((i+1)); printf "  %2d) %s\n" "$i" "$fp"; done <"$ORDERED"
  fi

  echo
  echo "Choose which file to KEEP:"
  echo "  - Enter the number (e.g., 1) to keep that file (others go to plan)"
  echo "  - s = skip group (decide later)"
  echo "  - q = quit (plan so far is preserved)"
  printf "Your choice: "
  if [ -t 0 ]; then read ans; else read ans </dev/tty; fi

  case "$ans" in
    q|Q) echo; warn "Stopping early at group $reviewed. Plan saved: $PLAN_OUT"; exit 0 ;;
    s|S|'') : ;;
    *) case "$ans" in *[!0-9]*|'') echo "Invalid choice. Skipping group." ;;
       *) choice="$ans"; j=0; while IFS= read -r fp; do j=$((j+1)); [ "$j" -ne "$choice" ] && printf "%s\n" "$fp" >> "$PLAN_OUT"; done <"$ORDERED";;
       esac ;;
  esac

  files_in_group="$(wc -l <"$ORDERED" | tr -d ' ')"
  files_seen=$((files_seen + files_in_group))
  : >"$TMP_GROUP"; : >"$ORDERED"
}

while IFS= read -r row; do
  g="$(printf "%s" "$row" | awk -F'\t' '{print $1}')"
  [ -s "$CAPDIR/$g" ] && present_group "$g"
done <"$TOP_FILE"

progress_review "$reviewed" "$SELECTED_TOTAL" "$files_seen" "$START_TS"
echo; echo
info "Interactive review complete."
info "Plan saved to: $PLAN_OUT"
exit 0
