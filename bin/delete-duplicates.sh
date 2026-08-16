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
# v1.4.5: source the shared logging module for its progress helpers only.
# It is loaded BEFORE the local info/warn/error definitions below, so those
# continue to win — this script deliberately tees every message into the
# apply log, which the shared versions do not do. Only log_progress_bar,
# log_progress_done and log_htime are actually taken from it.
if [ -r "$ROOT_DIR/lib/log.sh" ]; then
  # shellcheck source=../lib/log.sh
  . "$ROOT_DIR/lib/log.sh" 2>/dev/null || true
fi
# Fallbacks so the script runs standalone if lib/log.sh is missing.
command -v log_progress_bar  >/dev/null 2>&1 || log_progress_bar()  { :; }
command -v log_progress_done >/dev/null 2>&1 || log_progress_done() { :; }

_emit() {
  _level="$1"; shift
  # v1.4.5: the progress bar redraws in place on stderr, so any message
  # emitted mid-loop would land on top of it and leave a garbled line.
  # Clearing first is a no-op when no bar is active.
  log_progress_done
  # v1.4.13: colour the tag to match every other tool in this project.
  # This script has printed plain, uncoloured [INFO]/[WARN] text since it
  # was written — reported live from a NAS session, where these lines sit
  # directly after import-check.sh's own coloured [INFO] output and the
  # mismatch is visually jarring mid-sequence. lib/log.sh is already
  # sourced above (for the progress-bar helpers); LOG_C_INFO/LOG_C_WARN/
  # LOG_C_RST are reused here rather than defining a second set of colour
  # variables. The file-tee below stays plain text — colour codes have no
  # place in a saved log meant to be read back later.
  local _c=""
  case "$_level" in
    INFO)  _c="${LOG_C_INFO:-}" ;;
    WARN)  _c="${LOG_C_WARN:-}" ;;
    ERROR) _c="${LOG_C_ERR:-}"  ;;
  esac
  printf '%s[%s]%s %s\n' "$_c" "$_level" "${_c:+${LOG_C_RST:-}}" "$*" >&2
  [ -n "${APPLY_LOG:-}" ] && printf '[%s] %s\n' "$_level" "$*" >> "$APPLY_LOG" 2>/dev/null || true
}
info()  { _emit INFO  "$*"; }
warn()  { _emit WARN  "$*"; }
error() { _emit ERROR "$*"; }

# v1.4.18: for the MOVE loop's routine, per-candidate safety skips.
# Reported live from a NAS session: on a plan with tens of thousands of
# skips (a stale scan against a Photos Library that had reorganised its
# internal structure since the plan was made — an expected, safe
# outcome, not an error), the full warn() detail for every single skip
# flooded the terminal and buried the [MOVE] bar under thousands of
# lines. To an end user watching it happen, that reads as an error
# storm even though nothing unsafe occurred — every skip is a candidate
# left untouched, never a wrong move. Full detail is still written to
# APPLY_LOG, unchanged; only the per-item terminal noise is removed,
# replaced by one categorised summary once MOVE completes.
_move_skip_log() {
  [ -n "${APPLY_LOG:-}" ] && printf '[WARN] %s\n' "$*" >> "$APPLY_LOG" 2>/dev/null || true
}

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

# v1.4.17: single-pass structural validation, replacing three separate
# loops (SCAN, BUILD, VERIFY — added across v1.4.13/v1.4.14) that forked
# an awk process per line (SCAN, BUILD) or per group (VERIFY) against
# files that grew as the plan was processed. That was an O(n^2)-shaped
# pattern, confirmed live on a real 72,685-entry plan: BUILD alone
# reported a 17-minute ETA. Both earlier releases added progress
# visibility to that cost rather than removing it, by design — this is
# the deferred rewrite.
#
# Architecture: PASS 1 does everything SCAN+BUILD+VERIFY did — hashed/
# unhashed classification, keeper-map construction, duplicate/legacy/
# missing-keeper detection — in one linear read of the plan file, using
# AWK's native associative arrays for O(1) lookups. Unlike bash arrays,
# AWK's are unaffected by shell version, so this works identically on
# bash 3.2 (macOS) and bash 4.4+ (Synology DSM) with no bash
# associative-array dependency at all.
#
# A separate cost was found while tracing this: keeper_for_hash() (the
# function this block used to define) was called once PER DEL ENTRY
# during the MOVE loop below, each call forking its own awk scan of the
# keeper map — a fourth instance of the same pattern, not previously
# flagged. PASS 2 replaces it: one linear pass that loads the (already
# built) keeper map into an AWK associative array once, then annotates
# every DEL line with its resolved keeper path in a single read. MOVE
# now reads that annotated file directly instead of calling a per-line
# lookup function.
#
# Every existing rejection condition is preserved exactly: duplicate
# KEEP per hash, a hashed KEEP conflicting with a legacy KEEP for the
# same group, two unresolved legacy KEEPs in a row, an orphaned legacy
# KEEP at end of file, a DEL group with no keeper (ALL such groups
# reported, not just the first — matching the original VERIFY loop's
# accumulate-then-refuse behaviour), and a malformed KEEP entry (empty
# path). The mixed-plan check (some DEL entries hashed, some not) still
# uses hashed/unhashed counts that PASS 1 computes unconditionally for
# every DEL line, exactly like the original SCAN loop — never skipped
# just because a structural error was also found elsewhere in the file,
# since bash needs accurate counts to pick the right branch below
# regardless of what else PASS 1 noticed.
#
# All structured output between AWK and bash below (ERROR/RESULT lines)
# is TAB-delimited and parsed with `IFS=$'\t' read`, never bash word-
# splitting — a path can legitimately contain a space, and an early
# draft of this that used `set -- $line` to parse fields broke exactly
# that case. Caught before shipping by testing a path with a space in
# it, not by inspection.
#
# Regex note: the hash-format check deliberately avoids /{64}/ (an
# interval expression). Not every awk this tool has to run against
# supports interval expressions — lib/awk-detect.sh exists precisely
# because this project already hit a real awk-portability gap (BusyBox
# awk's NUL-record handling, v1.3.19). length(tail)==64 combined with an
# interval-free negated character class is equivalent and has no such
# dependency.
_dd_show_progress=0
[ -t 2 ] && _dd_show_progress=1
_dd_total_lines=$(wc -l < "$PLAN_FILE" 2>/dev/null | tr -d ' ')
[ -z "$_dd_total_lines" ] && _dd_total_lines=0

KEEPER_MAP=""
DEL_ANNOTATED=""
_cleanup_keeper_map() {
  [ -n "${KEEPER_MAP:-}" ] && rm -f -- "$KEEPER_MAP" 2>/dev/null || true
  [ -n "${DEL_ANNOTATED:-}" ] && rm -f -- "$DEL_ANNOTATED" 2>/dev/null || true
}
trap _cleanup_keeper_map EXIT
KEEPER_MAP="$(mktemp "${TMPDIR:-/tmp}/hasher-keepers.XXXXXX")" || { error "Could not create keeper map."; exit 1; }
: > "$KEEPER_MAP"

_dd_pass1_out="$(mktemp "${TMPDIR:-/tmp}/hasher-pass1.XXXXXX")" || { error "Could not create validation output."; exit 1; }
awk -v keeper_out="$KEEPER_MAP" -v show_progress="$_dd_show_progress" -v total_lines="$_dd_total_lines" '
function split_body(line, prefixlen,    body, n, parts, tail, i) {
  body = substr(line, prefixlen + 1)
  n = split(body, parts, "|")
  tail = parts[n]
  if (length(tail) == 64 && tail !~ /[^0-9a-fA-F]/) {
    SPLIT_HASH = tolower(tail)
    SPLIT_PATH = parts[1]
    for (i = 2; i < n; i++) SPLIT_PATH = SPLIT_PATH "|" parts[i]
  } else {
    SPLIT_HASH = ""
    SPLIT_PATH = body
  }
}
function draw_progress(cur,    pct, filled, bar, i) {
  if (!show_progress || total_lines <= 0) return
  if (cur < total_lines && (cur % step) != 0) return
  pct = int(100 * cur / total_lines)
  if (pct > 100) pct = 100
  filled = int(40 * pct / 100)
  bar = ""
  for (i = 0; i < 40; i++) bar = bar (i < filled ? "#" : "-")
  printf "\r[VALIDATE] %3d%% [%s]  %d/%d  checking plan structure    ", \
    pct, bar, cur, total_lines > "/dev/stderr"
}
BEGIN {
  FATAL = 0; hashed_count = 0; unhashed_count = 0
  pending_legacy_path = ""; pending_legacy_line = 0
  group_count = 0; keeper_count = 0
  step = 1
  if (total_lines > 200) step = int(total_lines / 200)
}
{ draw_progress(NR) }
/^KEEP\|/ {
  if (FATAL) next
  split_body($0, 5)
  if (SPLIT_PATH == "") { print "ERROR\tMALFORMED_KEEP\t" NR; FATAL = 1; next }
  if (SPLIT_HASH != "") {
    if ((SPLIT_HASH in keeper_path)) {
      print "ERROR\tDUP_KEEP\t" SPLIT_HASH "\t" keeper_line[SPLIT_HASH] "\t" keeper_path[SPLIT_HASH] "\t" NR "\t" SPLIT_PATH
      FATAL = 1; next
    }
    keeper_path[SPLIT_HASH] = SPLIT_PATH
    keeper_line[SPLIT_HASH] = NR
    keeper_count++
  } else {
    if (pending_legacy_path != "") {
      print "ERROR\tTWO_LEGACY\t" pending_legacy_line "\t" pending_legacy_path "\t" NR "\t" SPLIT_PATH
      FATAL = 1; next
    }
    pending_legacy_path = SPLIT_PATH
    pending_legacy_line = NR
  }
  next
}
/^DEL\|/ {
  split_body($0, 4)
  if (SPLIT_HASH != "") { hashed_count++ } else { unhashed_count++ }
  if (FATAL) next
  if (SPLIT_HASH == "") next
  if (!(SPLIT_HASH in del_seen)) {
    del_seen[SPLIT_HASH] = 1
    del_line[SPLIT_HASH] = NR
    del_path[SPLIT_HASH] = SPLIT_PATH
    group_count++
  }
  if (pending_legacy_path != "") {
    if ((SPLIT_HASH in keeper_path)) {
      print "ERROR\tHASHED_AND_LEGACY\t" SPLIT_HASH "\t" pending_legacy_line "\t" pending_legacy_path
      FATAL = 1; next
    }
    keeper_path[SPLIT_HASH] = pending_legacy_path
    keeper_line[SPLIT_HASH] = pending_legacy_line
    keeper_count++
    pending_legacy_path = ""; pending_legacy_line = 0
  }
  next
}
END {
  if (show_progress && total_lines > 0) { draw_progress(total_lines); printf "\r%80s\r", "" > "/dev/stderr" }
  if (!FATAL) {
    if (pending_legacy_path != "") {
      print "ERROR\tORPHAN_LEGACY\t" pending_legacy_line "\t" pending_legacy_path
      FATAL = 1
    } else {
      missing = 0
      for (h in del_seen) {
        if (!(h in keeper_path)) { print "ERROR\tMISSING_KEEPER\t" h "\t" del_line[h] "\t" del_path[h]; missing++ }
      }
      if (missing > 0) FATAL = 1
    }
  }
  if (!FATAL && keeper_out != "") {
    for (h in keeper_path) print h "\t" keeper_path[h] "\t" keeper_line[h] >> keeper_out
    close(keeper_out)
  }
  print "RESULT\t" hashed_count "\t" unhashed_count "\t" group_count "\t" keeper_count "\t" FATAL
}
' "$PLAN_FILE" > "$_dd_pass1_out"

_hashed_count=$(awk -F'\t' '/^RESULT/{print $2}' "$_dd_pass1_out")
_unhashed_count=$(awk -F'\t' '/^RESULT/{print $3}' "$_dd_pass1_out")
_group_count=$(awk -F'\t' '/^RESULT/{print $4}' "$_dd_pass1_out")
_keeper_count=$(awk -F'\t' '/^RESULT/{print $5}' "$_dd_pass1_out")
_pass1_fatal=$(awk -F'\t' '/^RESULT/{print $6}' "$_dd_pass1_out")
: "${_hashed_count:=0}"; : "${_unhashed_count:=0}"; : "${_group_count:=0}"; : "${_keeper_count:=0}"; : "${_pass1_fatal:=0}"

if [ "$_hashed_count" -gt 0 ] && [ "$_unhashed_count" -gt 0 ]; then
  error "Plan is MIXED: $_hashed_count DEL entries carry a hash, $_unhashed_count do not."
  error "Refusing to apply — a mixed plan cannot be safely classified as verified."
  error "Regenerate the plan against a current hash manifest and try again."
  rm -f -- "$_dd_pass1_out" 2>/dev/null || true
  exit 2
fi

PLAN_HAS_HASHES=0
[ "$_hashed_count" -gt 0 ] && [ "$_unhashed_count" -eq 0 ] && PLAN_HAS_HASHES=1

if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
  if [ -n "$HASH_CMD_DD" ]; then
    info "Plan carries content hashes — all $_hashed_count candidates will be re-verified before quarantine."
  else
    error "Plan carries content hashes but no hash tool is available."
    error "Install sha256sum (coreutils) or shasum (Perl), or run this on a"
    error "host that has one. Refusing to apply without re-verification."
    rm -f -- "$_dd_pass1_out" 2>/dev/null || true
    exit 2
  fi

  if [ "$_pass1_fatal" = "1" ]; then
    while IFS=$'\t' read -r _tag _type _f1 _f2 _f3 _f4 _f5; do
      [ "$_tag" = "ERROR" ] || continue
      case "$_type" in
        MALFORMED_KEEP)
          error "Malformed KEEP entry at plan line $_f1."
          ;;
        DUP_KEEP)
          # _f1=hash _f2=first_line _f3=first_path _f4=next_line _f5=next_path
          error "Hash group $_f1 contains more than one KEEP entry."
          error "  first KEEP: line $_f2: $_f3"
          error "  next KEEP:  line $_f4: $_f5"
          error "Refusing ambiguous plan: $PLAN_FILE"
          ;;
        TWO_LEGACY)
          # _f1=first_line _f2=first_path _f3=next_line _f4=next_path
          error "Two legacy KEEP entries appeared without an intervening hashed DEL group."
          error "  first KEEP: line $_f1: $_f2"
          error "  next KEEP:  line $_f3: $_f4"
          ;;
        HASHED_AND_LEGACY)
          # _f1=hash _f2=legacy_line _f3=legacy_path
          error "Hash group $_f1 has both a hashed KEEP and a legacy KEEP."
          error "  legacy KEEP: line $_f2: $_f3"
          ;;
        ORPHAN_LEGACY)
          # _f1=line _f2=path
          error "Legacy KEEP entry at line $_f1 has no following hashed DEL group."
          error "  keeper: $_f2"
          ;;
        MISSING_KEEPER)
          # _f1=hash _f2=first_del_line _f3=first_del_path
          error "Hash group $_f1 has DEL entries but no KEEP entry."
          error "  first DEL: line $_f2: $_f3"
          ;;
      esac
    done < "$_dd_pass1_out"

    if grep -q '^ERROR	MISSING_KEEPER	' "$_dd_pass1_out"; then
      _missing_n=$(grep -c '^ERROR	MISSING_KEEPER	' "$_dd_pass1_out")
      error "Plan validation failed: $_missing_n group(s) have no unique keeper."
      error "Regenerate or re-review the plan before applying it."
    fi
    rm -f -- "$_dd_pass1_out" 2>/dev/null || true
    exit 2
  fi

  info "Plan structure valid: $_group_count hash groups, $_keeper_count unique KEEP entries, $TOTAL_DEL DEL candidates."

fi

# v1.4.17: PASS 2 runs unconditionally (not only for hashed plans).
# Harmless for a legacy/unverified plan -- KEEPER_MAP is naturally
# empty in that case (PASS 1 only ever populates it for a plan that
# turns out to be hashed), so every DEL line is simply annotated with
# an empty keeper column, which the MOVE loop below already only
# consults when PLAN_HAS_HASHES -eq 1 -- unchanged from before this
# rewrite. This lets both downstream loops (existing/missing count,
# and the actual move) read one unified format regardless of plan
# type, instead of needing two full copies of ~80 lines of move logic.
# PASS 2: annotate every DEL line with its resolved keeper path in one
# linear pass, replacing keeper_for_hash()'s per-DEL-entry forked scan
# inside the MOVE loop below.
DEL_ANNOTATED="$(mktemp "${TMPDIR:-/tmp}/hasher-delannotated.XXXXXX")" || { error "Could not create annotation output."; exit 1; }
: > "$DEL_ANNOTATED"
awk -v keeper_map="$KEEPER_MAP" -v out="$DEL_ANNOTATED" -v show_progress="$_dd_show_progress" -v total_lines="$_dd_total_lines" '
function split_body(line, prefixlen,    body, n, parts, tail, i) {
  body = substr(line, prefixlen + 1)
  n = split(body, parts, "|")
  tail = parts[n]
  if (length(tail) == 64 && tail !~ /[^0-9a-fA-F]/) {
    SPLIT_HASH = tolower(tail)
    SPLIT_PATH = parts[1]
    for (i = 2; i < n; i++) SPLIT_PATH = SPLIT_PATH "|" parts[i]
  } else {
    SPLIT_HASH = ""
    SPLIT_PATH = body
  }
}
function draw_progress(cur,    pct, filled, bar, i) {
  if (!show_progress || total_lines <= 0) return
  if (cur < total_lines && (cur % step) != 0) return
  pct = int(100 * cur / total_lines)
  if (pct > 100) pct = 100
  filled = int(40 * pct / 100)
  bar = ""
  for (i = 0; i < 40; i++) bar = bar (i < filled ? "#" : "-")
  printf "\r[ANNOTATE] %3d%% [%s]  %d/%d  linking candidates to their keeper    ", \
    pct, bar, cur, total_lines > "/dev/stderr"
}
BEGIN {
  while ((getline kline < keeper_map) > 0) { split(kline, kf, "\t"); keeper[kf[1]] = kf[2] }
  close(keeper_map)
  step = 1
  if (total_lines > 200) step = int(total_lines / 200)
}
/^DEL\|/ {
  draw_progress(NR)
  split_body($0, 4)
  # v1.4.17 fix: EVERY DEL line gets a row here, hashed or not. An
  # earlier version of this skipped unhashed lines entirely (matching
  # the intuition that "no hash, nothing to annotate") — but that left
  # DEL_ANNOTATED completely empty for a legacy/unverified plan, since
  # every DEL line in one is unhashed. The downstream MOVE loop needs
  # this file populated regardless of plan type; kp is simply empty
  # both when there is no hash and when there is one but no match
  # (which should not happen for a plan that already passed PASS 1).
  kp = (SPLIT_HASH != "" && (SPLIT_HASH in keeper)) ? keeper[SPLIT_HASH] : ""
  print SPLIT_PATH "\t" SPLIT_HASH "\t" kp >> out
}
END {
  if (show_progress && total_lines > 0) printf "\r%80s\r", "" > "/dev/stderr"
}
' "$PLAN_FILE"
rm -f -- "$_dd_pass1_out" 2>/dev/null || true

keeper_for_hash() {
  # v1.4.17: retained only as a defensive fallback. The MOVE loop's
  # normal path no longer calls this — see DEL_ANNOTATED above.
  [ -n "${KEEPER_MAP:-}" ] && [ -s "$KEEPER_MAP" ] || return 0
  awk -F '\t' -v h="$1" '$1==h {print $2; exit}' "$KEEPER_MAP"
}

# Pass 1: count existing vs missing
# v1.4.17: reads DEL_ANNOTATED (path\thash\tkeeper, one row per DEL
# entry, populated for every plan type by PASS 2 above) instead of
# re-parsing $PLAN_FILE with _split_del_line per line — the fields are
# already split out, so this is a plain read with no per-line function
# call at all.
existing=0
missing=0

while IFS=$'\t' read -r DEL_PATH DEL_HASH GROUP_KEEP || [ -n "$DEL_PATH" ]; do
  [ -z "$DEL_PATH" ] && continue
  if [ -e "$DEL_PATH" ]; then
    existing=$((existing+1))
  else
    missing=$((missing+1))
  fi
done <"$DEL_ANNOTATED"

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
# v1.4.18: per-category breakdown of moves_skipped_changed, for the
# summary at the end of MOVE — see _move_skip_log() above for why this
# exists. bash 3.2 (macOS) has no associative arrays, so these are
# named counters rather than a map; there are only nine routine skip
# reasons and that list changes rarely.
skip_symlink=0
skip_canon_failed=0
skip_no_keeper_map=0
skip_keeper_invalid=0
skip_keeper_missing=0
skip_keeper_changed=0
skip_missing_hash=0
skip_rehash_failed=0
skip_content_changed=0

# v1.4.5: progress reporting for the quarantine loop.
#
# Moving 1584 files across a NAS volume takes a minute or two and previously
# printed nothing between "Plan summary:" and "Move complete:". With no
# output the operator cannot distinguish slow-but-working from hung, and the
# natural response to a apparently-frozen destructive operation is to
# interrupt it — which is the worst possible moment to do so.
#
# `$existing` is the count of DEL entries that still exist on disk, already
# computed for the summary above, so this needs no extra pass over the plan.
_move_seen=0
_move_total="${existing:-0}"
_move_started="$(date +%s)"
[ "$_move_total" -gt 0 ] && info "Moving $_move_total file(s) to quarantine..."

# shellcheck disable=SC2162
while IFS=$'\t' read -r DEL_PATH DEL_HASH GROUP_KEEP || [ -n "$DEL_PATH" ]; do
      [ -z "$DEL_PATH" ] && continue
      [ -e "$DEL_PATH" ] || continue

      # Counted before the safety checks below, so skipped entries still
      # advance the bar — the total is "entries examined", not "moved".
      _move_seen=$(( _move_seen + 1 ))
      log_progress_bar "MOVE" "$_move_seen" "$_move_total" "$_move_started"

      if [ -L "$DEL_PATH" ]; then
        skip_symlink=$((skip_symlink+1))
        _move_skip_log "Planned path is now a symlink — SKIPPING for safety: $DEL_PATH"
        moves_fail=$((moves_fail+1))
        continue
      fi

      if command -v canonical_existing_path >/dev/null 2>&1; then
        DEL_REAL="$(canonical_existing_path "$DEL_PATH" 2>/dev/null || true)"
      else
        DEL_REAL="$DEL_PATH"
      fi
      if [ -z "$DEL_REAL" ] || [ ! -f "$DEL_REAL" ]; then
        skip_canon_failed=$((skip_canon_failed+1))
        _move_skip_log "Could not canonicalise planned file — SKIPPING for safety: $DEL_PATH"
        moves_fail=$((moves_fail+1))
        continue
      fi

      # v1.3.28: verify that the planned keeper still exists and still has
      # the group's expected content before moving any DEL entry. A surviving
      # DEL is not expendable if its keeper disappeared or changed.
      #
      # v1.4.17: GROUP_KEEP is already known here — annotated onto this
      # exact DEL row by PASS 2 above — so there is no longer a call to
      # keeper_for_hash() (which used to fork its own awk scan of the
      # keeper map once per DEL entry) at this point.
      if [ "$PLAN_HAS_HASHES" -eq 1 ]; then
        if [ -z "$GROUP_KEEP" ]; then
          skip_no_keeper_map=$((skip_no_keeper_map+1))
          _move_skip_log "No unique KEEP mapping for hash $DEL_HASH — SKIPPING group candidate: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        if [ "$GROUP_KEEP" = "$DEL_PATH" ] || [ -L "$GROUP_KEEP" ]; then
          skip_keeper_invalid=$((skip_keeper_invalid+1))
          _move_skip_log "Keeper is invalid or is the DEL path — SKIPPING: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        if command -v canonical_existing_path >/dev/null 2>&1; then
          KEEP_REAL="$(canonical_existing_path "$GROUP_KEEP" 2>/dev/null || true)"
        else
          KEEP_REAL="$GROUP_KEEP"
        fi
        if [ -z "$KEEP_REAL" ] || [ ! -f "$KEEP_REAL" ]; then
          skip_keeper_missing=$((skip_keeper_missing+1))
          _move_skip_log "Keeper is missing or not a regular file — SKIPPING: $DEL_PATH"
          _move_skip_log "  keeper: $GROUP_KEEP"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        keeper_actual="$($HASH_CMD_DD -- "$KEEP_REAL" 2>/dev/null | awk '{print $1}')"
        if [ -z "$keeper_actual" ] || [ "$keeper_actual" != "$DEL_HASH" ]; then
          skip_keeper_changed=$((skip_keeper_changed+1))
          _move_skip_log "Keeper changed or could not be re-hashed — SKIPPING: $DEL_PATH"
          _move_skip_log "  keeper:   $GROUP_KEEP"
          _move_skip_log "  expected: $DEL_HASH"
          [ -n "$keeper_actual" ] && _move_skip_log "  actual:   $keeper_actual"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi

        # v1.2.0: re-verify DEL content hash before quarantining
        # v1.3.17 (finding #2 belt-and-braces): if the pre-flight classified
        # the plan as hashed but we somehow reach here with an empty DEL_HASH,
        # that is a pre-flight bug or a race — safety-skip rather than move
        # without verification.
        if [ -z "$DEL_HASH" ]; then
          skip_missing_hash=$((skip_missing_hash+1))
          _move_skip_log "Missing per-entry hash on a verified plan — SKIPPING for safety: $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        actual="$($HASH_CMD_DD -- "$DEL_REAL" 2>/dev/null | awk '{print $1}')"
        if [ -z "$actual" ]; then
          skip_rehash_failed=$((skip_rehash_failed+1))
          _move_skip_log "Could not re-hash (skipping for safety): $DEL_PATH"
          moves_skipped_changed=$((moves_skipped_changed+1))
          continue
        fi
        if [ "$actual" != "$DEL_HASH" ]; then
          skip_content_changed=$((skip_content_changed+1))
          _move_skip_log "Content changed since plan was made — SKIPPING: $DEL_PATH"
          _move_skip_log "  expected $DEL_HASH"
          _move_skip_log "  actual   $actual"
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
done <"$DEL_ANNOTATED"

# Clear the in-place bar so the summary below starts on a clean line.
log_progress_done

if [ "$moves_skipped_changed" -gt 0 ]; then
  # v1.4.18: categorised breakdown instead of a bare count. Reported
  # live: on a plan with tens of thousands of routine skips (a stale
  # scan against a Photos Library that had reorganised its internal
  # structure since the plan was made), the old per-item warn() output
  # for every single skip flooded the terminal and read as an error
  # storm to the person watching it happen, even though nothing unsafe
  # occurred. Full per-file detail is unchanged in APPLY_LOG; this is
  # what now appears on screen instead — one line per reason that
  # actually happened, each with its own count, plus a pointer to the
  # log for anyone who wants the individual paths.
  #
  # Scoped to exactly the categories that increment moves_skipped_changed
  # (a "safety skip": the candidate could not be re-verified as still
  # matching the plan). skip_symlink/skip_canon_failed are deliberately
  # NOT listed here even though they're also routine, non-destructive
  # skips — they increment moves_fail instead (a pre-existing, separate
  # bucket; see the "Move complete" line below), so listing them here
  # would make this block's own header count not match the sum of what
  # it lists. Caught by testing two different skip categories occurring
  # in the same run, not by inspection — an early version of this fix
  # had exactly that mismatch.
  warn "$moves_skipped_changed file(s) skipped because the DEL or its keeper could not be safely re-verified:"
  [ "$skip_keeper_missing"  -gt 0 ] && warn "  keeper missing or not a regular file: $skip_keeper_missing"
  [ "$skip_keeper_changed"  -gt 0 ] && warn "  keeper changed or could not be re-hashed: $skip_keeper_changed"
  [ "$skip_content_changed" -gt 0 ] && warn "  DEL content changed since the plan was made: $skip_content_changed"
  [ "$skip_no_keeper_map"   -gt 0 ] && warn "  no unique KEEP mapping for the group: $skip_no_keeper_map"
  [ "$skip_keeper_invalid"  -gt 0 ] && warn "  keeper invalid or same as the DEL path: $skip_keeper_invalid"
  [ "$skip_missing_hash"    -gt 0 ] && warn "  missing per-entry hash on a verified plan: $skip_missing_hash"
  [ "$skip_rehash_failed"   -gt 0 ] && warn "  could not re-hash the DEL candidate: $skip_rehash_failed"
  warn "Every skip leaves the file in place — none of these were moved. Full detail"
  warn "for each one, including its path, is in: $APPLY_LOG"
  warn "Re-run hashing and duplicate discovery to rebuild a current plan."
fi
if [ "$moves_fail" -gt 0 ] && { [ "$skip_symlink" -gt 0 ] || [ "$skip_canon_failed" -gt 0 ]; }; then
  # v1.4.18: same categorised-breakdown treatment for the moves_fail
  # bucket's two routine, expected causes (a plan entry that's now a
  # symlink, or a path that fails to canonicalise) — kept as a separate
  # block rather than folded into the one above, since it counts against
  # a different total (moves_fail, not moves_skipped_changed) and mixing
  # them would make neither header count match its own listed items.
  # moves_fail can also include genuinely unexpected mv(1) failures with
  # no category counter of their own; this block only ever lists the two
  # routine causes, so it can legitimately under-count moves_fail's
  # total — it is not claiming to explain every failure, only these two.
  warn "$moves_fail file(s) could not be moved:"
  [ "$skip_symlink"      -gt 0 ] && warn "  planned path is now a symlink: $skip_symlink"
  [ "$skip_canon_failed" -gt 0 ] && warn "  could not canonicalise the planned path: $skip_canon_failed"
  warn "Full detail for each one, including its path, is in: $APPLY_LOG"
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
