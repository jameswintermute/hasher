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

# Colours + logging from the shared module (v1.3.11), the single source of truth.
# Fallback to minimal local defs if the shared file is missing.
if [ -r "$ROOT_DIR/lib/log.sh" ]; then
  . "$ROOT_DIR/lib/log.sh"
else
  info(){ printf '[INFO] %s\n' "$*"; }
  work(){ printf '[WORK] %s\n' "$*"; }
  ok(){   printf '[OK] %s\n'   "$*"; }
  warn(){ printf '[WARN] %s\n' "$*"; }
  err(){  printf '[ERR] %s\n'  "$*" >&2; }
fi

usage() {
  printf "%s\n" \
    "Usage: apply-folder-plan.sh [--plan <file>] [--force] [--delete-metadata]" \
    "                            [--verify-against TSV] [--no-verify] [--allow-unverified]" \
    "  --plan FILE         Plan file (one directory per line). Defaults to latest duplicate-folders plan in logs/" \
    "  --force             Do not ask for confirmation." \
    "  --delete-metadata   Delete metadata cache dirs (@eaDir, .AppleDouble) instead of moving them." \
    "  --verify-against TSV  Groups TSV (size<TAB>keep<TAB>del) for apply-time content re-verification." \
    "  --no-verify         Disable apply-time content re-verification entirely." \
    "  --allow-unverified  Proceed even when a planned delete has no keeper mapping (default: skip it)."
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN_FILE="${2:-}"; shift 2;;
    --force) FORCE=true; shift;;
    --delete-metadata) DELETE_METADATA=true; shift;;
    --verify-against) VERIFY_TSV="${2:-}"; shift 2;;
    --no-verify) NO_VERIFY=true; shift;;
    --allow-unverified) ALLOW_UNVERIFIED=true; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done
VERIFY_TSV="${VERIFY_TSV:-}"
NO_VERIFY="${NO_VERIFY:-false}"
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-false}"

# FIX (v1.3.8 — recheck concern 2): resolve and validate PLAN_FILE BEFORE
# verification-sidecar discovery. Previously the default (no --plan) plan was
# resolved later, so sidecar discovery ran with an empty PLAN_FILE, found no
# matching groups TSV, and (under the fail-safe) skipped every deletion. Order
# is now: parse args → default+validate PLAN_FILE → discover sidecar → apply.
if [ -z "${PLAN_FILE:-}" ]; then
  PLAN_FILE="$(ls -1t "$LOGS_DIR"/duplicate-folders-plan-*.txt 2>/dev/null | head -n1 || true)"
fi
if [ -z "${PLAN_FILE:-}" ] || [ ! -s "$PLAN_FILE" ]; then
  err "No plan file found. Run 'Find duplicate folders' first."
  exit 2
fi

# FIX (v1.3.5 — peer-review item 2): apply-time content re-verification for
# folder dedup, mirroring the file-dedup re-hash. If a groups TSV is available
# (size\tkeepdir\tdeldir), we recompute each pair's CURRENT direct-file
# signature from disk immediately before moving, and skip any DEL folder whose
# signature no longer matches its KEEP folder — e.g. a unique file was added to
# the DEL folder after the plan was generated. Disk is the source of truth.
# Auto-discover the groups TSV for verification if not supplied and not disabled.
# FIX (v1.3.7 — cross-check concern 3): resolve the sidecar STRICTLY from the
# plan being applied. If the plan is a reviewed plan (has a -STAMP), use the
# matching reviewed sidecar and ONLY that. If it's a raw/unstamped plan, use the
# matching original groups TSV by date if present. Never fall back to "newest
# reviewed sidecar" — an unrelated sidecar gives a wrong keeper map. If no
# matching mapping is found, verification stays ON but with an empty map, which
# (per the fail-safe change below) causes unmapped deletes to be SKIPPED rather
# than moved.
if [ "$NO_VERIFY" != true ] && [ -z "$VERIFY_TSV" ]; then
  _plan_base="$(basename -- "${PLAN_FILE:-}")"
  _stamp="$(printf '%s\n' "$_plan_base" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1 || true)"
  if printf '%s\n' "$_plan_base" | grep -q 'reviewed'; then
    # reviewed plan → require the exactly-matching reviewed sidecar
    if [ -n "$_stamp" ] && [ -s "$LOGS_DIR/duplicate-folders-groups-reviewed-$_stamp.tsv" ]; then
      VERIFY_TSV="$LOGS_DIR/duplicate-folders-groups-reviewed-$_stamp.tsv"
    else
      warn "Reviewed plan has no matching reviewed groups sidecar; deletions without a keeper mapping will be SKIPPED."
    fi
  else
    # raw plan → derive the matching groups TSV from the COMPLETE plan suffix.
    # Current raw artefacts include timestamp + PID, for example:
    #   duplicate-folders-plan-YYYY-MM-DD-HHMMSS-PID.txt
    #   duplicate-folders-groups-YYYY-MM-DD-HHMMSS-PID.tsv
    # Deriving the suffix from the basename avoids dropping the PID and silently
    # failing to resolve the verification sidecar. Retain older fallbacks for
    # pre-PID and date-only artefacts.
    _raw_suffix="${_plan_base#duplicate-folders-plan-}"
    _raw_suffix="${_raw_suffix%.txt}"
    if [ "$_raw_suffix" != "$_plan_base" ] && [ -s "$LOGS_DIR/duplicate-folders-groups-$_raw_suffix.tsv" ]; then
      VERIFY_TSV="$LOGS_DIR/duplicate-folders-groups-$_raw_suffix.tsv"
    elif [ -n "$_stamp" ] && [ -s "$LOGS_DIR/duplicate-folders-groups-$_stamp.tsv" ]; then
      VERIFY_TSV="$LOGS_DIR/duplicate-folders-groups-$_stamp.tsv"
    else
      _date="$(printf '%s\n' "$_plan_base" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)"
      if [ -n "$_date" ] && [ -s "$LOGS_DIR/duplicate-folders-groups-$_date.tsv" ]; then
        VERIFY_TSV="$LOGS_DIR/duplicate-folders-groups-$_date.tsv"
      else
        warn "No groups TSV matching this plan; deletions without a keeper mapping will be SKIPPED (use --allow-unverified to override)."
      fi
    fi
  fi
fi

# v1.3.28: resolve SHA-256 once. Verified folder apply must never degrade to
# empty hashes when the command is absent or a file cannot be hashed.
FOLDER_HASH_STYLE=""
if command -v sha256sum >/dev/null 2>&1; then
  FOLDER_HASH_STYLE="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  FOLDER_HASH_STYLE="shasum"
fi

# Compute the direct-file signature of a directory from disk. Returns non-zero
# if discovery, stat or hashing fails for any direct regular file.
dir_signature() {
  d="$1"
  [ -d "$d" ] || return 1
  [ -n "$FOLDER_HASH_STYLE" ] || return 1

  _sig_list="$(mktemp "${TMPDIR:-/tmp}/folder-sig-list.XXXXXX")" || return 1
  _sig_out="$(mktemp "${TMPDIR:-/tmp}/folder-sig-out.XXXXXX")" || { rm -f -- "$_sig_list"; return 1; }
  if ! find "$d" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort > "$_sig_list"; then
    rm -f -- "$_sig_list" "$_sig_out"; return 1
  fi
  : > "$_sig_out"
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || { rm -f -- "$_sig_list" "$_sig_out"; return 1; }
    b="$(basename "$f")"
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')" || { rm -f -- "$_sig_list" "$_sig_out"; return 1; }
    case "$sz" in ''|*[!0-9]*) rm -f -- "$_sig_list" "$_sig_out"; return 1 ;; esac
    if [ "$FOLDER_HASH_STYLE" = "sha256sum" ]; then
      h="$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')" || h=""
    else
      h="$(shasum -a 256 -- "$f" 2>/dev/null | awk '{print $1}')" || h=""
    fi
    if [ "${#h}" -ne 64 ] || ! printf '%s' "$h" | grep -qiE '^[0-9a-f]{64}$'; then
      rm -f -- "$_sig_list" "$_sig_out"; return 1
    fi
    printf '%s|%s|%s\n' "$b" "$h" "$sz" >> "$_sig_out" || { rm -f -- "$_sig_list" "$_sig_out"; return 1; }
  done < "$_sig_list"
  cat "$_sig_out"
  _sig_rc=$?
  rm -f -- "$_sig_list" "$_sig_out"
  return "$_sig_rc"
}

# Build a lookup of DEL -> KEEP from the groups TSV, if available.
# FIX (v1.3.6 — cross-check concern 5): the v1.3.5 version used `declare -A`
# (associative array), which is Bash 4+ only and breaks the project's Bash 3.2
# baseline (macOS ships 3.2 as /bin/bash). Replaced with a 3.2-safe lookup: a
# normalised temp TSV (keeper<TAB>del) queried per-DEL with awk on exact match.
VERIFY_ACTIVE=false
KEEP_MAP=""
if [ "$NO_VERIFY" = true ]; then
  warn "Apply-time verification DISABLED (--no-verify)."
else
  # FIX (v1.3.7 — cross-check concern 3): verification is ACTIVE whenever it is
  # not explicitly disabled, even if no groups TSV/keeper map was resolved. With
  # no map, every planned delete hits the no-keeper branch, which fail-safes to
  # SKIP (unless --allow-unverified). Previously VERIFY_ACTIVE was false when the
  # map was missing, so deletes proceeded entirely unverified.
  VERIFY_ACTIVE=true
  if [ -n "$VERIFY_TSV" ] && [ -s "$VERIFY_TSV" ]; then
    KEEP_MAP="$(mktemp "${TMPDIR:-/tmp}/keepmap.XXXXXX")"
    # Normalise to "deldir<TAB>keepdir" for direct lookup by del path.
    awk -F'\t' 'NF>=3 { print $3 "\t" $2 }' "$VERIFY_TSV" > "$KEEP_MAP" 2>/dev/null || true
    info "Apply-time verification ON (groups: $VERIFY_TSV). DEL folders that no longer match their keeper, or have no keeper mapping, will be skipped."
  else
    warn "Apply-time verification ON but no keeper map resolved — planned deletes without a mapping will be SKIPPED (use --allow-unverified to override, or --no-verify to disable)."
  fi
fi
[ "$ALLOW_UNVERIFIED" = true ] && warn "--allow-unverified: deletes without a keeper mapping will PROCEED unverified."
if [ "$VERIFY_ACTIVE" = true ] && [ -z "$FOLDER_HASH_STYLE" ]; then
  error "Apply-time verification requires sha256sum or shasum, but neither is available."
  error "Refusing to apply the folder plan without content hashes."
  exit 2
fi

# has_child_dirs DIR → returns 0 (true) if DIR contains at least one immediate
# subdirectory. Used for the apply-time leaf check (concern: a folder that was a
# leaf at plan time may have gained a subdirectory before apply).
has_child_dirs() {
  find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .
}

# Return true when DIR contains an immediate entry that is neither a regular
# file nor a directory (symlink, FIFO, socket, block/character device, etc.).
# Folder signatures intentionally cover regular files only, so these entries
# must be rechecked at APPLY time as well as plan-generation time.
has_nonregular_children() {
  find "$1" -mindepth 1 -maxdepth 1 ! -type f ! -type d -print -quit 2>/dev/null | grep -q .
}

# keeper_for DEL  → prints the mapped keeper dir (exact match), or empty.
keeper_for() {
  [ -n "$KEEP_MAP" ] && [ -s "$KEEP_MAP" ] || { printf ''; return; }
  awk -F'\t' -v d="$1" '$1==d { print $2; exit }' "$KEEP_MAP"
}

# FIX (v1.3.8 — recheck concern 4): use the SHARED resolve_quarantine_dir() from
# lib/host-detect.sh rather than a private copy. The local copy did not honour an
# exported QUARANTINE_DIR environment variable (only the conf), diverging from
# the shared resolver. Source the helper and call the shared function; fall back
# to an install-relative default only if the helper is missing.
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT_DIR/lib/host-detect.sh"
fi
if command -v resolve_quarantine_dir >/dev/null 2>&1; then
  QDIR="$(resolve_quarantine_dir)"
else
  QDIR="${QUARANTINE_DIR:-$ROOT_DIR/quarantine-$(date +%F)}"
fi
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
trap 'rm -f "$PLAN_CLEAN" "${KEEP_MAP:-}" 2>/dev/null' EXIT
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

idx=0; moved=0; fail=0; removed=0; skipped_verify=0
while IFS= read -r src; do
  [ -z "$src" ] && continue
  # belt-and-braces: skip any comment line even though PLAN_CLEAN is filtered
  case "$src" in \#*) continue ;; esac
  idx=$((idx+1))

  src_plan="$src"
  if [ -L "$src_plan" ]; then
    warn "($idx/$COUNT) planned folder path is now a symlink — refusing to follow it: $src_plan"
    fail=$((fail+1))
    _audit "SOURCE_SYMLINK_REFUSED" "$src_plan" "" ""
    continue
  fi
  if command -v canonical_existing_path >/dev/null 2>&1; then
    src_real="$(canonical_existing_path "$src_plan" 2>/dev/null || true)"
  else
    src_real="$src_plan"
  fi
  if [ -z "$src_real" ] || [ ! -d "$src_real" ]; then
    warn "($idx/$COUNT) source folder is missing or cannot be canonicalised: $src_plan"
    fail=$((fail+1))
    _audit "SOURCE_INVALID" "$src_plan" "" ""
    continue
  fi

  # per-folder size (best-effort, for the audit record)
  sz_kb="$(du -sk -- "$src_real" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$sz_kb" =~ ^[0-9]+$ ]] || sz_kb=""

  # FIX (v1.3.5 — item 2): apply-time content re-verification. If we have a
  # keeper for this DEL folder, recompute both signatures from disk NOW and skip
  # the move if they differ — the folder is no longer a true duplicate (e.g. a
  # unique file was added after the plan was generated).
  # FIX (v1.3.8 — recheck concern 1): APPLY-TIME LEAF CHECK. find-duplicate-
  # folders.sh excludes non-leaf directories at PLAN time, but a folder that was
  # a leaf when the plan was written may have gained a subdirectory before the
  # plan is applied. Since apply moves the directory RECURSIVELY, moving a folder
  # that is no longer a leaf would relocate nested data that was never compared.
  # Re-check leaf status from disk NOW and skip if either the delete folder or
  # its keeper has child directories. This is independent of content
  # verification — it holds even under --no-verify — because moving non-leaf
  # data is outside what a leaf-level tool ever proved. --allow-unverified is the
  # single documented escape hatch.
  if [ "$ALLOW_UNVERIFIED" != true ]; then
    _keep_for_leaf="$(keeper_for "$src_plan" 2>/dev/null || true)"
    _keep_real=""
    if [ -n "$_keep_for_leaf" ]; then
      if [ -L "$_keep_for_leaf" ]; then
        warn "($idx/$COUNT) SKIP — keeper path is now a symlink: $_keep_for_leaf"
        skipped_verify=$((skipped_verify+1))
        _audit "SKIPPED_KEEP_SYMLINK" "$src_plan" "$_keep_for_leaf" "$sz_kb"
        continue
      fi
      if command -v canonical_existing_path >/dev/null 2>&1; then
        _keep_real="$(canonical_existing_path "$_keep_for_leaf" 2>/dev/null || true)"
      else
        _keep_real="$_keep_for_leaf"
      fi
    fi
    if has_child_dirs "$src_real"; then
      warn "($idx/$COUNT) SKIP — no longer a leaf folder (gained sub-folders since planning): $src_plan"
      warn "   moving it would relocate nested data that was never compared."
      skipped_verify=$((skipped_verify+1))
      _audit "SKIPPED_NONLEAF_DEL" "$src_plan" "${_keep_for_leaf:-}" "$sz_kb"
      continue
    fi
    if has_nonregular_children "$src_real"; then
      warn "($idx/$COUNT) SKIP — folder gained a symlink or other non-regular entry since planning: $src_plan"
      warn "   that entry was never covered by the duplicate signature."
      skipped_verify=$((skipped_verify+1))
      _audit "SKIPPED_NONREGULAR_DEL" "$src_plan" "${_keep_for_leaf:-}" "$sz_kb"
      continue
    fi
    if [ -n "$_keep_real" ] && has_child_dirs "$_keep_real"; then
      warn "($idx/$COUNT) SKIP — keeper is no longer a leaf folder: $_keep_for_leaf"
      skipped_verify=$((skipped_verify+1))
      _audit "SKIPPED_NONLEAF_KEEP" "$src_plan" "$_keep_for_leaf" "$sz_kb"
      continue
    fi
    if [ -n "$_keep_real" ] && has_nonregular_children "$_keep_real"; then
      warn "($idx/$COUNT) SKIP — keeper gained a symlink or other non-regular entry: $_keep_for_leaf"
      skipped_verify=$((skipped_verify+1))
      _audit "SKIPPED_NONREGULAR_KEEP" "$src_plan" "$_keep_for_leaf" "$sz_kb"
      continue
    fi
  fi

  if [ "$VERIFY_ACTIVE" = true ]; then
    keep="$(keeper_for "$src_plan")"
    if [ -n "$keep" ]; then
      if command -v canonical_existing_path >/dev/null 2>&1; then
        keep_real="$(canonical_existing_path "$keep" 2>/dev/null || true)"
      else
        keep_real="$keep"
      fi
      if [ -z "$keep_real" ] || [ ! -d "$keep_real" ]; then
        warn "($idx/$COUNT) SKIP — keeper is missing or cannot be canonicalised: $keep"
        skipped_verify=$((skipped_verify+1))
        _audit "SKIPPED_KEEP_INVALID" "$src_plan" "$keep" "$sz_kb"
        continue
      fi
      if ! del_sig="$(dir_signature "$src_real")"; then
        warn "($idx/$COUNT) SKIP — could not calculate a complete SHA-256 signature: $src_plan"
        fail=$((fail+1))
        _audit "SKIPPED_SIGNATURE_ERROR_DEL" "$src_plan" "$keep" "$sz_kb"
        continue
      fi
      if ! keep_sig="$(dir_signature "$keep_real")"; then
        warn "($idx/$COUNT) SKIP — could not calculate keeper SHA-256 signature: $keep"
        fail=$((fail+1))
        _audit "SKIPPED_SIGNATURE_ERROR_KEEP" "$src_plan" "$keep" "$sz_kb"
        continue
      fi
      if [ "$del_sig" != "$keep_sig" ]; then
        warn "($idx/$COUNT) SKIP — contents no longer match keeper: $src_plan"
        warn "   keeper: $keep"
        skipped_verify=$((skipped_verify+1))
        _audit "SKIPPED_VERIFY_MISMATCH" "$src_plan" "$keep" "$sz_kb"
        continue
      fi
    else
      # FIX (v1.3.7 — cross-check concern 3): FAIL-SAFE. When verification is
      # active but this DEL folder has no keeper mapping, we cannot prove it is
      # still a duplicate. Default to SKIPPING it rather than moving it. The user
      # can override with --allow-unverified (proceed despite no mapping) or
      # --no-verify (disable verification entirely).
      if [ "$ALLOW_UNVERIFIED" = true ]; then
        warn "($idx/$COUNT) no keeper mapping; proceeding anyway (--allow-unverified): $src_plan"
        _audit "VERIFY_NO_KEEPER_ALLOWED" "$src_plan" "" "$sz_kb"
      else
        warn "($idx/$COUNT) SKIP — no keeper mapping to verify against: $src_plan"
        warn "   (use --allow-unverified to move it anyway, or --no-verify to disable checks)"
        skipped_verify=$((skipped_verify+1))
        _audit "SKIPPED_NO_KEEPER" "$src_plan" "" "$sz_kb"
        continue
      fi
    fi
  fi

  if [ "$DELETE_METADATA" = true ] && printf '%s\n' "$src_real" | grep -Eq '/(@eaDir|\.AppleDouble)(/|$)'; then
    work "($idx/$COUNT) delete metadata: $src_real"
    if rm -rf -- "$src_real" 2>>"$LOG_FILE"; then
      removed=$((removed+1)); ok "deleted"
      _audit "DELETE_METADATA" "$src_plan" "" "$sz_kb"
    else
      warn "delete failed — see log"; fail=$((fail+1))
      _audit "DELETE_METADATA_FAILED" "$src_plan" "" "$sz_kb"
    fi
    continue
  fi
  # v1.3.20 (peer-review recheck finding #5): mirror the source directory
  # hierarchy under $DEST_ROOT rather than encoding path separators with
  # `s|/|__|g`. The old encoding was NOT reversible — `/a/b__c` and
  # `/a__b/c` both flatten to `a__b__c`, and the mv would silently
  # replace/collide with the tool still reporting success. Use the same
  # pattern as delete-duplicates.sh (v1.3.5): build the destination by
  # joining $DEST_ROOT with the source's absolute path, and disambiguate
  # collisions with `.dup{n}` rather than silent overwrite.
  if command -v safe_quarantine_destination >/dev/null 2>&1; then
    dest="$(safe_quarantine_destination "$DEST_ROOT" "$src_real" 2>/dev/null || true)"
  else
    case "$src_real" in
      /*) dest="$DEST_ROOT$src_real" ;;
      *)  dest="$DEST_ROOT/$src_real" ;;
    esac
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir"
  fi
  if [ -z "$dest" ]; then
    warn "($idx/$COUNT) quarantine containment check failed — refusing to move: $src_plan"
    fail=$((fail+1))
    _audit "QUARANTINE_PATH_REFUSED" "$src_plan" "" "$sz_kb"
    continue
  fi
  if [ -e "$dest" ]; then
    n=1
    while [ -e "${dest}.dup${n}" ]; do n=$((n+1)); done
    warn "Quarantine target exists; using ${dest}.dup${n}"
    dest="${dest}.dup${n}"
  fi
  work "($idx/$COUNT) $src_real -> $dest"
  if mv -- "$src_real" "$dest" 2>>"$LOG_FILE" && [ ! -e "$src_real" ]; then
    moved=$((moved+1)); ok "moved"
    _audit "QUARANTINED" "$src_plan" "$dest" "$sz_kb"
  else
    warn "move failed — see log"; fail=$((fail+1))
    _audit "QUARANTINE_FAILED" "$src_plan" "$dest" "$sz_kb"
  fi
done < "$PLAN_CLEAN"

info "Done. Moved: $moved  | Deleted metadata: $removed  | Skipped (changed): $skipped_verify  | Failed: $fail  | Log: $LOG_FILE"
if [ "$skipped_verify" -gt 0 ]; then
  # v1.3.13 (recheck item 9): the counter covers several skip reasons (content
  # mismatch, no keeper mapping, delete/keeper no longer a leaf), so the
  # summary must not claim they were all content mismatches. The per-folder
  # warnings above give the exact reason for each.
  warn "$skipped_verify folder(s) skipped because they changed, lost verification context, or were no longer safe to move (see warnings above for each)."
  warn "Re-run option 3 (find duplicate folders) to re-evaluate them."
fi
info "Audit record appended to: $ACTIONS_LOG"
info "Review quarantine: $DEST_ROOT"
if [ "${fail:-0}" -gt 0 ]; then
  exit 1
fi
# v1.3.28: a safety skip means the plan was not fully applied. Return a
# distinct status so the launcher and automation cannot report full success.
if [ "${skipped_verify:-0}" -gt 0 ]; then
  exit 4
fi
exit 0
