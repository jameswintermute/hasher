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

# Hotfix: persist every apply/preflight message so plan failures can be diagnosed
# after the terminal session has closed. The log is created before argument
# parsing so even invalid-option errors are retained.
APPLY_TAG="$(date +'%F-%H%M%S')-$$"
APPLY_LOG="$LOGS_DIR/delete-duplicates-apply-$APPLY_TAG.log"
: > "$APPLY_LOG" 2>/dev/null || APPLY_LOG="${TMPDIR:-/tmp}/delete-duplicates-apply-$APPLY_TAG.log"
: > "$APPLY_LOG" 2>/dev/null || true
_emit() {
  _level="$1"; shift
  printf '[%s] %s\n' "$_level" "$*" >&2
  [ -n "${APPLY_LOG:-}" ] && printf '[%s] %s\n' "$_level" "$*" >> "$APPLY_LOG" 2>/dev/null || true
}
info()  { _emit INFO  "$*"; }
warn()  { _emit WARN  "$*"; }
error() { _emit ERROR "$*"; }

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

if [ -z "$PLAN_FILE" ]; then
  # fall back to latest review plan if not explicitly given
  PLAN_FILE="$(ls -1t "$LOGS_DIR"/review-dedupe-plan-*.txt 2>/dev/null | head -n1 || true)"
fi

[ -n "${PLAN_FILE:-}" ] || { warn "No review dedupe plan file found."; exit 0; }
[ -r "$PLAN_FILE" ] || { error "Plan file not readable: $PLAN_FILE"; exit 1; }

info "Using FILE delete plan: $PLAN_FILE"
info "Detailed apply log: $APPLY_LOG"

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

# v1.3.28 plans include the group hash on KEEP entries as well. Older hashed
# plans used KEEP|path only; those are supported by associating the pending
# keeper with the next DEL hash in the grouped plan order.
_split_keep_line() {
  local body="${1#KEEP|}"
  local tail="${body##*|}"
  if [ "${#tail}" -eq 64 ] && printf '%s' "$tail" | grep -qiE '^[0-9a-f]{64}$'; then
    KEEP_PATH="${body%|*}"
    KEEP_HASH="$tail"
  else
    KEEP_PATH="$body"
    KEEP_HASH=""
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

# v1.3.28 hotfix: build the hash -> keeper map independently of plan line
# order. Modern plans carry the hash on BOTH KEEP and DEL entries, so the hash
# itself is the group identity. The previous implementation held a KEEP as
# "pending" until a later DEL was seen; a valid reviewed group written as
# DEL|path|hash followed by KEEP|path|hash therefore left the keeper pending
# and falsely rejected the next group's KEEP as "multiple KEEP entries".
#
# Older hashed plans with KEEP|path (no hash) retain the old grouped-order
# fallback. All modern KEEP|path|hash entries are mapped immediately and may
# appear before, between, or after their DEL entries.
KEEPER_MAP=""
DEL_GROUPS=""
_cleanup_keeper_map() {
  [ -n "${KEEPER_MAP:-}" ] && rm -f -- "$KEEPER_MAP" 2>/dev/null || true
  [ -n "${DEL_GROUPS:-}" ] && rm -f -- "$DEL_GROUPS" 2>/dev/null || true
}
trap _cleanup_keeper_map EXIT
if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
  KEEPER_MAP="$(mktemp "${TMPDIR:-/tmp}/hasher-keepers.XXXXXX")" || { error "Could not create keeper map."; exit 1; }
  DEL_GROUPS="$(mktemp "${TMPDIR:-/tmp}/hasher-delgroups.XXXXXX")" || { error "Could not create DEL-group map."; exit 1; }
  : > "$KEEPER_MAP"
  : > "$DEL_GROUPS"

  _pending_legacy_keep=""
  _pending_legacy_line=""
  _line_no=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line_no=$((_line_no + 1))
    case "$_line" in
      KEEP\|*)
        _split_keep_line "$_line"
        if [ -z "$KEEP_PATH" ]; then
          error "Malformed KEEP entry at plan line $_line_no."
          error "  entry: $_line"
          exit 2
        fi

        if [ -n "$KEEP_HASH" ]; then
          _existing="$(awk -F '\t' -v h="$KEEP_HASH" '$1==h {print; exit}' "$KEEPER_MAP")"
          if [ -n "$_existing" ]; then
            _old_path="$(printf '%s\n' "$_existing" | awk -F '\t' '{print $2}')"
            _old_line="$(printf '%s\n' "$_existing" | awk -F '\t' '{print $3}')"
            error "Hash group $KEEP_HASH contains more than one KEEP entry."
            error "  first KEEP: line $_old_line: $_old_path"
            error "  next KEEP:  line $_line_no: $KEEP_PATH"
            error "Refusing ambiguous plan: $PLAN_FILE"
            exit 2
          fi
          printf '%s\t%s\t%s\n' "$KEEP_HASH" "$KEEP_PATH" "$_line_no" >> "$KEEPER_MAP"
        else
          if [ -n "$_pending_legacy_keep" ]; then
            error "Two legacy KEEP entries appeared without an intervening hashed DEL group."
            error "  first KEEP: line $_pending_legacy_line: $_pending_legacy_keep"
            error "  next KEEP:  line $_line_no: $KEEP_PATH"
            exit 2
          fi
          _pending_legacy_keep="$KEEP_PATH"
          _pending_legacy_line="$_line_no"
        fi
        ;;

      DEL\|*)
        _split_del_line "$_line"
        [ -n "$DEL_HASH" ] || continue

        if ! awk -F '\t' -v h="$DEL_HASH" '$1==h {found=1} END{exit !found}' "$DEL_GROUPS"; then
          printf '%s\t%s\t%s\n' "$DEL_HASH" "$_line_no" "$DEL_PATH" >> "$DEL_GROUPS"
        fi

        if [ -n "$_pending_legacy_keep" ]; then
          _existing="$(awk -F '\t' -v h="$DEL_HASH" '$1==h {print; exit}' "$KEEPER_MAP")"
          if [ -n "$_existing" ]; then
            error "Hash group $DEL_HASH has both a hashed KEEP and a legacy KEEP."
            error "  legacy KEEP: line $_pending_legacy_line: $_pending_legacy_keep"
            exit 2
          fi
          printf '%s\t%s\t%s\n' "$DEL_HASH" "$_pending_legacy_keep" "$_pending_legacy_line" >> "$KEEPER_MAP"
          _pending_legacy_keep=""
          _pending_legacy_line=""
        fi
        ;;
    esac
  done < "$PLAN_FILE"

  if [ -n "$_pending_legacy_keep" ]; then
    error "Legacy KEEP entry at line $_pending_legacy_line has no following hashed DEL group."
    error "  keeper: $_pending_legacy_keep"
    exit 2
  fi

  _group_count=0
  _missing_keeper_count=0
  while IFS=$'\t' read -r _group_hash _first_del_line _first_del_path || [ -n "${_group_hash:-}" ]; do
    [ -n "${_group_hash:-}" ] || continue
    _group_count=$((_group_count + 1))
    _keeper_record="$(awk -F '\t' -v h="$_group_hash" '$1==h {print; exit}' "$KEEPER_MAP")"
    if [ -z "$_keeper_record" ]; then
      _missing_keeper_count=$((_missing_keeper_count + 1))
      error "Hash group $_group_hash has DEL entries but no KEEP entry."
      error "  first DEL: line $_first_del_line: $_first_del_path"
    fi
  done < "$DEL_GROUPS"

  if [ "$_missing_keeper_count" -gt 0 ]; then
    error "Plan validation failed: $_missing_keeper_count group(s) have no unique keeper."
    error "Regenerate or re-review the plan before applying it."
    exit 2
  fi

  _keeper_count="$(awk 'END{print NR+0}' "$KEEPER_MAP")"
  info "Plan structure valid: $_group_count hash groups, $_keeper_count unique KEEP entries, $TOTAL_DEL DEL candidates."
fi

keeper_for_hash() {
  [ -n "${KEEPER_MAP:-}" ] && [ -s "$KEEPER_MAP" ] || return 0
  awk -F '\t' -v h="$1" '$1==h {print $2; exit}' "$KEEPER_MAP"
}

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

      if [ -L "$DEL_PATH" ]; then
        warn "Planned path is now a symlink — SKIPPING for safety: $DEL_PATH"
        moves_fail=$((moves_fail+1))
        continue
      fi

      if command -v canonical_existing_path >/dev/null 2>&1; then
        DEL_REAL="$(canonical_existing_path "$DEL_PATH" 2>/dev/null || true)"
      else
        DEL_REAL="$DEL_PATH"
      fi
      if [ -z "$DEL_REAL" ] || [ ! -f "$DEL_REAL" ]; then
        warn "Could not canonicalise planned file — SKIPPING for safety: $DEL_PATH"
        moves_fail=$((moves_fail+1))
        continue
      fi

      # v1.3.28: verify that the planned keeper still exists and still has
      # the group's expected content before moving any DEL entry. A surviving
      # DEL is not expendable if its keeper disappeared or changed.
      if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
        GROUP_KEEP="$(keeper_for_hash "$DEL_HASH" 2>/dev/null || true)"
        if [ -z "$GROUP_KEEP" ]; then
          warn "No unique KEEP mapping for hash $DEL_HASH — SKIPPING group candidate: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        if [ "$GROUP_KEEP" = "$DEL_PATH" ] || [ -L "$GROUP_KEEP" ]; then
          warn "Keeper is invalid or is the DEL path — SKIPPING: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        if command -v canonical_existing_path >/dev/null 2>&1; then
          KEEP_REAL="$(canonical_existing_path "$GROUP_KEEP" 2>/dev/null || true)"
        else
          KEEP_REAL="$GROUP_KEEP"
        fi
        if [ -z "$KEEP_REAL" ] || [ ! -f "$KEEP_REAL" ]; then
          warn "Keeper is missing or not a regular file — SKIPPING: $DEL_PATH"
          warn "  keeper: $GROUP_KEEP"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        keeper_actual="$($HASH_CMD_DD -- "$KEEP_REAL" 2>/dev/null | awk '{print $1}')"
        if [ -z "$keeper_actual" ] || [ "$keeper_actual" != "$DEL_HASH" ]; then
          warn "Keeper changed or could not be re-hashed — SKIPPING: $DEL_PATH"
          warn "  keeper:   $GROUP_KEEP"
          warn "  expected: $DEL_HASH"
          [ -n "$keeper_actual" ] && warn "  actual:   $keeper_actual"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi

        # v1.2.0: re-verify DEL content hash before quarantining
        # v1.3.17 (finding #2 belt-and-braces): if the pre-flight classified
        # the plan as hashed but we somehow reach here with an empty DEL_HASH,
        # that is a pre-flight bug or a race — safety-skip rather than move
        # without verification.
        if [ -z "$DEL_HASH" ]; then
          warn "Missing per-entry hash on a verified plan — SKIPPING for safety: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        actual="$($HASH_CMD_DD -- "$DEL_REAL" 2>/dev/null | awk '{print $1}')"
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

      # Build and validate a hierarchy-preserving destination. The source path
      # is canonicalised first so `..` components cannot escape QUAR_DIR.
      if command -v safe_quarantine_destination >/dev/null 2>&1; then
        dest="$(safe_quarantine_destination "$QUAR_DIR" "$DEL_REAL" 2>/dev/null || true)"
      else
        case "$DEL_REAL" in
          /*) dest="$QUAR_DIR$DEL_REAL" ;;
          *)  dest="$QUAR_DIR/$DEL_REAL" ;;
        esac
        dest_dir=$(dirname "$dest")
        mkdir -p "$dest_dir"
      fi
      if [ -z "$dest" ]; then
        warn "Quarantine containment check failed — refusing to move: $DEL_PATH"
        moves_fail=$((moves_fail+1))
        continue
      fi

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
      if mv -- "$DEL_REAL" "$dest" 2>/dev/null && [ ! -e "$DEL_REAL" ]; then
        moves_ok=$((moves_ok+1))
      else
        warn "Failed to move (source still present): $DEL_PATH"
        moves_fail=$((moves_fail+1))
      fi
      ;;
  esac
done <"$PLAN_FILE"

if [ "$moves_skipped_changed" -gt 0 ]; then
  warn "$moves_skipped_changed file(s) skipped because the DEL or its keeper could not be safely re-verified."
  warn "Re-run hashing and duplicate discovery to rebuild a current plan."
fi
info "Move complete: $moves_ok files moved to quarantine ($QUAR_DIR); $moves_fail failures; $moves_skipped_changed safety skips."
if [ "${moves_fail:-0}" -gt 0 ]; then
  exit 1
fi
# v1.3.28: safety refusal is distinct from complete success.
if [ "${moves_skipped_changed:-0}" -gt 0 ]; then
  exit 4
fi
exit 0
