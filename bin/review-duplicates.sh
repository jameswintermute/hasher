#!/bin/sh
# review-duplicates.sh — minimal POSIX/BusyBox interactive reviewer
# Works with logs/*-duplicate-hashes.txt. No bash arrays; newline-safe.
set -eu
# Keep IFS off spaces to preserve file paths with spaces:
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
EOF
}

REPORT=""; LIMIT=50; KEEP="newest"; NONINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) REPORT="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-50}"; shift 2 ;;
    --keep) KEEP="${2:-newest}"; shift 2 ;;
    --non-interactive) NONINT=1; shift ;;
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

  # default keeper
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
  printf "    Action: (Enter=accept) [k N=set keep] [s=skip] [q=quit] > "
  read -r ans || ans="q"
  case "$ans" in
    "" ) for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done ;;
    q|Q) info "Stopping early per user request."; QUIT=1 ;;
    s|S) : ;;
    k* ) n="$(printf "%s" "$ans" | awk '{print $2}')" || n=""
         if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then
           i=0; for p in "$@"; do i=$((i+1)); [ "$i" -eq "$n" ] && keeper="$p"; done
           for p in "$@"; do [ "$p" = "$keeper" ] && continue; printf "%s\n" "$p" >> "$PLAN"; done
         else echo "    Invalid index."; fi ;;
    * ) echo "    Unknown input." ;;
  esac
}

# Build a bounded stream of groups with a single awk pass (no '--' to stay BusyBox-safe)
STREAM="$LOGS_DIR/.review-stream-$$.txt"
trap 'rm -f "$STREAM"' EXIT

awk -v limit="$LIMIT" '
  BEGIN{g=0; n=0}
  /^HASH[[:space:]]/ {
    if (g==limit) exit
    if (n>0) print ""
    print
    g++; n=0
    next
  }
  /^[[:space:]]*$/ { next }
  /^  / { sub(/^[ ]+/, "", $0); print; n++; next }
' "$REPORT" > "$STREAM" || { err "Failed to parse report."; exit 1; }

# Iterate the stream in the current shell (no subshell), preserving QUIT flag
ghash=""; gpaths=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ -z "${line:-}" ]; then
    if [ -n "${ghash:-}" ]; then
      oldIFS=$IFS; IFS="$(printf '\n\t')"
      # shellcheck disable=SC2086
      set -- $gpaths
      IFS=$oldIFS
      review_group "$ghash" "$@"
      [ "$QUIT" -eq 1 ] && break
    fi
    ghash=""; gpaths=""; continue
  fi
  case "$line" in
    HASH\ *)
      if [ -n "${ghash:-}" ]; then
        oldIFS=$IFS; IFS="$(printf '\n\t')"; set -- $gpaths; IFS=$oldIFS
        review_group "$ghash" "$@"; [ "$QUIT" -eq 1 ] && break
        gpaths=""
      fi
      ghash="$(printf "%s" "$line" | awk '{print $2}')"
      ;;
    *)
      if [ -z "$gpaths" ]; then gpaths="$(printf "%s" "$line")"; else gpaths="$gpaths
$(printf "%s" "$line")"; fi
      ;;
  esac
done < "$STREAM"

echo
info "Review complete. Plan: $PLAN"
cp -f -- "$PLAN" "$VAR_DIR/latest-plan.txt" 2>/dev/null || true
next "Use menu option 6 to apply the plan."
exit 0
