#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
LOGS_DIR="${ROOT_DIR}/logs"
mkdir -p "$LOGS_DIR"

PLAN_FILE=""
FORCE=false
DELETE_METADATA=false

# Color helper
init_colors() {
  if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
    CINFO="\033[1;34m"; CWORK="\033[1;36m"; COK="\033[1;32m"; CWARN="\033[1;33m"; CERR="\033[1;31m"; CRESET="\033[0m"
  else
    CINFO=""; CWORK=""; COK=""; CWARN=""; CERR=""; CRESET=""
  fi
}
info(){ printf "%b[INFO]%b %s\n" "$CINFO" "$CRESET" "$*"; }
work(){ printf "%b[WORK]%b %s\n" "$CWORK" "$CRESET" "$*"; }
ok(){   printf "%b[OK]%b %s\n"   "$COK"   "$CRESET" "$*"; }
warn(){ printf "%b[WARN]%b %s\n" "$CWARN" "$CRESET" "$*"; }
err(){  printf "%b[ERROR]%b %s\n" "$CERR" "$CRESET" "$*"; }

init_colors

usage() {
  printf "%s\n" \
    "Usage: apply-folder-plan.sh [--plan <file>] [--force] [--delete-metadata]" \
    "  --plan FILE         Plan file (one directory per line). Defaults to latest duplicate-folders plan in logs/" \
    "  --force             Do not ask for confirmation." \
    "  --delete-metadata   Delete metadata cache dirs (@eaDir, .AppleDouble) instead of moving them."
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN_FILE="${2:-}"; shift 2;;
    --force) FORCE=true; shift;;
    --delete-metadata) DELETE_METADATA=true; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [ -z "${PLAN_FILE:-}" ]; then
  PLAN_FILE="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
fi
if [ -z "${PLAN_FILE:-}" ] || [ ! -s "$PLAN_FILE" ]; then
  err "No plan file found. Run 'Find duplicate folders' first."
  exit 2
fi

# Resolve quarantine dir from hasher.conf (local overrides default)
resolve_quarantine_dir() {
  local raw=""
  if [ -f "$ROOT_DIR/local/hasher.conf" ]; then
    raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$ROOT_DIR/local/hasher.conf" | tail -n1 || true)"
  fi
  if [ -z "$raw" ] && [ -f "$ROOT_DIR/default/hasher.conf" ]; then
    raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$ROOT_DIR/default/hasher.conf" | tail -n1 || true)"
  fi
  local val
  val="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^[\"\x27]//; s/[\"\x27]$//')"
  if [ -z "$val" ]; then
    # FIX (v1.1.9): host-aware fallback via host-detect.sh.
    # v1.2.4: default_quarantine_root() now returns an install-relative path
    # ($ROOT_DIR/quarantine-DATE) on every host, so quarantine lives beside
    # the tool. Set QUARANTINE_DIR in local/hasher.conf to override.
    if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
      . "$ROOT_DIR/lib/host-detect.sh"
      val="$(default_quarantine_root)"
    else
      val="$ROOT_DIR/quarantine-$(date +%F)"
    fi
  else
    val="${val//\$\((date +%F)\)/$(date +%F)}"
    val="${val//\$(date +%F)/$(date +%F)}"
  fi
  printf '%s\n' "$val"
}

QDIR="$(resolve_quarantine_dir)"
TS="$(date +%F-%H%M%S)"
DEST_ROOT="$QDIR/folders-$TS"
mkdir -p -- "$DEST_ROOT"

# Free space
DF_H="$(df -h "$QDIR" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
info "Quarantine: $QDIR — $DF_H"

# FIX (v1.2.3): the reviewed plans written by review-folder-plan.sh begin with
# a '#'-prefixed comment header (provenance + format notes). The previous code
# read the plan line-by-line WITHOUT skipping comments, which caused two
# failures:
#   1. the du size-estimate loop ran `du` on a non-existent "folder" named
#      "# Reviewed folder dedup plan", got an empty size, and the arithmetic
#      `$((10#${kb:-0}))` with an empty kb is a syntax error that, under
#      `set -e`, killed the whole script BEFORE any folder was moved — which
#      is why quarantine ended up empty.
#   2. the move loop would otherwise try to `mv` each comment line as a path.
# Raw plans (from find-duplicate-folders.sh) have no comments, so they worked;
# reviewed plans silently did nothing. We now normalise the plan ONCE into a
# comment-free, blank-free temp file and use it for all reads below.
PLAN_CLEAN="$(mktemp "${TMPDIR:-/tmp}/folder-plan.XXXXXX")"
trap 'rm -f "$PLAN_CLEAN"' EXIT
# strip blank lines and full-line comments (leading optional whitespace + '#')
sed -e 's/[[:space:]]*$//' "$PLAN_FILE" \
  | grep -vE '^[[:space:]]*#' \
  | grep -vE '^[[:space:]]*$' \
  > "$PLAN_CLEAN" || true

COUNT="$(wc -l < "$PLAN_CLEAN" | tr -d ' ')"
info "Plan: $PLAN_FILE  | Directories: $COUNT"

# Count metadata entries in plan
META_COUNT="$(grep -Ec '/(@eaDir|\.AppleDouble)(/|$)' "$PLAN_CLEAN" || true)"
if [ "${META_COUNT:-0}" -gt 0 ] && ! $DELETE_METADATA; then
  printf "%s" "$(printf "%b[INFO]%b " "$CINFO" "$CRESET")"
  read -r -p "Found $META_COUNT metadata cache dirs in plan (@eaDir, .AppleDouble). Delete them instead of moving? [y/N]: " reply || reply=""
  # FIX (v1.1.9): bash-3.2-compatible lowercasing
  case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
    y|yes) DELETE_METADATA=true;;
  esac
fi

# du estimate
if command -v du >/dev/null 2>&1; then
  du_total_k=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    kb="$(du -sk -- "$d" 2>/dev/null | awk 'NR==1{print $1}')"
    if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
      kb="$(du -k -- "$d" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
    fi
    # FIX (v1.2.3): guard against empty/non-numeric kb (e.g. a path that no
    # longer exists), which would make $((10#${kb:-0})) a fatal arithmetic
    # error under set -e. Default to 0 explicitly.
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    [[ "$du_total_k" =~ ^[0-9]+$ ]] || du_total_k=0
    du_total_k=$(( du_total_k + kb ))
  done < "$PLAN_CLEAN"
  du_bytes=$((du_total_k*1024))
  awk -v b="$du_bytes" 'BEGIN{ gb=b/1024/1024/1024; mb=b/1024/1024; if (gb>=1) printf("[INFO] Estimated move size (recursive): %.2f GB\n", gb); else printf("[INFO] Estimated move size (recursive): %.2f MB\n", mb); }'
fi

# Confirm
if ! $FORCE; then
  printf "%s" "$(printf "%b[INFO]%b " "$CINFO" "$CRESET")"
  printf "Proceed to %s directories into:\n  %s\n[y/N]: " "$([ "$DELETE_METADATA" = true ] && echo "move+delete" || echo "move")" "$DEST_ROOT"
  read -r reply || reply=""
  # FIX (v1.1.9): bash-3.2-compatible lowercasing
  case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *) echo "Aborted."; exit 0;;
  esac
fi

LOG_FILE="$LOGS_DIR/apply-folder-plan-$TS.log"
info "Logging to $LOG_FILE"

# v1.2.2: single persistent, high-fidelity audit log of folder actions.
# This is WRITE-ONLY from the tool's perspective — it is a human/audit record
# and is NEVER read back to drive any deletion decision (that would make a
# forgeable text file part of the trusted control path for a root-running
# bulk-move tool). The reviewer determines "already done" from disk state
# (the DEL folder's presence at its original path), not from this log.
# Format: tab-separated, one record per actioned folder:
#   ISO8601 \t ACTION \t SOURCE \t DEST \t SIZE_KB
ACTIONS_LOG="$LOGS_DIR/folder-actions.log"
_audit() {
  # $1=action $2=source $3=dest $4=size_kb
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:-}" "${4:-}" \
    >> "$ACTIONS_LOG" 2>/dev/null || true
}
# Seed a human-readable session header (also write-only)
{
  printf '# ---- apply-folder-plan session %s ----\n' "$TS"
  printf '# plan: %s\n' "$PLAN_FILE"
  printf '# dest-root: %s\n' "$DEST_ROOT"
} >> "$ACTIONS_LOG" 2>/dev/null || true

idx=0; moved=0; fail=0; removed=0
while IFS= read -r src; do
  [ -z "$src" ] && continue
  # belt-and-braces: skip any comment line even though PLAN_CLEAN is filtered
  case "$src" in \#*) continue ;; esac
  idx=$((idx+1))

  # per-folder size (best-effort, for the audit record)
  sz_kb="$(du -sk -- "$src" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$sz_kb" =~ ^[0-9]+$ ]] || sz_kb=""

  if [ "$DELETE_METADATA" = true ] && printf '%s\n' "$src" | grep -Eq '/(@eaDir|\.AppleDouble)(/|$)'; then
    work "($idx/$COUNT) delete metadata: $src"
    if rm -rf -- "$src" 2>>"$LOG_FILE"; then
      removed=$((removed+1)); ok "deleted"
      _audit "DELETE_METADATA" "$src" "" "$sz_kb"
    else
      warn "delete failed — see log"; fail=$((fail+1))
      _audit "DELETE_METADATA_FAILED" "$src" "" "$sz_kb"
    fi
    continue
  fi
  # Build a unique destination slot using the full source path, not just
  # the basename.  Multiple sibling dirs named e.g. "RAW" would otherwise
  # collide in the flat quarantine root, causing every mv after the first
  # to fail with "Directory not empty".
  #
  # Strategy: strip the leading '/' and replace every remaining '/' with
  # '__' to produce a flat, collision-free name that still encodes the
  # full original path.  e.g.
  #   /volume1/James/Photos/Switzerland/RAW  →  volume1__James__Photos__Switzerland__RAW
  #   /volume1/James/Photos/Rhinefall/RAW    →  volume1__James__Photos__Rhinefall__RAW
  slot="$(printf '%s\n' "$src" | sed 's|^/||; s|/|__|g')"
  dest="$DEST_ROOT/$slot"
  work "($idx/$COUNT) $src -> $dest"
  if mv -- "$src" "$dest" 2>>"$LOG_FILE"; then
    moved=$((moved+1)); ok "moved"
    _audit "QUARANTINED" "$src" "$dest" "$sz_kb"
  else
    warn "move failed — see log"; fail=$((fail+1))
    _audit "QUARANTINE_FAILED" "$src" "$dest" "$sz_kb"
  fi
done < "$PLAN_CLEAN"

info "Done. Moved: $moved  | Deleted metadata: $removed  | Failed: $fail  | Log: $LOG_FILE"
info "Audit record appended to: $ACTIONS_LOG"
info "Review quarantine: $DEST_ROOT"
exit 0
