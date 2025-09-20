#!/bin/sh
# review-duplicates.sh — POSIX/BusyBox-friendly interactive reviewer
# Reads from the controlling TTY (FD 3/4) so prompts always block even when launched from a parent menu.
# Progress bars, size ordering, per-group reclaim, summary, and %/count scope selection.
set -eu
IFS="$(printf '\n\t')"

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$APP_HOME/logs"; mkdir -p "$LOGS_DIR"
VAR_DIR="$APP_HOME/var/duplicates"; mkdir -p "$VAR_DIR"

# Open dedicated TTY FDs for reliable prompts/reads
if [ -r /dev/tty ]; then
  exec 3</dev/tty 4>/dev/tty
else
  # Fallback to stdin/stdout
  exec 3<&0 4>&1
fi

COK="$(printf '\033[0;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[0;31m')"; CCYAN="$(printf '\033[0;36m')"; CRESET="$(printf '\033[0m')"
info(){ printf "%s[INFO]%s %s\n" "$COK" "$CRESET" "$*" >&4; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR" "$CRESET" "$*"; }
next(){ printf "%s[NEXT]%s %s\n" "$CCYAN" "$CRESET" "$*"; }

usage(){
cat >&4 <<'EOF'
Usage: review-duplicates.sh --from-report FILE [options]
  --from-report FILE     Canonical duplicate-hashes report
  --limit N              Review at most N groups (default 50)
  --keep POLICY          newest|oldest|first|last (default newest)
  --non-interactive      Apply policy without prompts
  --order size|count     Order groups by total duplicate bytes (size) or by count (default: count)
EOF
}

REPORT=""; LIMIT=50; KEEP="newest"; NONINT=0; ORDER="size"
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-50}"; shift 2 ;;
    --keep) KEEP="${2:-newest}"; shift 2 ;;
    --non-interactive) NONINT=1; shift ;;
    --order) ORDER="${2:-size}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 2 ;;
  esac
done
[ -n "$REPORT" ] || { err "Missing --from-report"; usage; exit 2; }
[ -f "$REPORT" ] || { err "Report not found: $REPORT"; exit 2; }

timestamp="$(date +'%Y-%m-%d-%H%M%S')"
PLAN="$LOGS_DIR/review-dedupe-plan-$timestamp.txt"; : > "$PLAN"
QUIT=0

is_tty(){ [ -t 4 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; }
draw_bar(){ cur="$1"; tot="$2"; label="$3"; width=40
  if [ "${tot:-0}" -gt 0 ]; then perc=$(( cur * 100 / tot )); else perc=0; fi
  [ "$perc" -gt 100 ] && perc=100
  filled=$(( perc * width / 100 )); empty=$(( width - filled ))
  hashes="$(printf "%${filled}s" | tr ' ' '#')"; spaces="$(printf "%${empty}s")"
  printf "\r[%s%s] %3d%%  %s" "$hashes" "$spaces" "$perc" "$label" >&4
}
human(){ bytes="$1"; awk -v b="$bytes" 'BEGIN{
  if (b<1024) printf "%d B", b;
  else if (b<1024*1024) printf "%.1f KiB", b/1024;
  else if (b<1024*1024*1024) printf "%.1f MiB", b/1048576;
  else printf "%.2f GiB", b/1073741824;
}'; }

get_mtime(){ stat -c '%Y' -- "$1" 2>/dev/null || echo 0; }
get_size(){  stat -c '%s' -- "$1" 2>/dev/null || echo 0; }

read_prompt(){
  prompt="$1"
  printf "%s" "$prompt" >&4
  : >&4
  set +e
  IFS= read -r ans <&3
  rc=$?
  set -e
  [ $rc -ne 0 ] && return 1
  printf "%s" "$ans"
  return 0
}

review_group() {
  hash="$1"; shift
  TMPG="$(mktemp)"; printf "%s\n" "$@" | sed '/^[[:space:]]*$/d' | sort -u > "$TMPG"
  set -- $(cat "$TMPG"); rm -f "$TMPG"
  count=$#
  [ "$count" -ge 2 ] || return 0

  keeper="$1"
  if [ "$KEEP" = "newest" ] || [ "$KEEP" = "oldest" ]; then
    best="$([ "$KEEP" = "newest" ] && echo 0 || echo 9999999999)"
    for p in "$@"; do
      mt="$(get_mtime "$p")"
      if [ "$KEEP" = "newest" ]; then [ "$mt" -gt "$best" ] && best="$mt" && keeper="$p"
      else [ "$mt" -lt "$best" ] && best="$mt" && keeper="$p"
      fi
    done
  elif [ "$KEEP" = "last" ]; then for p in "$@"; do keeper="$p"; done ; fi

  keep_size="$(get_size "$keeper")"; sum_size=0
  for p in "$@"; do s="$(get_size "$p")"; sum_size=$((sum_size + s)); done
  potential=$((sum_size - keep_size))

  if [ "$NONINT" -eq 1 ]; then
    for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
    SAVED=$((SAVED + potential)); return 0
  fi

  echo >&4
  printf "─ Group  hash: %s  (N=%d)  (potential reclaim: %s)\n" "$hash" "$count" "$(human "$potential")" >&4
  i=0
  for p in "$@"; do i=$((i+1)); mark=" "; [ "$p" = "$keeper" ] && mark="*"; printf "  %2d) %s%s\n" "$i" "$mark" "$p" >&4; done
  printf "    Policy: %s  [* marks suggested keeper]\n" "$KEEP" >&4

  ans="$(read_prompt "    Action: (Enter=accept) [N=pick keep] [k N=set keep] [s=skip] [q=quit] > " || echo "__EOF__")"
  [ "$ans" = "__EOF__" ] && { info "Stopping (no TTY)."; QUIT=1; return 0; }
  trimmed="$(printf "%s" "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  accept_now=0
  if [ -z "$trimmed" ]; then accept_now=1
  elif [ "$trimmed" = "q" ] || [ "$trimmed" = "Q" ]; then info "Stopping early per user request."; QUIT=1; return 0
  elif [ "$trimmed" = "s" ] || [ "$trimmed" = "S" ]; then return 0
  elif printf "%s" "$trimmed" | grep -Eq '^k[[:space:]]+[0-9]+$'; then
       n="$(printf "%s" "$trimmed" | awk '{print $2}')"; if [ "$n" -ge 1 ] 2>/dev/null; then
         i=0; for p in "$@"; do i=$((i+1)); [ "$i" -eq "$n" ] && keeper="$p"; done
         keep_size="$(get_size "$keeper")"; potential=$((sum_size - keep_size)); accept_now=1; fi
  elif printf "%s" "$trimmed" | grep -Eq '^[0-9]+$'; then
       n="$trimmed"; if [ "$n" -ge 1 ] 2>/dev/null; then
         i=0; for p in "$@"; do i=$((i+1)); [ "$i" -eq "$n" ] && keeper="$p"; done
         keep_size="$(get_size "$keeper")"; potential=$((sum_size - keep_size)); accept_now=1; fi
  else accept_now=1; fi

  if [ "$accept_now" -eq 1 ]; then
    for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
    SAVED=$((SAVED + potential))
  fi
}

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

# Phase 1: parse report into group files and hash list
HASHLIST="$TMPDIR/hashes.txt"; : > "$HASHLIST"
info "Indexing duplicate groups…"
TOTAL_GROUPS="$(grep -c '^HASH[[:space:]]' "$REPORT" 2>/dev/null || echo 0)"
SAVED=0
(
  awk -v dir="$TMPDIR" '
    BEGIN{g=0}
    /^HASH[[:space:]]/ { g++; h=$2; print h >> "'"$HASHLIST"'"; next }
    /^[[:space:]]*$/ { next }
    /^  / { sub(/^[ ]+/, "", $0); if (h!="") print $0 >> dir "/" h ".grp"; next }
  ' "$REPORT"
) & PID1=$!
if is_tty; then
  while kill -0 "$PID1" >/dev/null 2>&1; do cur="$(wc -l < "$HASHLIST" 2>/dev/null || echo 0)"; draw_bar "${cur:-0}" "${TOTAL_GROUPS:-0}" "Parsing groups…"; sleep 0.2; done
  draw_bar "${TOTAL_GROUPS:-0}" "${TOTAL_GROUPS:-0}" "Parsing groups…"; echo >&4
fi
wait "$PID1" || { err "Failed to parse report."; exit 1; }

# Phase 1b: summary — compute deletables from group files (unique paths)
DUPFILES=0; FILESINGROUPS=0
for f in "$TMPDIR"/*.grp; do
  [ -f "$f" ] || continue
  c="$(sort -u "$f" | wc -l | tr -d ' ')"
  FILESINGROUPS=$((FILESINGROUPS + c))
  if [ "$c" -ge 2 ] 2>/dev/null; then DUPFILES=$((DUPFILES + c - 1)); fi
done

# Potential reclaim estimation using latest duplicates-*.csv (if present)
CSV="$(ls -1t "$LOGS_DIR"/duplicates-*.csv 2>/dev/null | head -n1 || true)"
POT=0
if [ -n "${CSV:-}" ] && [ -f "$CSV" ]; then
  POT="$(awk -F',' '
    NR==FNR { need[$0]=1; next }
    ( $1 in need ) { h=$1; s=$3; if (s=="") s=0; sum[h]+=s; if (s>max[h]) max[h]=s }
    END { pot=0; for (h in sum) pot += sum[h]-max[h]; print pot }
  ' "$HASHLIST" "$CSV" 2>/dev/null || echo 0)"
fi

TOTAL_GROUPS="$(wc -l < "$HASHLIST" 2>/dev/null || echo 0)"
info "Summary: Groups: $TOTAL_GROUPS  | Duplicate files (deletable): ${DUPFILES:-0}  | Potential reclaim: $(human "${POT:-0}")"
info "Scope hint: files-in-groups: $FILESINGROUPS | average files/group: $(awk -v f="$FILESINGROUPS" -v g="$TOTAL_GROUPS" 'BEGIN{ if(g>0) printf "%.2f\n", f/g; else print "0.00" }')"

# Phase 1c: scope selection
if [ "$NONINT" -eq 0 ]; then
  defpct=10
  sel="$(read_prompt "How much to review this pass? Enter % (10/25/50/100) or exact group count (e.g. 500). [default: ${defpct}%] > " || echo "")"
  sel="$(printf "%s" "$sel" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if printf "%s" "$sel" | grep -Eq '^[0-9]+%$'; then
    p="$(printf "%s" "$sel" | tr -d '%')"; [ "$p" -gt 100 ] 2>/dev/null && p=100
    LIMIT=$(( (TOTAL_GROUPS * p + 99) / 100  ))
  elif printf "%s" "$sel" | grep -Eq '^[0-9]+$'; then
    LIMIT="$sel"
  else
    LIMIT=$(( (TOTAL_GROUPS * defpct + 99) / 100  ))
  }
  info "Reviewing up to $LIMIT groups this pass."
fi

# Phase 2: build ordering
ORDER_FILE="$TMPDIR/order.txt"; : > "$ORDER_FILE"
if [ "$ORDER" = "size" ] && [ -n "${CSV:-}" ] && [ -f "$CSV" ]; then
  info "Ranking groups by total size (largest first)…"
  TOTAL_LINES="$(wc -l < "$CSV" 2>/dev/null || echo 0)"
  (
    awk -F',' '
      NR==FNR { ok[$0]=1; next }
      ( $1 in ok ) { s=$3; if (s=="") s=0; sum[$1]+=s }
      END { for (k in sum) printf "%012d %s\n", sum[k], k }
    ' "$HASHLIST" "$CSV" | sort -nr > "$ORDER_FILE"
  ) & PID2=$!
  if is_tty; then
    cur=0
    while kill -0 "$PID2" >/dev/null 2>&1; do
      cur=$((cur+50000)); draw_bar "$cur" "$TOTAL_LINES" "Ranking by size from $(basename "$CSV")…"; sleep 0.2
    done
    draw_bar "$TOTAL_LINES" "$TOTAL_LINES" "Ranking by size from $(basename "$CSV")…"; echo >&4
  fi
  wait "$PID2" || { err "Failed to rank by size."; exit 1; }
else
  [ "$ORDER" = "size" ] && warn "No duplicates-*.csv found; falling back to count ordering."
  info "Ranking groups by file count (largest first)…"
  for f in "$TMPDIR"/*.grp; do
    [ -f "$f" ] || continue
    c="$(sort -u "$f" | wc -l | tr -d ' ')"
    h="$(basename "$f" .grp)"
    printf "%012d %s\n" "$c" "$h" >> "$ORDER_FILE"
  done
  sort -nr "$ORDER_FILE" -o "$ORDER_FILE"
fi

# Phase 3: interactive review
shown=0; SAVED=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "${line:-}" ] && continue
  h="$(printf "%s" "$line" | awk '{print $2}')"
  f="$TMPDIR/$h.grp"; [ -s "$f" ] || continue
  gpaths="$(sort -u "$f")"
  oldIFS=$IFS; IFS="$(printf '\n\t')"; set -- $gpaths; IFS=$oldIFS
  review_group "$h" "$@"
  [ "$QUIT" -eq 1 ] && break
  shown=$((shown+1)); [ "$shown" -ge "$LIMIT" ] && break
done < "$ORDER_FILE"

echo >&4
info "Review complete. Planned deletions so far: $(wc -l < "$PLAN" 2>/dev/null || echo 0) files"
info "Estimated reclaim from accepted groups: $(human "$SAVED")"
info "Plan: $PLAN"
cp -f -- "$PLAN" "$VAR_DIR/latest-plan.txt" 2>/dev/null || true
next "Use menu option 6 to apply the plan."
exit 0
