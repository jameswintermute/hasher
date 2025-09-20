#!/bin/sh
# review-duplicates.sh — POSIX/BusyBox-friendly interactive reviewer
# Features:
# - Progress indicators: parsing groups & ranking by size
# - Ordering: --order size|count (default count). "size" ranks by total bytes using latest logs/duplicates-*.csv
# - Pre-run summary & selection: choose % (10/25/50/100) or exact number of groups to review
# - Interactive: Enter=accept suggested, number=N picks keeper N, 'k N' sets keeper, 's' skip, 'q' quit
set -eu
IFS="$(printf '\n\t')"

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$APP_HOME/logs"; mkdir -p "$LOGS_DIR"
VAR_DIR="$APP_HOME/var/duplicates"; mkdir -p "$VAR_DIR"

COK="$(printf '\033[0;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[0;31m')"; CCYAN="$(printf '\033[0;36m')"; CRESET="$(printf '\033[0m')"
info(){ printf "%s[INFO]%s %s\n" "$COK" "$CRESET" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR" "$CRESET" "$*"; }
next(){ printf "%s[NEXT]%s %s\n" "$CCYAN" "$CRESET" "$*"; }

usage(){
cat <<'EOF'
Usage: review-duplicates.sh --from-report FILE [options]
  --from-report FILE     Canonical duplicate-hashes report
  --limit N              Review at most N groups (default 50; overridden by interactive % selection)
  --keep POLICY          newest|oldest|first|last (default newest)
  --non-interactive      Apply policy without prompts
  --order size|count     Order groups by total duplicate bytes (size) or by count (default: count)
EOF
}

REPORT=""; LIMIT=50; KEEP="newest"; NONINT=0; ORDER="count"
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-50}"; shift 2 ;;
    --keep) KEEP="${2:-newest}"; shift 2 ;;
    --non-interactive) NONINT=1; shift ;;
    --order) ORDER="${2:-count}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 2 ;;
  esac
done
[ -n "$REPORT" ] || { err "Missing --from-report"; usage; exit 2; }
[ -f "$REPORT" ] || { err "Report not found: $REPORT"; exit 2; }

timestamp="$(date +'%Y-%m-%d-%H%M%S')"
PLAN="$LOGS_DIR/review-dedupe-plan-$timestamp.txt"; : > "$PLAN"
QUIT=0

# tiny ui helpers ---------------------------------------------------------
is_tty(){ [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; }
draw_bar(){ # $1=cur $2=tot $3=label
  cur="$1"; tot="$2"; label="$3"; width=40
  if [ "${tot:-0}" -gt 0 ]; then perc=$(( cur * 100 / tot )); else perc=0; fi
  [ "$perc" -gt 100 ] && perc=100
  filled=$(( perc * width / 100 )); empty=$(( width - filled ))
  hashes="$(printf "%${filled}s" | tr ' ' '#')"
  spaces="$(printf "%${empty}s")"
  printf "\r[%s%s] %3d%%  %s" "$hashes" "$spaces" "$perc" "$label"
}
human(){ bytes="$1"; awk -v b="$bytes" 'BEGIN{
  if (b<1024) printf "%d B", b;
  else if (b<1024*1024) printf "%.1f KiB", b/1024;
  else if (b<1024*1024*1024) printf "%.1f MiB", b/1048576;
  else printf "%.2f GiB", b/1073741824;
}'; }

get_mtime(){ stat -c '%Y' -- "$1" 2>/dev/null || echo 0; }
get_size(){  stat -c '%s' -- "$1" 2>/dev/null || echo 0; }

review_group() {
  hash="$1"; shift
  count=$#
  [ "$count" -ge 2 ] || return 0

  # default keeper proposal
  keeper="$1"
  if [ "$KEEP" = "newest" ] || [ "$KEEP" = "oldest" ]; then
    best="$([ "$KEEP" = "newest" ] && echo 0 || echo 9999999999)"
    for p in "$@"; do
      mt="$(get_mtime "$p")"
      if [ "$KEEP" = "newest" ]; then
        [ "$mt" -gt "$best" ] && best="$mt" && keeper="$p"
      else
        [ "$mt" -lt "$best" ] && best="$mt" && keeper="$p"
      fi
    done
  elif [ "$KEEP" = "last" ]; then
    for p in "$@"; do keeper="$p"; done
  fi

  # Compute potential reclaim if we accept now: sum(size) - size(keeper)
  keep_size="$(get_size "$keeper")"; sum_size=0
  for p in "$@"; do s="$(get_size "$p")"; sum_size=$((sum_size + s)); done
  potential=$((sum_size - keep_size))

  if [ "$NONINT" -eq 1 ]; then
    for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
    SAVED=$((SAVED + potential))
    return 0
  fi

  echo
  echo "─ Group  hash: $hash  (N=$count)  (potential reclaim: $(human "$potential"))"
  i=0
  for p in "$@"; do
    i=$((i+1))
    mark=" "; [ "$p" = "$keeper" ] && mark="*"
    printf "  %2d) %s%s\n" "$i" "$mark" "$p"
  done
  echo "    Policy: $KEEP  [* marks suggested keeper]"
  printf "    Action: (Enter=accept) [N=pick keep] [k N=set keep] [s=skip] [q=quit] > "
  read -r ans || ans="q"
  trimmed="$(printf "%s" "$ans" | tr -d '\r' | sed 's/^[[:space:]]*$//')"

  # Default to ACCEPT on unknown input to avoid user friction
  accept_now=0
  if [ -z "$trimmed" ]; then
    accept_now=1
  elif [ "$trimmed" = "q" ] || [ "$trimmed" = "Q" ]; then
    info "Stopping early per user request."; QUIT=1; return 0
  elif [ "$trimmed" = "s" ] || [ "$trimmed" = "S" ]; then
    return 0
  elif printf "%s" "$trimmed" | grep -Eq '^k[[:space:]]+[0-9]+$'; then
    n="$(printf "%s" "$trimmed" | awk '{print $2}')"
    if [ "$n" -ge 1 ] 2>/dev/null; then
      i=0; for p in "$@"; do i=$((i+1)); [ "$i" -eq "$n" ] && keeper="$p"; done
      keep_size="$(get_size "$keeper")"; potential=$((sum_size - keep_size))
      accept_now=1
    fi
  elif printf "%s" "$trimmed" | grep -Eq '^[0-9]+$'; then
    n="$trimmed"
    if [ "$n" -ge 1 ] 2>/dev/null; then
      i=0; for p in "$@"; do i=$((i+1)); [ "$i" -eq "$n" ] && keeper="$p"; done
      keep_size="$(get_size "$keeper")"; potential=$((sum_size - keep_size))
      accept_now=1
    fi
  else
    accept_now=1  # treat as Enter
  fi

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
PROG1="$TMPDIR/p1.txt"; : > "$PROG1"
(
  awk -v dir="$TMPDIR" '
    BEGIN{g=0}
    /^HASH[[:space:]]/ { g++; h=$2; print h >> "'"$HASHLIST"'"; next }
    /^[[:space:]]*$/ { next }
    /^  / { sub(/^[ ]+/, "", $0); if (h!="") print $0 >> dir "/" h ".grp"; next }
  ' "$REPORT"
  echo "$TOTAL_GROUPS" > "$PROG1"
) & PID1=$!
# progress
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  while kill -0 "$PID1" >/dev/null 2>&1; do
    cur="$(wc -l < "$HASHLIST" 2>/dev/null || echo 0)"
    draw_bar "${cur:-0}" "${TOTAL_GROUPS:-0}" "Parsing groups…"
    sleep 0.2
  done
  draw_bar "${TOTAL_GROUPS:-0}" "${TOTAL_GROUPS:-0}" "Parsing groups…"; echo
fi
wait "$PID1" || { err "Failed to parse report."; exit 1; }

# Phase 1b: quick summary (files to review & potential reclaim)
CSV="$(ls -1t "$LOGS_DIR"/duplicates-*.csv 2>/dev/null | head -n1 || true)"
if [ -n "${CSV:-}" ] && [ -f "$CSV" ]; then
  # potential reclaim ≈ sum(size) - max(size) per hash
  # dup_files = (count-1) per hash, summed
  read -r POT DUPFILES <<EOF_SUM
$(awk -F',' '
  NR==FNR { need[$0]=1; next }
  ( $1 in need ) {
    h=$1; s=$3; if (s=="") s=0;
    sum[h]+=s; cnt[h]++; if (s>max[h]) max[h]=s;
  }
  END {
    pot=0; dup=0;
    for (h in sum) { pot += sum[h]-max[h]; dup += (cnt[h]-1); }
    print pot, dup
  }
' "$HASHLIST" "$CSV")
EOF_SUM
else
  # fallback: dup_files only from group files; pot unknown
  POT=0
  DUPFILES="$(awk '{c[$0]++} END{ n=0; for(k in c){ if (c[k]>1) n+=c[k]-1 } print n }' "$HASHLIST" 2>/dev/null || echo 0)"
fi

TOTAL_GROUPS="$(wc -l < "$HASHLIST" 2>/dev/null || echo 0)"
info "Summary: Groups: $TOTAL_GROUPS  | Duplicate files (deletable): ${DUPFILES:-0}  | Potential reclaim: $(human "${POT:-0}")"

# Phase 1c: ask user how much to review this pass (percentage or exact groups)
if [ "$NONINT" -eq 0 ]; then
  defpct=10
  printf "How much to review this pass? Enter %% (10/25/50/100) or exact group count (e.g. 500). [default: %d%%] > " "$defpct"
  read -r sel || sel=""
  sel="$(printf "%s" "$sel" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if printf "%s" "$sel" | grep -Eq '^[0-9]+%$'; then
    p="$(printf "%s" "$sel" | tr -d '%')"
    [ "$p" -gt 100 ] 2>/dev/null && p=100
    LIMIT=$(( (TOTAL_GROUPS * p + 99) / 100 ))
  elif printf "%s" "$sel" | grep -Eq '^[0-9]+$'; then
    LIMIT="$sel"
  else
    LIMIT=$(( (TOTAL_GROUPS * defpct + 99) / 100 ))
  fi
  info "Reviewing up to $LIMIT groups this pass."
fi

# Phase 2: build ordering
ORDER_FILE="$TMPDIR/order.txt"; : > "$ORDER_FILE"
if [ "$ORDER" = "size" ]; then
  if [ -n "${CSV:-}" ] && [ -f "$CSV" ]; then
    info "Ranking groups by total size (largest first)…"
    TOTAL_LINES="$(wc -l < "$CSV" 2>/dev/null || echo 0)"
    PROG2="$TMPDIR/p2.txt"; : > "$PROG2"
    (
      awk -F',' -v step=50000 '
        NR==FNR { ok[$0]=1; next }
        {
          h=$1; s=$3; if (s=="") s=0;
          if (h in ok) sum[h]+=s;
          if (NR%step==0) print NR > "'"$PROG2"'";
        }
        END { for (k in sum) printf "%012d %s\n", sum[k], k }
      ' "$HASHLIST" "$CSV" | sort -nr > "$ORDER_FILE"
      echo "$TOTAL_LINES" > "$PROG2"
    ) & PID2=$!
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
      while kill -0 "$PID2" >/dev/null 2>&1; do
        cur="$(tail -n1 "$PROG2" 2>/dev/null || echo 0)"
        draw_bar "${cur:-0}" "${TOTAL_LINES:-0}" "Ranking by size from $(basename "$CSV")…"
        sleep 0.2
      done
      draw_bar "${TOTAL_LINES:-0}" "${TOTAL_LINES:-0}" "Ranking by size from $(basename "$CSV")…"; echo
    fi
    wait "$PID2" || { err "Failed to rank by size."; exit 1; }
  else
    warn "No duplicates-*.csv found; falling back to count ordering."
    ORDER="count"
  fi
fi

if [ "$ORDER" = "count" ]; then
  info "Ranking groups by file count (largest first)…"
  for f in "$TMPDIR"/*.grp; do
    [ -f "$f" ] || continue
    h="$(basename "$f" .grp)"
    c="$(wc -l < "$f" 2>/dev/null || echo 0)"
    printf "%012d %s\n" "$c" "$h" >> "$ORDER_FILE"
  done
  sort -nr "$ORDER_FILE" -o "$ORDER_FILE"
fi

# Phase 3: interactive review
shown=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "${line:-}" ] && continue
  h="$(printf "%s" "$line" | awk '{print $2}')"
  f="$TMPDIR/$h.grp"
  [ -s "$f" ] || continue
  gpaths="$(cat "$f")"
  oldIFS=$IFS; IFS="$(printf '\n\t')"; set -- $gpaths; IFS=$oldIFS
  review_group "$h" "$@"
  [ "$QUIT" -eq 1 ] && break
  shown=$((shown+1))
  [ "$shown" -ge "$LIMIT" ] && break
done < "$ORDER_FILE"

echo
info "Review complete. Planned deletions so far: $(wc -l < "$PLAN" 2>/dev/null || echo 0) files"
info "Estimated reclaim from accepted groups: $(human "$SAVED")"
info "Plan: $PLAN"
cp -f -- "$PLAN" "$VAR_DIR/latest-plan.txt" 2>/dev/null || true
next "Use menu option 6 to apply the plan."
exit 0
