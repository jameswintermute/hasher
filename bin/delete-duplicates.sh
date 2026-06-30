#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs";        mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";          mkdir -p "$VAR_DIR"
# FIX (v1.3.5 — peer-review item 5): use the SHARED quarantine resolver so file
# dedup, folder dedup, and zero-length removal all quarantine to the same place
# and honour QUARANTINE_DIR from local/hasher.conf. Previously this was a static
# undated "$ROOT_DIR/quarantine", diverging from default_quarantine_root() used
# elsewhere. Falls back to the old path only if the helper is unavailable.
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT_DIR/lib/host-detect.sh"
  QUAR_DIR="$(default_quarantine_root 2>/dev/null || true)"
fi
# allow an explicit QUARANTINE_DIR override from the environment/conf if present
[ -n "${QUARANTINE_DIR:-}" ] && QUAR_DIR="$QUARANTINE_DIR"
[ -z "${QUAR_DIR:-}" ] && QUAR_DIR="$ROOT_DIR/quarantine"
mkdir -p "$QUAR_DIR"

PLAN_FILE="${1:-}"

info()  { printf "[INFO] %s\n"  "$1" >&2; }
warn()  { printf "[WARN] %s\n"  "$1" >&2; }
error() { printf "[ERROR] %s\n" "$1" >&2; }

if [ -z "$PLAN_FILE" ]; then
  # fall back to latest review plan if not explicitly given
  PLAN_FILE="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
fi

[ -n "${PLAN_FILE:-}" ] || { warn "No review dedupe plan file found."; exit 0; }
[ -r "$PLAN_FILE" ] || { error "Plan file not readable: $PLAN_FILE"; exit 1; }

info "Using FILE delete plan: $PLAN_FILE"

# ── v1.2.0: just-in-time re-verification ─────────────────────────────────────
# Plans produced by v1.2.0+ carry the expected content hash as a third field:
#   DEL|path|expectedhash
# Before quarantining, we re-hash the candidate and confirm it still matches.
# If the file changed since the plan was built (different hash), we SKIP it —
# it is no longer safe to treat as a duplicate. This closes the stale-plan
# window between hashing (T0) and applying (T2), which can be days.
#
# Old-format plans (DEL|path, no hash) are still accepted: verification is
# simply not possible, so we fall back to the existence check and warn once.

# Resolve a hashing command (mirror hasher.sh's platform logic, minimal form)
_resolve_hash_cmd_dd() {
  if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum";
  elif command -v shasum >/dev/null 2>&1; then echo "shasum -a 256";
  else echo ""; fi
}
HASH_CMD_DD="$(_resolve_hash_cmd_dd)"

# Split a "DEL|path|hash" or "DEL|path" line into path + expected hash.
# Uses the LAST '|' as the hash separator only when the tail looks like a
# 64-hex sha256; otherwise treats the whole remainder as the path (so paths
# containing '|' still work in old-format plans).
_split_del_line() {
  # sets globals: DEL_PATH, DEL_HASH (DEL_HASH empty if none)
  local body="${1#DEL|}"
  local tail="${body##*|}"
  if [ "${#tail}" -eq 64 ] && printf '%s' "$tail" | grep -qiE '^[0-9a-f]{64}$'; then
    DEL_PATH="${body%|*}"
    DEL_HASH="$tail"
  else
    DEL_PATH="$body"
    DEL_HASH=""
  fi
}

# Count DEL entries
TOTAL_DEL=$(grep -c '^DEL|' "$PLAN_FILE" 2>/dev/null || true)
if [ "$TOTAL_DEL" -eq 0 ]; then
  warn "No DEL entries found in plan (nothing to do)."
  exit 0
fi

# Detect whether this plan carries hashes (sample the first DEL line)
PLAN_HAS_HASHES=0
_first_del="$(grep -m1 '^DEL|' "$PLAN_FILE" 2>/dev/null || true)"
if [ -n "$_first_del" ]; then
  _split_del_line "$_first_del"
  [ -n "$DEL_HASH" ] && PLAN_HAS_HASHES=1
fi

if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
  if [ -n "$HASH_CMD_DD" ]; then
    info "Plan carries content hashes — candidates will be re-verified before quarantine."
  else
    warn "Plan carries hashes but no hash tool (sha256sum/shasum) found — cannot re-verify."
    PLAN_HAS_HASHES=0
  fi
else
  warn "Plan has no content hashes (old format) — falling back to existence check only."
  warn "Regenerate the plan with auto-dedup v1.2.0+ to enable re-verification."
fi

# Pass 1: count existing vs missing
existing=0
missing=0

# shellcheck disable=SC2162
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DEL\|*)
      _split_del_line "$line"
      [ -z "$DEL_PATH" ] && continue
      if [ -e "$DEL_PATH" ]; then
        existing=$((existing+1))
      else
        missing=$((missing+1))
      fi
      ;;
  esac
done <"$PLAN_FILE"

if [ "$existing" -eq 0 ]; then
  warn "No existing files in plan (nothing to do)."
  exit 0
fi

info "Plan summary: $TOTAL_DEL DEL entries; $existing currently exist, $missing already missing."

# Quarantine layout: mirror full path under $QUAR_DIR
# e.g. /volume1/foo/bar.jpg -> $QUAR_DIR/volume1/foo/bar.jpg
moves_ok=0
moves_fail=0
moves_skipped_changed=0

# shellcheck disable=SC2162
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DEL\|*)
      _split_del_line "$line"
      [ -z "$DEL_PATH" ] && continue
      [ -e "$DEL_PATH" ] || continue

      # v1.2.0: re-verify content hash before quarantining
      if [ "$PLAN_HAS_HASHES" -eq 1 ] && [ -n "$DEL_HASH" ]; then
        actual="$($HASH_CMD_DD -- "$DEL_PATH" 2>/dev/null | awk '{print $1}')"
        if [ -z "$actual" ]; then
          warn "Could not re-hash (skipping for safety): $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        if [ "$actual" != "$DEL_HASH" ]; then
          warn "Content changed since plan was made — SKIPPING: $DEL_PATH"
          warn "  expected $DEL_HASH"
          warn "  actual   $actual"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
      fi

      # Build destination path
      case "$DEL_PATH" in
        /*) dest="$QUAR_DIR$DEL_PATH" ;;
        *)  dest="$QUAR_DIR/$DEL_PATH" ;;
      esac
      dest_dir=$(dirname "$dest")
      mkdir -p "$dest_dir"

      # FIX (v1.3.5 — peer-review item 5): `mv -n` can return success while
      # silently NOT moving when the destination already exists, which would be
      # counted as a successful quarantine while the duplicate remained live at
      # its source. Detect collisions explicitly: if the destination already
      # exists, disambiguate with a numeric suffix rather than skipping or
      # clobbering, and verify the source is actually gone after the move.
      if [ -e "$dest" ]; then
        n=1
        while [ -e "${dest}.dup${n}" ]; do n=$((n+1)); done
        warn "Quarantine target already exists; using ${dest}.dup${n}"
        dest="${dest}.dup${n}"
      fi
      if mv -- "$DEL_PATH" "$dest" 2>/dev/null && [ ! -e "$DEL_PATH" ]; then
        moves_ok=$((moves_ok+1))
      else
        warn "Failed to move (source still present): $DEL_PATH"
        moves_fail=$((moves_fail+1))
      fi
      ;;
  esac
done <"$PLAN_FILE"

if [ "$moves_skipped_changed" -gt 0 ]; then
  warn "$moves_skipped_changed file(s) skipped because their content no longer matched the plan."
  warn "These files changed between hashing and now — re-run hashing + dedup to re-evaluate them."
fi
info "Move complete: $moves_ok files moved to quarantine ($QUAR_DIR); $moves_fail failures."
exit 0
