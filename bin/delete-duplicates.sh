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
# FIX (v1.3.6 — cross-check concern 3): use the SHARED resolve_quarantine_dir()
# from lib/host-detect.sh, which reads QUARANTINE_DIR from local/hasher.conf
# (then default/hasher.conf, then env, then the install-relative default). The
# v1.3.5 version only honoured an environment variable, not the conf setting —
# so a user's local/hasher.conf QUARANTINE_DIR was silently ignored.
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT_DIR/lib/host-detect.sh"
  QUAR_DIR="$(resolve_quarantine_dir 2>/dev/null || true)"
fi
[ -z "${QUAR_DIR:-}" ] && QUAR_DIR="$ROOT_DIR/quarantine"
mkdir -p "$QUAR_DIR"

PLAN_FILE=""
ALLOW_UNVERIFIED_PLAN=0

# v1.3.16 (peer-review finding #5): parse args explicitly. Previously $1 was
# taken as the plan path unconditionally; we now accept --plan/-p and add
# --allow-unverified-plan to explicitly opt in to applying old-format plans
# that carry no per-entry hashes (which cannot be re-verified).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan|-p) PLAN_FILE="${2:-}"; shift 2 ;;
    --allow-unverified-plan) ALLOW_UNVERIFIED_PLAN=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--plan PATH] [--allow-unverified-plan]

Applies a review-dedupe plan by quarantining the DEL entries.

By default, plans MUST carry per-entry SHA-256 hashes so each file is
re-verified immediately before it is moved (protects against stale-plan
drift). Old-format plans without hashes are refused; pass
--allow-unverified-plan (and confirm) to apply them regardless.
EOF
      exit 0 ;;
    -*) error "Unknown option: $1"; exit 2 ;;
    *)  # positional: plan path (back-compat with the old "$1" behaviour)
        [ -z "$PLAN_FILE" ] && PLAN_FILE="$1"
        shift ;;
  esac
done

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
# v1.3.17: legacy plans (DEL|path, no per-entry hash) and mixed plans are now
# refused by default. Legacy plans require --allow-unverified-plan and a
# typed confirmation. Mixed plans (some entries hashed, some not) are always
# refused. See the pre-flight validation below for the exact policy.

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

# v1.3.17 (peer-review recheck finding #2): CRITICAL — validate EVERY DEL
# line up front, not just the first. Previously a mixed plan (some entries
# with hashes, some without) was classified as "hashed" from a single sample
# and the unhashed entries were then moved with no verification. Second
# fail-open: a hashed plan with no available hash tool used to silently
# downgrade to "unhashed" and continue on the verified path. Both are gone.
#
# The plan is now classified into exactly one bucket after scanning every
# DEL entry:
#   - ALL entries carry a valid 64-hex hash        → PLAN_HAS_HASHES=1
#   - NONE of the entries carry a hash             → PLAN_HAS_HASHES=0 (legacy)
#   - MIXED, or malformed hash on any entry        → REFUSE outright
_mixed_count=0
_unhashed_count=0
_hashed_count=0
while IFS= read -r _line; do
  [ -z "$_line" ] && continue
  _split_del_line "$_line"
  if [ -n "$DEL_HASH" ]; then
    _hashed_count=$((_hashed_count + 1))
  else
    _unhashed_count=$((_unhashed_count + 1))
  fi
done < <(grep '^DEL|' "$PLAN_FILE" 2>/dev/null || true)

if [ "$_hashed_count" -gt 0 ] && [ "$_unhashed_count" -gt 0 ]; then
  _mixed_count=$_hashed_count
  error "Plan is MIXED: $_hashed_count DEL entries carry a hash, $_unhashed_count do not."
  error "Refusing to apply — a mixed plan cannot be safely classified as verified."
  error "Regenerate the plan against a current hash manifest and try again."
  exit 2
fi

PLAN_HAS_HASHES=0
[ "$_hashed_count" -gt 0 ] && [ "$_unhashed_count" -eq 0 ] && PLAN_HAS_HASHES=1

if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
  if [ -n "$HASH_CMD_DD" ]; then
    info "Plan carries content hashes — all $_hashed_count candidates will be re-verified before quarantine."
  else
    # v1.3.17 (finding #2): fail closed. Do NOT silently downgrade a hashed
    # plan to unverified just because the hash tool is missing — the whole
    # point of the hashes is re-verification. Exit with a clear message.
    error "Plan carries content hashes but no hash tool is available."
    error "Install sha256sum (coreutils) or shasum (Perl), or run this on a"
    error "host that has one. Refusing to apply without re-verification."
    exit 2
  fi
else
  # No hashes at all → legacy plan path. Still refuse unless the user opts in.
  if [ "${ALLOW_UNVERIFIED_PLAN:-0}" -ne 1 ]; then
    error "Plan has NO per-entry content hashes (old format): $PLAN_FILE"
    error "This tool cannot re-verify entries before quarantining them, which"
    error "means a stale plan could move a file that is no longer duplicate."
    error ""
    error "Options:"
    error "  1) Regenerate the plan against a current hash manifest (recommended):"
    error "       bin/find-duplicates.sh   →   review/auto-dedup   →   apply"
    error "  2) Override deliberately (still uses quarantine — recoverable):"
    error "       $(basename "$0") --plan \"$PLAN_FILE\" --allow-unverified-plan"
    exit 2
  fi
  warn "Applying an UNVERIFIED plan (no per-entry hashes) — proceeding on the"
  warn "existence check only. Quarantine is recoverable, but this bypasses the"
  warn "stale-plan safety check."
  printf "Type 'apply-unverified' to confirm: "
  read -r _confirm || _confirm=""
  if [ "$_confirm" != "apply-unverified" ]; then
    info "Aborted (confirmation not given)."
    exit 0
  fi
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
      if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
        # v1.3.17 (finding #2 belt-and-braces): if the pre-flight classified
        # the plan as hashed but we somehow reach here with an empty DEL_HASH,
        # that is a pre-flight bug or a race — safety-skip rather than move
        # without verification.
        if [ -z "$DEL_HASH" ]; then
          warn "Missing per-entry hash on a verified plan — SKIPPING for safety: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
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
# v1.3.23 (peer-review recheck finding #4): return non-zero when any
# move failed. Files "skipped because content changed" are a safety
# outcome, not a failure — they exit 0 with a warning above.
if [ "${moves_fail:-0}" -gt 0 ]; then
  exit 1
fi
exit 0
