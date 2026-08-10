#!/bin/bash
# Hasher — import-check.sh
# Copyright (C) 2026 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#
# Import Check: bring files from an SD card, old backup disk, DVD rip, or
# cloud export into a staging folder and find out which of them the NAS
# already has — without ever touching the NAS copy.
#
# The rule is absolute and structural: the NAS side of a match is NEVER a
# delete candidate. Not "usually", not "unless configured otherwise" — the
# plan generator below cannot emit a DEL line for a path outside
# $IMPORT_DIR, by construction (see classify_and_plan). This is the same
# design principle as the quarantine-containment work in v1.3.26: the
# safety property lives in what the code is CAPABLE of emitting, not in a
# check the operator has to trust.
#
# Design (agreed with the user before building):
#   1. Quarantine, never permanent delete — same model as every other
#      destructive path in this tool (--force-delete may be added later;
#      not in this release).
#   2. Only cross-boundary matches are auto-resolved. Two files inside the
#      import folder that duplicate EACH OTHER, or a file with no match
#      anywhere, are left alone here — "which of my own two copies do I
#      keep" is a different decision with no safe default, and bundling it
#      into "does the NAS already have this" would blur a rule that needs
#      to stay simple.
#   3. Scan scope is IMPORT_DIR only, compared against the most recent
#      complete NAS manifest — not a fresh full-NAS hash. This is what
#      makes "drop a card in, run a check" fast every time instead of
#      costing a multi-hour rescan. The staleness risk this introduces
#      (NAS file changed or vanished since that manifest was taken) is
#      absorbed by delete-duplicates.sh's existing keeper re-verification:
#      a stale match is skipped (rc=4) rather than acted on. No new safety
#      mechanism was needed because the fixed point already required by
#      v1.4.4 covers it.
#   4. Remainder handling: after discard, whatever is left in IMPORT_DIR
#      (unique files AND import-internal duplicates, not distinguished) is
#      moved into IMPORT_DIR/unique-files/ in one step, so the top level of
#      the import folder returns to empty and is ready for the next card.
#
# Usage:
#   bin/import-check.sh setup                    interactive first-time setup
#   bin/import-check.sh scan                      hash the import folder
#   bin/import-check.sh summary                   classify and report
#   bin/import-check.sh discard [--force]         generate + apply the plan
#   bin/import-check.sh dedup-internal [--force]  dedup import's own duplicates
#   bin/import-check.sh sort [--force]            move remainder to unique-files/
#
# Exit codes: 0 success, 1 hard failure, 2 invalid input/config,
#             3 missing prerequisite, 4 nothing to do (not an error)

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
BIN_DIR="$ROOT_DIR/bin"
LOCAL_DIR="$ROOT_DIR/local"
LOGS_DIR="$ROOT_DIR/logs"
HASHES_DIR="$ROOT_DIR/hashes"
VAR_DIR="$ROOT_DIR/var"

mkdir -p "$LOGS_DIR" "$HASHES_DIR" "$VAR_DIR" 2>/dev/null || true

if [ -r "$ROOT_DIR/lib/log.sh" ]; then
  # shellcheck source=../lib/log.sh
  . "$ROOT_DIR/lib/log.sh"
else
  info(){ printf '[INFO] %s\n' "$*"; }
  ok()  { printf '[OK] %s\n'   "$*"; }
  warn(){ printf '[WARN] %s\n' "$*"; }
  err() { printf '[ERR] %s\n'  "$*" >&2; }
fi
command -v log_progress_bar  >/dev/null 2>&1 || log_progress_bar()  { :; }
command -v log_progress_done >/dev/null 2>&1 || log_progress_done() { :; }

# v1.4.7: canonical_existing_path() is used by the overlap-safety check
# below. A minimal fallback is provided so a partially-updated install
# (older lib/host-detect.sh) degrades to string comparison rather than
# failing outright — the overlap check still runs, just without symlink
# resolution.
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  # shellcheck source=../lib/host-detect.sh
  . "$ROOT_DIR/lib/host-detect.sh"
fi
if ! command -v canonical_existing_path >/dev/null 2>&1; then
  canonical_existing_path() {
    [ -e "$1" ] || return 1
    if [ -d "$1" ]; then (CDPATH= cd -P -- "$1" 2>/dev/null && pwd -P)
    else printf '%s' "$1"; fi
  }
fi

# ── Config ───────────────────────────────────────────────────────────────
# import_dir is read from local/hasher.conf [import_check]. `setup` writes
# it; every other subcommand requires it to already be there — this script
# does not guess a default, because guessing wrong and hashing the wrong
# folder is exactly the kind of mistake this tool exists to prevent.
CONF="$LOCAL_DIR/hasher.conf"

read_import_dir() {
  [ -r "$CONF" ] || { printf ''; return; }
  awk '
    /^[[:space:]]*\[/ { insec = (tolower($0) ~ /\[import_check\]/); next }
    insec && /^[[:space:]]*import_dir[[:space:]]*=/ {
      sub(/^[[:space:]]*import_dir[[:space:]]*=[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$CONF" 2>/dev/null
}

write_import_dir() {
  local _dir="$1"
  mkdir -p "$LOCAL_DIR" 2>/dev/null || true
  if [ -r "$CONF" ]; then
    awk -v dir="$_dir" '
      BEGIN { in_sec = 0; wrote = 0; have_sec = 0 }
      /^[[:space:]]*\[/ {
        if (in_sec && !wrote) { print "import_dir = " dir; wrote = 1 }
        in_sec = (tolower($0) ~ /\[import_check\]/)
        if (in_sec) have_sec = 1
        print
        next
      }
      in_sec && /^[[:space:]]*import_dir[[:space:]]*=/ {
        if (!wrote) { print "import_dir = " dir; wrote = 1 }
        next
      }
      { print }
      END {
        if (in_sec && !wrote) { print "import_dir = " dir; wrote = 1 }
        if (!have_sec) { print ""; print "[import_check]"; print "import_dir = " dir }
      }
    ' "$CONF" > "${CONF}.import-tmp.$$" 2>/dev/null
  else
    {
      printf '# Local overrides — see default/hasher.conf for every available key\n\n'
      printf '[import_check]\n'
      printf 'import_dir = %s\n' "$_dir"
    } > "${CONF}.import-tmp.$$"
  fi
  mv -f -- "${CONF}.import-tmp.$$" "$CONF"
}

IMPORT_DIR="$(read_import_dir)"

# import_dir_boundary — IMPORT_DIR with exactly one trailing slash.
#
# Every prefix comparison in this script uses this, never a bare $IMPORT_DIR,
# because "$path" starting with "$IMPORT_DIR" (no slash) would false-match
# a sibling like /volume1/import-old/ against /volume1/import. This is the
# same class of bug fixed for scan-root overlap detection in hasher.sh; it
# gets its own name here so every call site is visibly using the safe form.
import_dir_boundary() {
  printf '%s/' "${IMPORT_DIR%/}"
}

# ── require_import_dir + overlap validation (v1.4.7, peer-review #1) ───────
#
# The original release relied entirely on classify_and_plan() excluding
# NAS-manifest rows found beneath the import boundary. That protects the
# DEL side correctly — a NAS-side row under IMPORT_DIR is never used as a
# keeper — but it silently assumes everything under IMPORT_DIR is
# disposable staging material. If a user ever configures import_dir to BE,
# or to overlap, a real trusted scan root (paths.txt entry), that assumption
# is false, and the consequence is worse than the reviewer's headline case:
# `discard` can physically relocate real primary NAS content out of its
# real location whenever a backup copy of the same file happens to exist
# elsewhere on the NAS — an entirely ordinary thing for a NAS user to have.
# `sort` then reorganises whatever regular NAS folder structure remains.
#
# The fix: refuse to operate at all when import_dir overlaps ANY trusted
# root, checked after canonicalising both sides (so a symlink or a `..`
# cannot be used to route around the check) and checked at the start of
# every operational subcommand — not only at setup time, since paths.txt
# and hasher.conf can both be hand-edited afterwards.
#
# require_import_dir() now performs this check unconditionally, so callers
# get it for free by calling the function they already had to call anyway.

# _canon_or_raw <path> — canonical_existing_path() if the path exists,
# otherwise the path as given. A configured root that does not currently
# exist (unmounted disk, typo) cannot be canonicalised, but it still needs
# to participate in string-prefix overlap comparison rather than silently
# dropping out of the check.
_canon_or_raw() {
  local _p
  _p="$(canonical_existing_path "$1" 2>/dev/null)" || _p=""
  [ -n "$_p" ] && printf '%s' "$_p" || printf '%s' "${1%/}"
}

# _paths_overlap <a> <b> — true if a==b, a is inside b, or b is inside a.
# Both arguments are expected already canonicalised; boundary comparison
# always adds exactly one trailing slash, for the same reason
# import_dir_boundary() does — a bare prefix match would let
# /volume1/import-archive false-collide with /volume1/import.
_paths_overlap() {
  local _a="${1%/}" _b="${2%/}"
  [ "$_a" = "$_b" ] && return 0
  case "${_b}/" in "${_a}/"*) return 0 ;; esac
  case "${_a}/" in "${_b}/"*) return 0 ;; esac
  return 1
}

# validate_import_isolation — refuse (exit 2) if IMPORT_DIR overlaps any
# line in local/paths.txt. Called by require_import_dir(), so every
# subcommand gets this for free.
validate_import_isolation() {
  local _pf="$LOCAL_DIR/paths.txt"
  [ -r "$_pf" ] || return 0

  local _import_canon
  _import_canon="$(_canon_or_raw "$IMPORT_DIR")"

  local _line _root_canon
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in \#*|"") continue ;; esac
    _root_canon="$(_canon_or_raw "$_line")"
    if _paths_overlap "$_import_canon" "$_root_canon"; then
      err "Import Check cannot use this folder."
      err ""
      err "The import staging folder must be separate from every trusted NAS scan root."
      err ""
      err "Import folder:"
      err "  $IMPORT_DIR"
      err "Conflicting NAS root (from local/paths.txt):"
      err "  $_line"
      err ""
      err "No files have been touched. Fix local/hasher.conf or local/paths.txt, then retry."
      exit 2
    fi
  done < "$_pf"
  return 0
}

require_import_dir() {
  if [ -z "${IMPORT_DIR:-}" ]; then
    err "No import folder configured."
    info "Run: bin/import-check.sh setup"
    exit 2
  fi
  if [ ! -d "$IMPORT_DIR" ]; then
    err "Configured import folder does not exist: $IMPORT_DIR"
    info "Run: bin/import-check.sh setup"
    exit 2
  fi
  # v1.4.7: re-checked on every call, not just at setup time, because
  # paths.txt and hasher.conf are both plain text files a user can and
  # will hand-edit after the fact.
  validate_import_isolation
}

# ── latest_nas_manifest — most recent COMPLETE hasher-*.csv ────────────────
# Mirrors launcher.sh's latest_hashes_csv (v1.4.4): newest-first, first one
# with a data row wins, header-only and partial-hasher-* manifests are
# skipped. Kept as a separate implementation deliberately — this script has
# no dependency on launcher.sh, and duplicating a few lines is cheaper than
# introducing a cross-file coupling for it.
latest_nas_manifest() {
  local _files=() _f _i
  for _f in "$HASHES_DIR"/hasher-*.csv; do
    [ -e "$_f" ] || continue
    _files[${#_files[@]}]="$_f"
  done
  _i=$(( ${#_files[@]} - 1 ))
  while [ "$_i" -ge 0 ]; do
    if [ -r "${_files[$_i]}" ] && \
       [ "$(head -n 2 "${_files[$_i]}" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ]; then
      printf '%s' "${_files[$_i]}"
      return 0
    fi
    _i=$(( _i - 1 ))
  done
  printf ''
}

# ── Subcommands ──────────────────────────────────────────────────────────

cmd_setup() {
  echo
  printf 'Import Check setup\n'
  echo "This creates a staging folder for files coming from an SD card, old"
  echo "backup disk, DVD, or cloud export. Files placed here are checked"
  echo "against your NAS — anything already on the NAS is quarantined FROM"
  echo "THIS FOLDER ONLY. The NAS copy is never touched, moved, or replaced."
  echo
  echo "This folder must be kept SEPARATE from your NAS scan roots"
  echo "(local/paths.txt) — it is untrusted staging material, not part of"
  echo "your normal inventory. Import Check will refuse to run against a"
  echo "folder that overlaps a trusted root."
  echo

  # Best-effort friendlier default: sibling of the install directory.
  local _default
  _default="$(cd -- "$ROOT_DIR/.." 2>/dev/null && pwd -P)/import"
  [ -n "${IMPORT_DIR:-}" ] && _default="$IMPORT_DIR"

  printf 'Import folder path [%s]: ' "$_default"
  local _in
  read -r _in || _in=""
  local _dir="${_in:-$_default}"

  if [ ! -d "$_dir" ]; then
    mkdir -p "$_dir" 2>/dev/null || { err "Could not create $_dir"; exit 1; }
    ok "Created $_dir"
  else
    info "$_dir already exists — using it."
  fi

  # v1.4.10 (peer review finding #2): detect and offer to fix a LEGACY
  # configuration (this exact folder still listed in paths.txt from a
  # pre-v1.4.7 install) BEFORE running the general overlap check below.
  #
  # The original ordering ran the overlap check first, which refused
  # unconditionally the moment it found this exact entry in paths.txt --
  # so the migration offer a few lines further down could NEVER be
  # reached by the very users it existed to help: a v1.4.6 install that
  # had added import_dir to paths.txt (the old, pre-v1.4.7 behaviour) hit
  # "This folder overlaps a trusted NAS scan root and cannot be used" and
  # setup simply refused, with no path forward.
  #
  # Regression caught by the test suite immediately after this was first
  # written: a bare "is $_dir an exact line in paths.txt" test cannot
  # distinguish a genuine legacy-migration case from a user setting up
  # Import Check for the FIRST time who happens to type in a path that is
  # ALSO a real, currently-used NAS scan root -- both look identical from
  # that one signal alone, and the latter is exactly the unsafe
  # configuration the overlap check exists to catch. The correct
  # distinguishing signal is whether IMPORT_DIR was ALREADY configured to
  # this exact folder before this setup run started ($IMPORT_DIR here
  # still holds the pre-existing value; it is not reassigned until
  # write_import_dir further down) -- that is only true if a previous
  # setup already recorded this folder as Import Check's own, which is
  # precisely the legacy-migration case and nothing else.
  local _pf="$LOCAL_DIR/paths.txt"
  if [ -n "${IMPORT_DIR:-}" ] && [ "$IMPORT_DIR" = "$_dir" ] \
     && [ -r "$_pf" ] && grep -qxF "$_dir" "$_pf" 2>/dev/null; then
    warn "This exact folder is listed in local/paths.txt as a trusted NAS"
    warn "scan root -- likely added by an earlier version of Import Check,"
    warn "which is no longer how this works. It needs to be removed from"
    warn "there before it can be used as the import staging folder."
    printf 'Remove this entry from local/paths.txt now? [Y/n]: '
    local _reply
    read -r _reply || _reply=""
    case "$(printf '%s' "${_reply:-y}" | tr '[:upper:]' '[:lower:]')" in
      n|no)
        warn "Left in place. The overlap check below will refuse to proceed"
        warn "while it remains listed there."
        ;;
      *)
        local _tmp="${_pf}.import-tmp.$$"
        grep -vxF "$_dir" "$_pf" > "$_tmp" 2>/dev/null || : > "$_tmp"
        mv -f -- "$_tmp" "$_pf"
        ok "Removed from $_pf"
        ;;
    esac
  fi

  # v1.4.7 (peer review #1): validate BEFORE saving anything. Reuses the
  # same check every operational subcommand runs via require_import_dir(),
  # so setup and normal use can never disagree about what counts as an
  # overlap. Directly against local/paths.txt rather than through
  # IMPORT_DIR/require_import_dir(), since $_dir has not been written to
  # config yet at this point. Re-reads $_pf fresh here (rather than reusing
  # anything read above) in case the legacy-removal step above just
  # changed it -- this must see the CURRENT file, not a stale copy.
  if [ -r "$_pf" ]; then
    local _dir_canon _line _root_canon
    _dir_canon="$(_canon_or_raw "$_dir")"
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in \#*|"") continue ;; esac
      _root_canon="$(_canon_or_raw "$_line")"
      if _paths_overlap "$_dir_canon" "$_root_canon"; then
        err "This folder overlaps a trusted NAS scan root and cannot be used"
        err "as the Import Check staging folder."
        err ""
        err "Proposed import folder:"
        err "  $_dir"
        err "Conflicting NAS root (from local/paths.txt):"
        err "  $_line"
        err ""
        err "Choose a folder outside every trusted root, then run setup again."
        err "No configuration was changed."
        exit 2
      fi
    done < "$_pf"
  fi

  write_import_dir "$_dir"
  IMPORT_DIR="$_dir"
  ok "Recorded import_dir in $CONF"

  echo
  ok "Import Check is set up: $_dir"
  info "Drop files in, then run: bin/import-check.sh scan"
}

cmd_scan() {
  require_import_dir

  local _nas_csv
  _nas_csv="$(latest_nas_manifest)"
  if [ -z "$_nas_csv" ]; then
    err "No complete NAS manifest found yet."
    info "Run a full hash first (option 1), then come back and scan the import folder."
    exit 3
  fi
  info "Comparing against NAS manifest: $(basename "$_nas_csv")"

  local _script="$BIN_DIR/hasher.sh"
  [ -r "$_script" ] || { err "hasher.sh not found."; exit 3; }

  local _tag _pf _out
  _tag="$(date +'%Y-%m-%d-%H%M%S')-$$"
  _pf="$VAR_DIR/import-scan-paths.$$"
  _out="$HASHES_DIR/import-scan-$_tag.csv"
  printf '%s\n' "$IMPORT_DIR" > "$_pf"

  # v1.4.12: respect the user's configured parallel-hashing level rather
  # than silently defaulting to serial (1 job). This reads the exact same
  # var/jobs.conf the launcher's Performance settings menu ('p') writes —
  # not a separate, Import-Check-specific setting — so a level chosen
  # once applies everywhere hasher.sh is invoked, including here. Before
  # this fix, a single-folder import scan against a large small-file
  # corpus (an SD card, a Photos-library-style export) ran fully serial
  # regardless of what the operator had configured for normal full hashes,
  # which measurably matters: hasher.sh's own comment on HASH_JOBS notes
  # serial mode's per-file fork overhead dominates wall-clock on exactly
  # this kind of corpus. Same read logic as launcher.sh (head -n1, strip
  # to digits, fall back to 1 if empty/invalid/<1) so the two never
  # disagree about what "configured" means.
  local _jobs_file="$VAR_DIR/jobs.conf" _jobs=1 _j
  if [ -r "$_jobs_file" ]; then
    _j="$(head -n1 "$_jobs_file" 2>/dev/null | tr -cd '0-9')"
    if [ -n "$_j" ] && [ "$_j" -ge 1 ] 2>/dev/null; then _jobs="$_j"; fi
  fi

  info "Hashing import folder only: $IMPORT_DIR"
  [ "$_jobs" -gt 1 ] && info "Parallel hashing: $_jobs workers."
  # v1.4.7 (peer review, "other improvements"): exclude the tool's own
  # managed output folder. Without this, files sort() already moved into
  # unique-files/ get rehashed and reconsidered on every later scan —
  # harmless (they will not spuriously match anything new) but wasted work,
  # and it undermines "ready for the next card" as a real invariant.
  #
  # --no-discover: duplicate discovery over a single-folder manifest is
  # meaningless (nothing to compare against but itself) and would only cost
  # time. --no-sort: this manifest is consumed immediately below, not kept
  # for cross-run diffing, so the sort's guarantees buy nothing here.
  if ! bash "$_script" --pathfile "$_pf" --output "$_out" \
        --exclude '*/unique-files/*' --jobs "$_jobs" \
        --no-discover --no-sort; then
    rm -f -- "$_pf" 2>/dev/null || true
    err "Import folder hashing failed — see output above."
    exit 1
  fi
  rm -f -- "$_pf" 2>/dev/null || true

  if [ ! -s "$_out" ] || [ "$(head -n 2 "$_out" 2>/dev/null | wc -l | tr -d ' ')" -lt 2 ]; then
    warn "Import folder is empty — nothing to scan."
    rm -f -- "$_out" 2>/dev/null || true
    exit 4
  fi

  # Stable pointer so summary/discard/sort don't need to re-derive "the
  # scan that was just run" — mirrors the *-latest.* convention used
  # throughout the rest of the tool.
  ln -sfn -- "$(basename "$_out")" "$HASHES_DIR/import-scan-latest.csv" 2>/dev/null \
    || cp -f -- "$_out" "$HASHES_DIR/import-scan-latest.csv"

  # v1.4.7 (peer review #3): pin this scan to the exact NAS manifest it was
  # compared against. Without this, summary/discard/sort each independently
  # called latest_nas_manifest() again — so a full NAS hash completing
  # between "scan" and "discard" silently changed what discard compared
  # against, with no indication to the user that the evidence had shifted
  # since the summary they just read. The sidecar makes that impossible:
  # every downstream subcommand reads the pinned manifest from here, and
  # notices — rather than silently substitutes — if a newer one exists.
  local _meta="$HASHES_DIR/import-scan-$_tag.meta"
  {
    printf 'marker=HASHER_IMPORT_SCAN_V1\n'
    printf 'import_csv=%s\n' "$_out"
    printf 'nas_csv=%s\n' "$_nas_csv"
    printf 'import_dir=%s\n' "$IMPORT_DIR"
    printf 'created_at=%s\n' "$(date +'%Y-%m-%d %H:%M:%S')"
  } > "$_meta"
  ln -sfn -- "$(basename "$_meta")" "$HASHES_DIR/import-scan-latest.meta" 2>/dev/null \
    || cp -f -- "$_meta" "$HASHES_DIR/import-scan-latest.meta"

  ok "Import scan complete: $_out"
  info "Pinned NAS manifest: $(basename "$_nas_csv")"
  info "Next: bin/import-check.sh summary"
}

# load_verified_import_scan — v1.4.10 (peer review finding #3).
#
# Sets globals _import_csv and _nas_csv as ONE atomic unit, read from the
# import-scan-latest.meta sidecar. The previous approach independently
# resolved import-scan-latest.csv (one symlink) and scan_pinned_nas_csv()
# (a second, separate symlink) — cmd_scan publishes those two symlinks as
# two non-atomic operations, so a process killed between them could leave
# the CSV symlink pointing at a NEWER scan than the meta symlink
# describes, silently reintroducing the exact provenance mismatch the
# meta sidecar exists to prevent.
#
# Fix: the meta file is now authoritative, and the CSV path used is the
# one ITS OWN import_csv= field names — a specific, already-fully-written,
# timestamped file (never the -latest.csv symlink). That file was written
# in full by cmd_scan before either "latest" symlink was touched, so this
# is internally consistent by construction: whichever scan the meta
# symlink currently names, its own record of "the CSV that went with it"
# is always correct, even if it isn't the very latest scan by wall-clock
# time. The publish order of the two -latest symlinks in cmd_scan
# therefore no longer affects correctness for any v1.4.7+ scan — only the
# meta symlink is read by any internal consumer now.
#
# Also validates meta.import_dir against the CURRENTLY CONFIGURED
# IMPORT_DIR, catching the case where the user switched import folders
# (re-ran setup pointing elsewhere) but a stale scan's meta is still
# sitting there unrefreshed.
#
# v1.4.11 (peer review of v1.4.10): the original single condition here —
# "meta unreadable OR marker missing" — treated two different situations
# identically: a meta file that genuinely does not exist yet (a real
# pre-v1.4.7 install, upgrade continuity) versus one that EXISTS but is
# truncated, corrupted, or otherwise invalid (a crash mid-write — the meta
# is written as several separate printf calls inside one redirect, not
# one atomic write — or a user directly editing the file, plausible on a
# NAS). The second case was silently falling through to the SAME legacy
# fallback as the first: unpinned import-scan-latest.csv plus an
# independently-resolved latest_nas_manifest(), completely bypassing the
# pinning guarantee this function exists to provide. That is a full,
# silent reversion to the exact provenance problem v1.4.7/v1.4.10 fixed,
# not a smaller version of it — worth closing rather than leaving as a
# known gap. Split into two conditions: "meta does not exist at all" is
# genuine legacy compatibility (unchanged behaviour); "meta exists but
# fails validation" is now treated as corruption and refused outright,
# asking for a fresh scan rather than guessing.
#
# Returns 0 and sets _import_csv/_nas_csv on success; returns 1 with an
# error already printed on failure. Falls back to the pre-v1.4.7 two-file
# lookup only when no meta sidecar exists at all -- upgrade continuity,
# not normal use, since every v1.4.7+ scan writes one.
load_verified_import_scan() {
  _import_csv=""
  _nas_csv=""
  local _meta="$HASHES_DIR/import-scan-latest.meta"

  if [ ! -e "$_meta" ]; then
    # Genuinely no sidecar has ever been written -- a pre-v1.4.7 scan, or
    # no scan at all yet. -e rather than -r deliberately: an unreadable
    # (but present) file is NOT "no scan happened", it's "something is
    # here and cannot be trusted" -- that belongs in the corruption branch
    # below, not this one.
    _import_csv="$HASHES_DIR/import-scan-latest.csv"
    if [ ! -r "$_import_csv" ]; then
      err "No import scan found. Run: bin/import-check.sh scan"
      _import_csv=""
      return 1
    fi
    _nas_csv="$(latest_nas_manifest)"
    if [ -z "$_nas_csv" ]; then
      err "No NAS manifest found."
      return 1
    fi
    return 0
  fi

  if [ ! -r "$_meta" ] || ! grep -qxF 'marker=HASHER_IMPORT_SCAN_V1' "$_meta" 2>/dev/null; then
    err "Import scan metadata is invalid, unreadable, or incomplete"
    err "($_meta)."
    err "Run a fresh import scan before continuing:"
    err "  bin/import-check.sh scan"
    return 1
  fi

  local _meta_import_csv _meta_nas_csv _meta_import_dir
  _meta_import_csv="$(awk '/^import_csv=/{ sub(/^import_csv=/, ""); print; exit }' "$_meta")"
  _meta_nas_csv="$(awk '/^nas_csv=/{ sub(/^nas_csv=/, ""); print; exit }' "$_meta")"
  _meta_import_dir="$(awk '/^import_dir=/{ sub(/^import_dir=/, ""); print; exit }' "$_meta")"

  if [ -z "$_meta_import_csv" ] || [ ! -r "$_meta_import_csv" ]; then
    err "The recorded import scan is missing or unreadable."
    err "Run: bin/import-check.sh scan"
    return 1
  fi
  if [ -z "$_meta_nas_csv" ] || [ ! -r "$_meta_nas_csv" ]; then
    err "The NAS manifest this scan was pinned to is missing or unreadable."
    err "Run a full hash, then: bin/import-check.sh scan"
    return 1
  fi
  if [ "$_meta_import_dir" != "$IMPORT_DIR" ]; then
    err "The last scan was against a different import folder:"
    err "  scanned:   $_meta_import_dir"
    err "  currently: $IMPORT_DIR"
    err "Run: bin/import-check.sh scan"
    return 1
  fi

  _import_csv="$_meta_import_csv"
  _nas_csv="$_meta_nas_csv"
  return 0
}

# scan_pinned_nas_csv — the exact NAS manifest the current import scan was
# compared against, from the sidecar written by cmd_scan(). Falls back to
# latest_nas_manifest() only for a scan that predates v1.4.7 (no sidecar
# yet exists) — a fresh scan always gets a fresh sidecar.
#
# v1.4.10: kept only because cmd_scan's own completion message uses it to
# report the pinned manifest name it just wrote (which is always the
# freshest by definition, so the crash-window concern that motivated
# load_verified_import_scan() doesn't apply to that one call site).
# summary/discard/sort no longer call this directly -- see
# load_verified_import_scan() above.
scan_pinned_nas_csv() {
  local _meta="$HASHES_DIR/import-scan-latest.meta"
  if [ -r "$_meta" ] && grep -qxF 'marker=HASHER_IMPORT_SCAN_V1' "$_meta" 2>/dev/null; then
    # v1.4.7 bug fix: the original form `$1=""; sub(/^=/,""); print` rebuilt
    # $0 using OFS (a space) once $1 was cleared, so the result was
    # " /path/to/file" — a leading space, not the value after "=". That
    # extra space then made the path unreadable everywhere it was used.
    # sub() on the whole line, stripping only the known "key=" prefix, has
    # no such reconstruction step.
    awk '/^nas_csv=/{ sub(/^nas_csv=/, ""); print; exit }' "$_meta"
    return 0
  fi
  latest_nas_manifest
}

# warn_if_nas_manifest_newer <pinned_csv> — informational only. Tells the
# user a newer NAS inventory exists without changing which one is used;
# summary/discard/sort all act on the pinned manifest regardless, so a
# result cannot change out from under the user between viewing the summary
# and choosing to discard.
warn_if_nas_manifest_newer() {
  local _pinned="$1" _current
  _current="$(latest_nas_manifest)"
  if [ -n "$_current" ] && [ -n "$_pinned" ] && [ "$_current" != "$_pinned" ]; then
    warn "A newer NAS inventory is available ($(basename "$_current"))."
    warn "This result is pinned to the manifest from your last import scan"
    warn "($(basename "$_pinned")). Run 'scan' again to compare against the"
    warn "newer inventory, or continue — nothing changes automatically."
  fi
}

# import_scan_is_stale — v1.4.10 (peer review finding #4).
#
# True if a discard or dedup-internal action has happened since
# $_import_csv was scanned -- i.e. rows in it may no longer reflect what
# is actually on disk (files it lists may have already been quarantined).
# Originally only cmd_dedup_internal checked this (v1.4.9); discard and
# summary did not, which was inconsistent -- delete-duplicates.sh's
# keeper-verification makes a stale discard SAFE (it skips vanished
# files rather than acting on them), but the user experience was
# confusing: apparent duplicate counts that turn into a wall of skips.
# Extracted here so summary/discard/dedup-internal apply the identical
# test rather than three near-copies of the same -nt comparison.
import_scan_is_stale() {
  local _marker="$VAR_DIR/import-check-last-destructive.marker"
  [ -r "$_marker" ] && [ "$_marker" -nt "$_import_csv" ]
}

# classify_and_plan <nas_csv> <import_csv> <out_plan> <out_remainder_list>
#
# Builds a hash -> paths index from both manifests, kept as two SEPARATE
# awk associative arrays (nas_path[] and import_path[]) that are never
# merged into one pool to pick a keeper from. For every hash present in
# BOTH, emit one KEEP|nas_path|hash and one DEL|import_path|hash per import
# copy — the exact format delete-duplicates.sh already consumes, including
# its just-in-time re-verification. Hashes with import-side entries but no
# NAS-side match go to the remainder list untouched.
#
# The invariant this function exists to guarantee: every KEEP path is
# outside IMPORT_DIR and every DEL path is inside it. This is enforced
# structurally (disjoint source arrays) and then re-checked explicitly per
# candidate before a KEEP line is written, so a future edit to this
# function cannot silently violate it without the check firing.
classify_and_plan() {
  local _nas_csv="$1" _import_csv="$2" _plan="$3" _remainder="$4" _skipped="${5:-}"
  local _boundary
  _boundary="$(import_dir_boundary)"

  : > "$_plan"
  : > "$_remainder"
  [ -n "$_skipped" ] && : > "$_skipped"

  # v1.4.8: progress reporting for the classification pass. On a large
  # import (order 100k files) this awk pass genuinely takes several
  # seconds with zero prior feedback — indistinguishable from a hang,
  # the same complaint fixed for the hash and quarantine loops in v1.4.5.
  #
  # Implemented natively inside the awk script rather than via
  # lib/log.sh's log_progress_bar(), because classify_and_plan does its
  # work in a single awk process — there is no per-row return to bash to
  # call a bash function from. Deliberately does NOT show elapsed time or
  # an ETA: that needs systime(), which is not reliably available across
  # the awk variants this tool already has to support (see
  # lib/awk-detect.sh — BusyBox awk on Synology DSM has bitten this
  # project before). A moving percentage and row count is enough to show
  # the process is alive without depending on awk timing behaviour.
  #
  # TTY detection and the "how many rows total" precount both happen here
  # in bash, where they're cheap and portable, rather than inside awk.
  local _show_progress=0
  log_is_tty && _show_progress=1
  local _total_lines=0
  if [ "$_show_progress" -eq 1 ]; then
    local _n1 _n2
    _n1="$(wc -l < "$_nas_csv" 2>/dev/null | tr -d ' ')"
    _n2="$(wc -l < "$_import_csv" 2>/dev/null | tr -d ' ')"
    [ -z "$_n1" ] && _n1=0
    [ -z "$_n2" ] && _n2=0
    _total_lines=$(( _n1 + _n2 ))
  fi

  # v1.4.7 (peer review, plan-format limitation): the KEEP|path|hash /
  # DEL|path|hash format inherited from delete-duplicates.sh uses `|` as
  # its field separator with no escaping. A legal filename containing `|`
  # would silently corrupt field parsing downstream — shifting or merging
  # columns rather than failing loudly. Fixing the format itself is a
  # larger, cross-cutting change (find-duplicates.sh and
  # apply-folder-plan.sh use the same format) and is out of scope here;
  # what belongs in THIS script is refusing to ever emit a line that would
  # corrupt it. Import Check is the path most likely to encounter this in
  # practice, since it processes material from uncontrolled external
  # media rather than the NAS's own, presumably already-sane, layout.
  #
  # Any candidate path containing `|` — on either side of a match — is
  # diverted to the skipped-paths report (when the caller provides one)
  # instead of being written into the plan. The match is simply not acted
  # on; nothing unsafe is emitted.
  awk -v boundary="$_boundary" -v plan="$_plan" -v remainder="$_remainder" -v skipped="$_skipped" \
      -v show_progress="$_show_progress" -v total_lines="$_total_lines" '
    function unquote(s) {
      if (substr(s,1,1) == "\"") {
        s = substr(s, 2, length(s)-2)
        gsub(/""/, "\"", s)
      }
      return s
    }
    # draw_progress — redraw the in-place bar. Rate-limited by row count
    # rather than wall-clock time (see the comment above the awk call for
    # why): step is sized so roughly 200 redraws happen over the whole
    # run regardless of input size, which is smooth without being
    # wasteful on a very large manifest.
    function draw_progress(cur,    pct, filled, bar, i) {
      if (!show_progress || total_lines <= 0) return
      if (cur < total_lines && (cur % step) != 0) return
      pct = int(100 * cur / total_lines)
      if (pct > 100) pct = 100
      filled = int(40 * pct / 100)
      bar = ""
      for (i = 0; i < 40; i++) bar = bar (i < filled ? "#" : "-")
      printf "\r[WORK] %3d%% [%s]  %d/%d  matching import files against the NAS manifest    ", \
        pct, bar, cur, total_lines > "/dev/stderr"
    }
    BEGIN {
      step = 1
      if (total_lines > 200) step = int(total_lines / 200)
    }
    # Re-split a CSV line respecting quoted commas; sets P (path) and H (hash).
    function parse_row(line,    n, i, c, cur, inq, fields, nf) {
      nf = 0; cur = ""; inq = 0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ }
            else inq = 0
          } else cur = cur c
        } else {
          if (c == "\"") inq = 1
          else if (c == ",") { fields[++nf] = cur; cur = "" }
          else cur = cur c
        }
      }
      fields[++nf] = cur
      P = unquote(fields[1])
      H = fields[nf]   # hash is always the last column
    }
    FNR == 1 { next }  # skip header of each file
    {
      draw_progress(NR)
    }
    FNR == NR {
      # First file: NAS manifest.
      parse_row($0)
      if (index(P, boundary) == 1) next   # rows under import_dir never
                                           # count as NAS-side, even if the
                                           # import folder was included in a
                                           # full NAS hash at some point.
      nas_path[H] = nas_path[H] SUBSEP P
      next
    }
    {
      # Second file: import-only manifest. Every row here is under
      # IMPORT_DIR by construction (that is all that was scanned).
      parse_row($0)
      import_path[H] = import_path[H] SUBSEP P
    }
    END {
      # Final draw at 100%, then clear the line so whatever the caller
      # prints next (warn/info from cmd_summary etc.) starts on a fresh
      # line rather than overwriting the tail of the bar.
      if (show_progress && total_lines > 0) {
        draw_progress(total_lines)
        printf "\r%80s\r", "" > "/dev/stderr"
      }
      for (h in import_path) {
        if (h in nas_path) {
          split(nas_path[h], keepers, SUBSEP)
          keeper = ""
          for (k in keepers) {
            if (keepers[k] == "") continue
            # Structural invariant, re-checked per candidate: refuse to use
            # anything under the import boundary as a keeper even though
            # the `next` above should already have kept it out of
            # nas_path[]. Belt-and-braces, not the primary guarantee.
            if (index(keepers[k], boundary) == 1) continue
            keeper = keepers[k]
            break
          }
          if (keeper == "") {
            split(import_path[h], mm, SUBSEP)
            for (m in mm) { if (mm[m] != "") print mm[m] >> remainder }
            continue
          }
          # Pipe-character guard: if the keeper OR any DEL candidate in
          # this group contains "|", the whole group is diverted to the
          # skipped report rather than partially written — a group is one
          # unit and must not be half-emitted.
          split(import_path[h], members, SUBSEP)
          has_pipe = (index(keeper, "|") > 0)
          if (!has_pipe) {
            for (m in members) {
              if (members[m] != "" && index(members[m], "|") > 0) { has_pipe = 1; break }
            }
          }
          if (has_pipe) {
            if (skipped != "") {
              print "KEEP-CANDIDATE\t" keeper >> skipped
              for (m in members) { if (members[m] != "") print "DEL-CANDIDATE\t" members[m] >> skipped }
            }
            continue
          }
          print "KEEP|" keeper "|" h >> plan
          for (m in members) {
            if (members[m] == "") continue
            print "DEL|" members[m] "|" h >> plan
          }
        } else {
          split(import_path[h], members, SUBSEP)
          has_pipe = 0
          for (m in members) {
            if (members[m] != "" && index(members[m], "|") > 0) { has_pipe = 1; break }
          }
          if (has_pipe) {
            if (skipped != "") {
              for (m in members) { if (members[m] != "") print "REMAINDER-CANDIDATE\t" members[m] >> skipped }
            }
            continue
          }
          for (m in members) { if (members[m] != "") print members[m] >> remainder }
        }
      }
    }
  ' "$_nas_csv" "$_import_csv"
}

cmd_summary() {
  require_import_dir
  local _nas_csv _import_csv
  # v1.4.10 (peer review #3): both resolved atomically from the meta
  # sidecar — see load_verified_import_scan() for why this replaced
  # independently resolving import-scan-latest.csv and
  # scan_pinned_nas_csv().
  load_verified_import_scan || exit 3
  warn_if_nas_manifest_newer "$_nas_csv"
  # v1.4.10 (peer review #4): summary is read-only, so a stale scan is a
  # caveat, not a reason to refuse showing information -- unlike discard,
  # nothing here acts on the data. See import_scan_is_stale() for what
  # "stale" means.
  if import_scan_is_stale; then
    warn "The import folder has changed since this scan (a discard or"
    warn "dedup action ran since). These counts may not reflect the"
    warn "current contents. Run '"'"'scan'"'"' again for a current picture."
  fi

  local _plan="$VAR_DIR/import-summary-plan.$$"
  local _remainder="$VAR_DIR/import-summary-remainder.$$"
  local _skipped="$VAR_DIR/import-summary-skipped.$$"
  classify_and_plan "$_nas_csv" "$_import_csv" "$_plan" "$_remainder" "$_skipped"
  # v1.4.10 (peer review #5): capture the skipped count BEFORE deleting
  # the file, so it can be folded into "Files scanned" below. Previously
  # this count was warned about but never added to the total, so "Files
  # scanned in import" silently undercounted by however many files hit
  # the pipe-character guard -- the numbers didn't add up to what was
  # actually in the folder, with no explanation why.
  local _skipped_count=0
  if [ -s "$_skipped" ]; then
    # v1.4.10: count only DEL-CANDIDATE/REMAINDER-CANDIDATE lines — those
    # are the actual import-folder files affected. A cross-boundary match
    # also logs one KEEP-CANDIDATE line, which is the NAS-side path, not
    # an import file; counting it too overstated "files scanned in
    # import" by one for every cross-boundary pipe-match (caught by
    # comparing this summary's total against the real file count in a
    # manual test — 4 reported vs 3 actual files on disk).
    _skipped_count="$(grep -cE '^(DEL|REMAINDER)-CANDIDATE' "$_skipped" 2>/dev/null)" || true
    [ -z "$_skipped_count" ] && _skipped_count=0
    warn "$_skipped_count path(s) are part of a match involving a '|'"
    warn "character and are excluded from this summary — the plan format"
    warn "cannot represent them safely. Details: $_skipped"
  fi
  rm -f -- "$_skipped" 2>/dev/null || true

  local _del_count _remainder_count
  # grep -c exits 1 when it finds no match, EVEN THOUGH it still prints "0"
  # to stdout. Under set -e, that nonzero exit kills the script at the
  # command substitution unless explicitly tolerated — but a naive
  # "|| echo 0" fallback would tolerate it AND also fire, appending a
  # second "0" and producing "0\n0", which then breaks -eq. The correct
  # form tolerates the exit without adding output: "|| true" after the
  # substitution, not inside it.
  _del_count="$(grep -c '^DEL|' "$_plan" 2>/dev/null)" || true
  [ -z "$_del_count" ] && _del_count=0
  _remainder_count="$(wc -l < "$_remainder" 2>/dev/null | tr -d ' ')" || true
  [ -z "$_remainder_count" ] && _remainder_count=0

  echo
  printf 'Import Check Summary\n'
  printf -- '─────────────────────────────────────────────────────────\n'
  printf 'Import folder:              %s\n' "$IMPORT_DIR"
  printf 'Compared against:           %s\n' "$(basename "$_nas_csv")"
  # v1.4.10 (peer review #5): the total now includes _skipped_count, so
  # this line adds up to everything classify_and_plan actually looked at
  # -- not just the two buckets that happen to be actionable.
  printf 'Files scanned in import:    %s\n' "$(( _del_count + _remainder_count + _skipped_count ))"
  echo
  printf '  Already on your NAS:      %-6s -> safe to quarantine\n' "$_del_count"
  printf "  Remaining (hand-sort):    %-6s -> unique + import's own duplicates\n" "$_remainder_count"
  if [ "$_skipped_count" -gt 0 ]; then
    printf '  Excluded (unsafe name):   %-6s -> contains '"'"'|'"'"', see warning above\n' "$_skipped_count"
  fi
  echo

  if [ "$_del_count" -gt 0 ]; then
    info "Sample matches (first 5):"
    grep '^DEL|' "$_plan" | head -n5 | while IFS='|' read -r _tag _path _hash; do
      printf '  %s\n' "${_path#"$IMPORT_DIR"/}"
    done
  fi

  echo
  echo "   discard   - quarantine the $_del_count verified NAS duplicates"
  echo "   sort      - move the $_remainder_count remaining file(s) into unique-files/"
  echo

  rm -f -- "$_plan" "$_remainder" 2>/dev/null || true
}

cmd_discard() {
  require_import_dir
  local _force=false
  for _a in "$@"; do [ "$_a" = "--force" ] && _force=true; done

  local _nas_csv _import_csv
  load_verified_import_scan || exit 3
  warn_if_nas_manifest_newer "$_nas_csv"
  # v1.4.10 (peer review #4): discard is destructive, so -- unlike
  # summary -- a stale scan is a hard refusal here, matching what
  # dedup-internal already enforced (v1.4.9). Safe either way because
  # delete-duplicates.sh's keeper-verification would just skip vanished
  # files, but refusing up front avoids "lots of skips" confusion.
  if import_scan_is_stale; then
    err "The import folder has changed since this scan (a discard or"
    err "dedup action ran since this scan was taken). Re-scan first so"
    err "this works from current data:"
    err "  bin/import-check.sh scan"
    exit 2
  fi

  local _tag _plan
  _tag="$(date +'%Y-%m-%d-%H%M%S')-$$"
  _plan="$LOGS_DIR/import-discard-plan-$_tag.txt"
  local _remainder="$VAR_DIR/import-discard-remainder.$$"

  local _skipped="$LOGS_DIR/import-discard-skipped-$_tag.log"
  classify_and_plan "$_nas_csv" "$_import_csv" "$_plan" "$_remainder" "$_skipped"
  rm -f -- "$_remainder" 2>/dev/null || true
  if [ -s "$_skipped" ]; then
    warn "$(wc -l < "$_skipped" | tr -d ' ') path(s) are part of a match involving a '|'"
    warn "character and were excluded from this plan — the plan format cannot"
    warn "represent them safely. Details: $_skipped"
    warn "Rename the file(s) with a '|' in the name, then re-run scan/discard."
  else
    rm -f -- "$_skipped" 2>/dev/null || true
  fi

  local _del_count
  _del_count="$(grep -c '^DEL|' "$_plan" 2>/dev/null)" || true
  # grep -c always prints a count (0 on no match) and exits 1 in that case —
  # a "|| echo 0" fallback here would ALSO fire on that exit 1, appending a
  # second "0" and producing "0\n0" instead of "0", which then breaks the
  # -eq test below. grep -c needs no fallback; it already never produces
  # empty output.
  [ -z "$_del_count" ] && _del_count=0
  if [ "$_del_count" -eq 0 ]; then
    info "Nothing to quarantine — no import file matches the NAS manifest."
    rm -f -- "$_plan" 2>/dev/null || true
    exit 4
  fi

  # Belt-and-braces gate, in addition to the structural guarantee inside
  # classify_and_plan: refuse outright if any KEEP line is not strictly
  # outside the import boundary. This can only fire if the classifier
  # itself has a defect — in which case refusing beats discovering it via
  # a corrupted NAS.
  local _boundary bad
  _boundary="$(import_dir_boundary)"
  bad="$(grep '^KEEP|' "$_plan" | awk -F'|' -v b="$_boundary" 'index($2,b)==1{c++} END{print c+0}')"
  if [ "${bad:-0}" -gt 0 ]; then
    err "Refusing to proceed: $bad KEEP entry(ies) point inside the import folder."
    err "This should be impossible and indicates a defect in import-check.sh, not"
    err "your data. No files have been touched. Plan retained for diagnosis: $_plan"
    exit 1
  fi

  info "Plan written: $_plan"
  info "$_del_count file(s) in $IMPORT_DIR have a verified copy on the NAS"
  info "and will be moved to quarantine (not deleted)."
  info "0 file(s) on your NAS will be touched — structurally guaranteed:"
  info "  the import folder is confirmed isolated from every trusted NAS"
  info "  root, and every KEEP path is re-checked to be outside it."

  if ! $_force; then
    printf 'Proceed? [y/N]: '
    local _reply
    read -r _reply || _reply=""
    case "$(printf '%s' "$_reply" | tr '[:upper:]' '[:lower:]')" in
      y|yes) ;;
      *) echo "Cancelled. Plan retained: $_plan"; exit 0 ;;
    esac
  fi

  local _dd="$BIN_DIR/delete-duplicates.sh"
  [ -r "$_dd" ] || { err "delete-duplicates.sh not found."; exit 3; }

  # Reuses delete-duplicates.sh unmodified: same keeper re-verification,
  # same quarantine-not-delete, same exit codes (0 success, 1 hard failure,
  # 4 safety skips). Nothing about "this is an import-check plan" needs to
  # be known below this line.
  bash "$_dd" "$_plan"
  local _rc=$?

  # v1.4.9: mark the import-scan CSV as potentially stale, so a later
  # dedup-internal run knows to ask for a fresh scan rather than silently
  # building groups from files this discard just quarantined.
  : > "$VAR_DIR/import-check-last-destructive.marker"

  exit "$_rc"
}

# cmd_dedup_internal — v1.4.9. Deduplicate the import folder's OWN
# duplicates (two files in the import folder that match each other, not
# the NAS). This was deliberately left unautomated in v1.4.6/v1.4.7:
# "which of my own two copies do I keep" has no safe default the way
# "does the NAS already have this" does, and folding it into `discard`
# would have blurred a rule that needed to stay simple. It remains a
# SEPARATE, explicit, opt-in action here — not part of `discard` — with
# the same plan-review-then-confirm workflow as everywhere else in this
# tool. What changes in v1.4.9 is only that the action now has a menu
# entry, instead of requiring the user to run a second hasher instance
# scoped to the import folder by hand.
#
# Run AFTER `discard`, not before: if a hash group has both a NAS match
# and multiple import copies, `discard` already removes every import copy
# in that group (NAS wins over all of them, not just one). Running this
# first would waste effort deduplicating files `discard` is about to
# remove anyway. Running `discard` first also means whatever `sort` moves
# into unique-files/ afterward is genuinely unique — not "unique + our own
# duplicates" as the pre-v1.4.9 documentation had to caveat.
#
# Safety is structural, the same way `discard` is: import-scan-latest.csv
# NEVER contains a NAS path — it is a scan of IMPORT_DIR alone — so a plan
# generated from it cannot reference anything outside the import folder,
# regardless of what find-duplicates.sh's keep-strategy selects as each
# group's keeper. No overlap check is doing that work here; the manifest
# itself never had a NAS path to leak.
cmd_dedup_internal() {
  require_import_dir
  local _force=false
  for _a in "$@"; do [ "$_a" = "--force" ] && _force=true; done

  # v1.4.10: uses the same atomic loader as summary/discard/sort (peer
  # review #3), rather than resolving import-scan-latest.csv on its own —
  # this also gets it the import_dir-mismatch protection for free (if the
  # import folder was switched since the last scan, that is now caught
  # here too, not just in the other three commands). _nas_csv is set but
  # unused: dedup-internal never compares against the NAS.
  local _nas_csv _import_csv
  load_verified_import_scan || exit 3

  # v1.4.9, extracted to a shared helper in v1.4.10 (peer review #4) so
  # summary/discard/dedup-internal all apply the identical staleness test
  # rather than three near-copies of the same -nt comparison. Destructive
  # here, so this refuses (matches discard) rather than warns (matches
  # summary): a stale scan would build duplicate groups referencing files
  # discard already quarantined. delete-duplicates.sh's keeper-
  # verification (v1.4.4) would catch that safely (skip, not act), but
  # the result would be confusing -- "0 groups usable" -- rather than the
  # tool asking for what it needs up front.
  if import_scan_is_stale; then
    err "Your last import scan predates a discard or dedup action against"
    err "this folder. Re-scan first so this works from current data:"
    err "  bin/import-check.sh scan"
    exit 2
  fi

  local _fd="$BIN_DIR/find-duplicates.sh"
  [ -r "$_fd" ] || { err "find-duplicates.sh not found."; exit 3; }

  info "Checking for duplicates within the import folder itself..."
  local _tag _dupes_report _fd_log
  _tag="$(date +'%Y-%m-%d-%H%M%S')-$$"
  # v1.4.10 (peer review finding #1): find-duplicates.sh normally publishes
  # logs/duplicate-hashes-latest.txt -- the SAME pointer review-duplicates.sh,
  # auto-dedup.sh, and launch-review.sh all default to reading for the
  # NORMAL NAS duplicate workflow. Running this against the import-only
  # manifest and letting it publish unconditionally would silently replace
  # that pointer with import-only data, so a later NAS-side run with no
  # explicit --from-report would pick up the wrong report. --report-out
  # gives this run its own namespace; --no-publish-latest keeps the NAS
  # pointers untouched entirely. Import Check's own review index is not
  # needed here, so --no-review-index skips building one.
  _dupes_report="$LOGS_DIR/import-internal-duplicates-$_tag.txt"
  _fd_log="$VAR_DIR/import-internal-fd.$$.log"
  if ! bash "$_fd" --input "$_import_csv" --mode bulk --keep-strategy shortest-path \
        --report-out "$_dupes_report" --no-publish-latest --no-review-index \
        > "$_fd_log" 2>&1; then
    err "Could not check for internal duplicates -- see output below."
    cat "$_fd_log" >&2
    rm -f -- "$_fd_log" 2>/dev/null || true
    exit 1
  fi
  rm -f -- "$_fd_log" 2>/dev/null || true

  if ! grep -qxF '# HASHER_VERIFIED_DUPLICATE_REPORT v1' "$_dupes_report" 2>/dev/null; then
    info "No duplicates found within the import folder."
    exit 4
  fi

  local _ad="$BIN_DIR/auto-dedup.sh"
  [ -r "$_ad" ] || { err "auto-dedup.sh not found."; exit 3; }

  # v1.4.9: auto-dedup.sh only ever WRITES a plan -- it never applies one.
  # Its own --force flag only skips ITS confirmation prompt for writing
  # the plan, not for acting on it. Applying is a separate, explicit call
  # to delete-duplicates.sh below, exactly mirroring how cmd_discard
  # already reuses delete-duplicates.sh unmodified.
  local _plan_out="$LOGS_DIR/import-internal-dedup-plan-$_tag.txt"
  if ! bash "$_ad" --from-report "$_dupes_report" --plan-out "$_plan_out" \
        --keep shortest-path --force > "$VAR_DIR/import-internal-ad.$$.log" 2>&1; then
    err "Could not build a dedup plan -- see output below."
    cat "$VAR_DIR/import-internal-ad.$$.log" >&2
    rm -f -- "$VAR_DIR/import-internal-ad.$$.log" 2>/dev/null || true
    exit 1
  fi
  rm -f -- "$VAR_DIR/import-internal-ad.$$.log" 2>/dev/null || true

  local _del_count
  _del_count="$(grep -c '^DEL|' "$_plan_out" 2>/dev/null)" || true
  [ -z "$_del_count" ] && _del_count=0
  if [ "$_del_count" -eq 0 ]; then
    info "Nothing to deduplicate -- every file in the import folder is unique."
    exit 4
  fi

  info "Plan written: $_plan_out"
  info "$_del_count file(s) inside the import folder duplicate ANOTHER file"
  info "also inside the import folder (not the NAS). Keeping the shortest"
  info "path in each group; the rest will be moved to quarantine."

  if ! $_force; then
    printf 'Proceed? [y/N]: '
    local _reply
    read -r _reply || _reply=""
    case "$(printf '%s' "$_reply" | tr '[:upper:]' '[:lower:]')" in
      y|yes) ;;
      *) echo "Cancelled. Plan retained: $_plan_out"; exit 0 ;;
    esac
  fi

  local _dd="$BIN_DIR/delete-duplicates.sh"
  [ -r "$_dd" ] || { err "delete-duplicates.sh not found."; exit 3; }

  bash "$_dd" "$_plan_out"
  local _rc=$?

  # Mark this destructive action so the next dedup-internal or discard run
  # knows the import-scan CSV it's about to reuse may now be stale.
  : > "$VAR_DIR/import-check-last-destructive.marker"

  exit "$_rc"
}


cmd_sort() {
  require_import_dir
  local _force=false
  for _a in "$@"; do [ "$_a" = "--force" ] && _force=true; done

  local _nas_csv _import_csv
  load_verified_import_scan || exit 3
  warn_if_nas_manifest_newer "$_nas_csv"

  local _plan="$VAR_DIR/import-sort-plan.$$"
  local _remainder="$VAR_DIR/import-sort-remainder.$$"
  local _skipped="$VAR_DIR/import-sort-skipped.$$"
  classify_and_plan "$_nas_csv" "$_import_csv" "$_plan" "$_remainder" "$_skipped"
  rm -f -- "$_plan" 2>/dev/null || true
  if [ -s "$_skipped" ]; then
    warn "$(wc -l < "$_skipped" | tr -d ' ') path(s) are part of a match involving a '|'"
    warn "character and are excluded from sort. Move these files by hand —"
    warn "the plan format cannot represent them safely."
  fi
  rm -f -- "$_skipped" 2>/dev/null || true

  local _n
  _n="$(wc -l < "$_remainder" 2>/dev/null | tr -d ' ')" || true
  [ -z "$_n" ] && _n=0
  if [ "$_n" -eq 0 ]; then
    info "Nothing to sort — no remainder files."
    rm -f -- "$_remainder" 2>/dev/null || true
    exit 4
  fi

  local _dest="${IMPORT_DIR%/}/unique-files"

  if ! $_force; then
    printf '%s file(s) will move into %s\n' "$_n" "$_dest"
    printf 'Proceed? [y/N]: '
    local _reply
    read -r _reply || _reply=""
    case "$(printf '%s' "$_reply" | tr '[:upper:]' '[:lower:]')" in
      y|yes) ;;
      *) echo "Cancelled."; rm -f -- "$_remainder" 2>/dev/null || true; exit 0 ;;
    esac
  fi

  mkdir -p "$_dest" 2>/dev/null || { err "Could not create $_dest"; exit 1; }

  local _moved=0 _fail=0 _seen=0 _started
  _started="$(date +%s)"
  while IFS= read -r _src || [ -n "$_src" ]; do
    [ -z "$_src" ] && continue
    # Never move something already inside unique-files/ (e.g. a re-run
    # after a partial sort).
    case "$_src" in "$_dest"/*) continue ;; esac
    _seen=$(( _seen + 1 ))
    log_progress_bar "SORT" "$_seen" "$_n" "$_started"

    [ -e "$_src" ] || continue
    if [ -L "$_src" ]; then
      warn "Skipping symlink: $_src"
      continue
    fi
    local _rel _dst _ddir
    _rel="${_src#"$IMPORT_DIR"/}"
    _dst="$_dest/$_rel"
    _ddir="$(dirname -- "$_dst")"
    mkdir -p "$_ddir" 2>/dev/null || true
    if [ -e "$_dst" ]; then
      local _n2=1
      while [ -e "${_dst}.dup${_n2}" ]; do _n2=$(( _n2 + 1 )); done
      _dst="${_dst}.dup${_n2}"
    fi
    if mv -- "$_src" "$_dst" 2>/dev/null; then
      _moved=$(( _moved + 1 ))
    else
      warn "Failed to move: $_src"
      _fail=$(( _fail + 1 ))
    fi
  done < "$_remainder"
  log_progress_done
  rm -f -- "$_remainder" 2>/dev/null || true

  ok "Moved $_moved file(s) into $_dest"
  [ "$_fail" -gt 0 ] && warn "$_fail file(s) could not be moved — see warnings above."

  # Report whether the top level is now clear, since that is what makes
  # repeat use ("drop the next card in") frictionless. unique-files/ itself
  # is expected to remain — the count above already excludes it, but the
  # message needs to say so explicitly or "1 item(s) remain" reads as a
  # problem when it is exactly the intended outcome.
  local _leftover
  _leftover="$(find "$IMPORT_DIR" -mindepth 1 -maxdepth 1 -not -name 'unique-files' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${_leftover:-0}" -eq 0 ]; then
    ok "$IMPORT_DIR is clear at the top level — ready for the next card."
  else
    info "$_leftover other item(s) remain at the top level of $IMPORT_DIR (outside unique-files/)."
  fi

  [ "$_fail" -gt 0 ] && exit 1
  exit 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────
SUBCOMMAND="${1:-}"
[ $# -gt 0 ] && shift || true

# ── Lock (v1.4.7, "other worthwhile improvements") ──────────────────────
# Prevents e.g. `scan` in one terminal racing `discard` in another against
# the same import folder — scan could rewrite import-scan-latest.csv out
# from under a discard that has already read the old one, or two discards
# could both act on the same plan. The main hasher.sh lock in var/ does not
# cover this: import-check.sh is a separate, independently-runnable tool.
#
# mkdir is atomic, same mechanism hasher.sh itself uses for its own lock.
# Held only for the subcommands that read or write shared state (scan,
# discard, sort); summary is read-only and setup is interactive with its
# own confirmation prompts, so contention there is low-consequence and
# serialising it would only slow down normal use.
IC_LOCK="$VAR_DIR/import-check.lock"
_ic_lock_acquired=0
_ic_release_lock() {
  if [ "$_ic_lock_acquired" -eq 1 ]; then
    rmdir "$IC_LOCK" 2>/dev/null || true
    _ic_lock_acquired=0
  fi
}
_ic_acquire_lock() {
  if mkdir "$IC_LOCK" 2>/dev/null; then
    _ic_lock_acquired=1
    trap _ic_release_lock EXIT INT TERM
    return 0
  fi
  err "Another import-check operation appears to be running."
  err "If this is stale (a previous run crashed), remove: $IC_LOCK"
  exit 2
}

case "$SUBCOMMAND" in
  setup)    cmd_setup "$@" ;;
  scan)     _ic_acquire_lock; cmd_scan "$@";    _ic_release_lock ;;
  summary)  cmd_summary "$@" ;;
  discard)  _ic_acquire_lock; cmd_discard "$@"; _ic_release_lock ;;
  dedup-internal) _ic_acquire_lock; cmd_dedup_internal "$@"; _ic_release_lock ;;
  sort)     _ic_acquire_lock; cmd_sort "$@";    _ic_release_lock ;;
  ""|help|-h|--help)
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    err "Unknown subcommand: $SUBCOMMAND"
    info "Usage: bin/import-check.sh {setup|scan|summary|discard|dedup-internal|sort}"
    exit 2
    ;;
esac
