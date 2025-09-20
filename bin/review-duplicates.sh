#!/bin/sh
# review-duplicates.sh — POSIX/BusyBox-friendly interactive reviewer
# - Reads canonical report: logs/*-duplicate-hashes.txt
# - Optional ordering: --order size|count (default count). "size" ranks by total bytes using latest logs/duplicates-*.csv
# - Interactive: Enter=accept suggested, 'k N'=set keeper index, number alone chooses keeper & accepts, 's'=skip, 'q'=quit
# - Non-interactive policy: --non-interactive with --keep newest|oldest|first|last
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
  --limit N              Review at most N groups (default 50)
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

get_mtime(){ stat -c '%Y' -- "$1" 2>/dev/null || echo 0; }

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

  if [ "$NONINT" -eq 1 ]; then
    for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
    return 0
  fi

  echo
  echo "─ Group  hash: $hash  (N=$count)"
  i=0
  for p in "$@"; do
    i=$((i+1))
    mark=" "; [ "$p" = "$keeper" ] && mark="*"
    printf "  %2d) %s%s\n" "$i" "$mark" "$p"
  done
  echo "    Policy: $KEEP  [* marks suggested keeper]"
  printf "    Action: (Enter=accept) [N=pick keep] [k N=set keep] [s=skip] [q=quit] > "
  read -r ans || ans="q"
  # normalize CR & whitespace-only to blank
  trimmed="$(printf "%s" "$ans" | tr -d '\r' | sed 's/^[[:space:]]*$//')"
  if [ -z "$trimmed" ]; then
    for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
    return 0
  fi

  case "$trimmed" in
    q|Q) info "Stopping early per user request."; QUIT=1 ;;
    s|S) : ;;
    k\ *)
      n="$(printf "%s" "$trimmed" | awk '{print $2}')" || n=""
      ;;
    *)
      # if plain number, treat as 'k N'
      if printf "%s" "$trimmed" | grep -Eq '^[0-9]+$'; then n="$trimmed"; else n=""; fi
      ;;
  esac

  if [ -n "${n:-}" ]; then
    # choose index
    idx="$n"
    # bounds check
    if [ "$idx" -ge 1 ] 2>/dev/null; then
      i=0; for p in "$@"; do i=$((i+1)); [ "$i" -eq "$idx" ] && keeper="$p"; done
      for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
    else
      echo "    Invalid index."
    fi
  else
    echo "    Unknown input."
  fi
}

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
# First pass: split report into per-hash group files; also capture hash list
HASHLIST="$TMPDIR/hashes.txt"; : > "$HASHLIST"
awk -v dir="$TMPDIR" '
  /^HASH[[:space:]]/ { h=$2; f=dir "/" h ".grp"; print h >> "'"$HASHLIST"'"; next }
  /^[[:space:]]*$/ { next }
  /^  / { sub(/^[ ]+/, "", $0); if (h!="") print $0 >> f; next }
' "$REPORT"

# Determine ordering
ORDER_FILE="$TMPDIR/order.txt"; : > "$ORDER_FILE"
if [ "$ORDER" = "size" ]; then
  csv="$(ls -1t "$LOGS_DIR"/duplicates-*.csv 2>/dev/null | head -n1 || true)"
  if [ -n "${csv:-}" ] && [ -f "$csv" ]; then
    info "Ranking groups by total size (largest first)…"
    awk -F',' 'NR==FNR{ok[$0]=1; next} ok[$1]{ s=($3==""?0:$3); sum[$1]+=s } END{ for (k in sum) printf "%012d %s\n", sum[k], k }' "$HASHLIST" "$csv" \
      | sort -nr > "$ORDER_FILE"
  else
    warn "No duplicates-*.csv found; falling back to count ordering."
    ORDER="count"
  fi
fi

if [ "$ORDER" = "count" ]; then
  info "Ranking groups by file count (largest first)…"
  # count lines in each .grp file
  # shellcheck disable=SC2045
  for f in $(ls "$TMPDIR"/*.grp 2>/dev/null || true); do
    h="$(basename "$f" .grp)"
    c="$(wc -l < "$f" 2>/dev/null || echo 0)"
    printf "%012d %s\n" "$c" "$h" >> "$ORDER_FILE"
  done
  sort -nr "$ORDER_FILE" -o "$ORDER_FILE"
fi

# Iterate in chosen order, up to LIMIT groups
shown=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "${line:-}" ] && continue
  h="$(printf "%s" "$line" | awk '{print $2}')"
  f="$TMPDIR/$h.grp"
  [ -s "$f" ] || continue
  # read paths for this group
  gpaths="$(cat "$f")"
  # call reviewer
  oldIFS=$IFS; IFS="$(printf '\n\t')"; set -- $gpaths; IFS=$oldIFS
  review_group "$h" "$@"
  [ "$QUIT" -eq 1 ] && break
  shown=$((shown+1))
  [ "$shown" -ge "$LIMIT" ] && break
done < "$ORDER_FILE"

echo
info "Review complete. Plan: $PLAN"
cp -f -- "$PLAN" "$VAR_DIR/latest-plan.txt" 2>/dev/null || true
next "Use menu option 6 to apply the plan."
exit 0
