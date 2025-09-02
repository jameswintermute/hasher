#!/bin/sh
# review-batch.sh — slice duplicates report and open interactive reviewer
# Usage:
#   bin/review-batch.sh [--skip N] [--take N] [--report FILE] [--keep newest|oldest|largest]
# Notes:
#   - Auto-detects report if not given (prefers logs/du-*/duplicates.txt, else logs/*-duplicate-hashes.txt).
#   - Writes sliced batch to logs/review-batch-<from>-<to>.txt and calls bin/review-duplicates.sh.

set -eu

ROOT="$(cd -- "$(dirname "$0")/.." && pwd -P)"
LOGS="$ROOT/logs"

SKIP=0
TAKE=100
REPORT=""
KEEP="newest"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip)   SKIP="${2:-0}"; shift ;;
    --take)   TAKE="${2:-100}"; shift ;;
    --report) REPORT="${2:-}"; shift ;;
    --keep)   KEEP="${2:-newest}"; shift ;;
    --help|-h)
      echo "Usage: $0 [--skip N] [--take N] [--report FILE] [--keep newest|oldest|largest]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift || true
done

# Auto-detect report if not provided
if [ -z "${REPORT:-}" ]; then
  REPORT="$(ls -1t "$LOGS"/du-*/duplicates.txt 2>/dev/null | head -n1 || true)"
  if [ -z "$REPORT" ]; then
    REPORT="$(ls -1t "$LOGS"/*-duplicate-hashes.txt 2>/dev/null | head -n1 || true)"
  fi
fi
[ -n "$REPORT" ] && [ -r "$REPORT" ] || { echo "No readable report found. Run find-duplicates first." >&2; exit 1; }

FROM=$(( SKIP + 1 ))
TO=$(( SKIP + TAKE ))
OUT="$LOGS/review-batch-${FROM}-${TO}.txt"

# Slice by groups starting with 'HASH '
awk -v skip="$SKIP" -v take="$TAKE" '
  /^HASH /{g++}
  (g>skip && g<=skip+take){ print }
' "$REPORT" > "$OUT"

echo "Prepared batch: $OUT"
if [ ! -s "$OUT" ]; then
  echo "No groups in this range (skip=$SKIP, take=$TAKE). Nothing to review." >&2
  exit 0
fi

CMD="$ROOT/bin/review-duplicates.sh --from-report \"$OUT\" --keep \"$KEEP\""
echo "Command: $CMD"
# shellcheck disable=SC2086
exec $ROOT/bin/review-duplicates.sh --from-report "$OUT" --keep "$KEEP"
