#!/bin/sh
# apply-file-plan.sh — Move duplicate files listed in a plan into a dated quarantine folder.
# Plan format: one absolute file path per line; blank lines and lines starting with '#' are ignored.
# Safe on BusyBox NAS (Synology). Does NOT permanently delete; only moves.
set -eu
IFS="$(printf '\n\t')"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs"; mkdir -p "$LOGS_DIR"
DEFAULT_QUAR="$ROOT_DIR/quarantine-$(date +'%Y-%m-%d')"

# Colors only if stdout is a TTY
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  CINFO="$(printf '\033[0;34m')"; COK="$(printf '\033[0;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[0;31m')"; CRESET="$(printf '\033[0m')"
else
  CINFO=""; COK=""; CWARN=""; CERR=""; CRESET=""
fi
info(){ printf "%s[INFO]%s %s\n" "$CINFO" "$CRESET" "$*"; }
ok(){   printf "%s[OK]%s %s\n"   "$COK"   "$CRESET" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR"  "$CRESET" "$*"; }

usage(){
  cat <<'EOF'
Usage: apply-file-plan.sh --plan FILE [--quarantine DIR] [--force]
  --plan FILE        Path to review-dedupe-plan-*.txt produced by review-duplicates.sh
  --quarantine DIR   Destination root (default: ../quarantine-YYYY-MM-DD)
  --force            Do not prompt for confirmation
Notes:
  - Files are moved to: <QUARANTINE>/<absolute-path>, creating parent directories.
  - If a destination exists, a ".dupeN" suffix is appended.
EOF
}

PLAN=""; QUAR="$DEFAULT_QUAR"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="${2:-}"; shift 2 ;;
    --quarantine) QUAR="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[ -n "$PLAN" ] || { err "Missing --plan"; usage; exit 2; }
[ -f "$PLAN" ] || { err "Plan not found: $PLAN"; exit 2; }

# Resolve CSV for size lookups (optional)
CSV="$(ls -1t "$LOGS_DIR"/duplicates-*.csv 2>/dev/null | head -n1 || true)"

# Quick counts + estimated bytes
FILES=0; BYTES=0
while IFS= read -r p || [ -n "$p" ]; do
  case "$p" in \#*|"") continue ;; esac
  [ -f "$p" ] || continue
  s="$(stat -c '%s' -- "$p" 2>/dev/null || echo 0)"
  BYTES=$((BYTES + s))
  FILES=$((FILES + 1))
done < "$PLAN"

[ "$FILES" -gt 0 ] || { warn "No existing files in plan (nothing to do)."; exit 0; }

# Filesystem + free space
MNT="/volume1"
FREE="$(df -h "$MNT" 2>/dev/null | awk 'NR==2{print $4" free on "$1" ("$6")"}' || echo "")"
[ -n "$FREE" ] && info "Quarantine: $QUAR — $FREE" || info "Quarantine: $QUAR"

# Human readable size
human(){ b="$1"; awk -v b="$b" 'BEGIN{ if(b<1024) printf "%d B",b; else if(b<1048576) printf "%.1f KiB",b/1024; else if(b<1073741824) printf "%.1f MiB",b/1048576; else printf "%.2f GiB",b/1073741824 }'; }

info "Plan: $PLAN  | Files: $FILES  | Est size: $(human "$BYTES")"

if [ "$FORCE" -ne 1 ]; then
  printf "Proceed to move files to quarantine? [y/N]: "
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) : ;; *) warn "Aborted by user."; exit 1 ;; esac
fi

LOG_APPLY="$LOGS_DIR/apply-file-plan-$(date +'%Y-%m-%d-%H%M%S').log"
mkdir -p "$QUAR" 2>/dev/null || mkdir -p "$QUAR"
MOVED=0; MOVED_BYTES=0; FAILED=0

# Spinner (simple)
spin='-\|/'; i=0
progress(){
  i=$(( (i + 1) % 4 ))
  printf "\r[%c] Moved: %d/%d ( %s )" "$(printf "%s" "$spin" | cut -c $((i+1)) )" "$MOVED" "$FILES" "$(human "$MOVED_BYTES")"
}

while IFS= read -r p || [ -n "$p" ]; do
  case "$p" in \#*|"") continue ;; esac
  if [ ! -f "$p" ]; then
    printf "# MISSING\t%s\n" "$p" >> "$LOG_APPLY"
    continue
  fi
  s="$(stat -c '%s' -- "$p" 2>/dev/null || echo 0)"
  dest="$QUAR$p"
  ddir="$(dirname "$dest")"
  mkdir -p "$ddir" 2>/dev/null || true
  base="$(basename "$dest")"; name="$base"; n=1
  while [ -e "$ddir/$name" ]; do
    name="$base.dupe$n"; n=$((n+1))
  done
  final="$ddir/$name"
  if mv -f -- "$p" "$final" 2>/dev/null || mv -f "$p" "$final"; then
    MOVED=$((MOVED + 1)); MOVED_BYTES=$((MOVED_BYTES + s))
    printf "%s\t%s\n" "$p" "$final" >> "$LOG_APPLY"
  else
    FAILED=$((FAILED + 1))
    printf "# FAIL\t%s\n" "$p" >> "$LOG_APPLY"
  fi
  progress
done < "$PLAN"

printf "\n"  # end spinner line
ok "Done. Moved: $MOVED / $FILES files  |  Reclaim staged: $(human "$MOVED_BYTES")"
info "Log: $LOG_APPLY"
exit 0
