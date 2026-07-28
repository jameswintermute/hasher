# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.
#
# host-detect.sh — sourceable helper to identify the runtime environment
# and provide host-appropriate defaults.
#
# Usage (from any hasher script):
#   . "$ROOT_DIR/lib/host-detect.sh"
#   detect_host                          # sets HASHER_HOST (synology|macos|linux|unknown)
#   default_quarantine_root              # prints a sensible quarantine root for $HASHER_HOST
#   host_default_excludes                # prints one exclude pattern per line for $HASHER_HOST
#   host_default_scan_root               # prints a fallback scan root if no paths.txt
#
# This file is intentionally POSIX-sh-safe (no bash-4 syntax, no [[ ]],
# no arrays). It must source cleanly under Synology DSM bash 3.2 and
# macOS /bin/bash 3.2 alike.

# ── HASHER_HOST detection ──────────────────────────────────────────────
# Sets the global HASHER_HOST to one of: synology, macos, linux, unknown.
# Idempotent — safe to call repeatedly.
detect_host() {
  if [ -n "${HASHER_HOST:-}" ]; then
    return 0
  fi

  # Synology: /etc/synoinfo.conf is present on all DSM versions.
  # The /etc/DSM directory exists on DSM 7+; either is sufficient.
  if [ -f /etc/synoinfo.conf ] || [ -d /etc/DSM ]; then
    HASHER_HOST="synology"
    export HASHER_HOST
    return 0
  fi

  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) HASHER_HOST="macos" ;;
    Linux)  HASHER_HOST="linux" ;;
    *)      HASHER_HOST="unknown" ;;
  esac
  export HASHER_HOST
}

# ── Bash version detection ─────────────────────────────────────────────
# Captures the running Bash version so any script can branch on it, and so
# the launcher/self-test can warn clearly. Important nuance: the platform
# most likely to give you an OLD bash is macOS, NOT Synology — Apple ships
# Bash 3.2.57 as /bin/bash (frozen since 2007 to avoid GPLv3), while many
# Synology DSM builds carry a newer 4.x bash (and BusyBox ash separately).
# So "ancient bash" here usually means a Mac, which is exactly why this
# project holds a 3.2 baseline.
#
# Sets globals:
#   HASHER_BASH_MAJOR, HASHER_BASH_MINOR  (integers; 0 if not bash)
#   HASHER_BASH_VERSION                   (e.g. "3.2.57" or "unknown")
# Idempotent.
detect_bash_version() {
  if [ -n "${HASHER_BASH_VERSION:-}" ]; then
    return 0
  fi
  if [ -n "${BASH_VERSINFO:-}" ]; then
    HASHER_BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
    HASHER_BASH_MINOR="${BASH_VERSINFO[1]:-0}"
    HASHER_BASH_VERSION="${BASH_VERSION:-unknown}"
  else
    # Not running under bash (e.g. sourced from BusyBox ash). Best-effort:
    # ask the bash binary on PATH, if any.
    HASHER_BASH_MAJOR=0; HASHER_BASH_MINOR=0; HASHER_BASH_VERSION="unknown"
    if command -v bash >/dev/null 2>&1; then
      _bv="$(bash -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]} ${BASH_VERSION}"' 2>/dev/null)"
      if [ -n "$_bv" ]; then
        HASHER_BASH_MAJOR="$(printf '%s\n' "$_bv" | awk '{print $1+0}')"
        HASHER_BASH_MINOR="$(printf '%s\n' "$_bv" | awk '{print $2+0}')"
        HASHER_BASH_VERSION="$(printf '%s\n' "$_bv" | awk '{print $3}')"
      fi
    fi
  fi
  export HASHER_BASH_MAJOR HASHER_BASH_MINOR HASHER_BASH_VERSION
}

# bash_at_least MAJOR MINOR  → returns 0 (true) if the running bash is >= that.
# Use to guard optional features:  if bash_at_least 4 0; then ...fast path... fi
bash_at_least() {
  detect_bash_version
  _need_maj="${1:-0}"; _need_min="${2:-0}"
  if [ "${HASHER_BASH_MAJOR:-0}" -gt "$_need_maj" ]; then
    return 0
  elif [ "${HASHER_BASH_MAJOR:-0}" -eq "$_need_maj" ] && [ "${HASHER_BASH_MINOR:-0}" -ge "$_need_min" ]; then
    return 0
  fi
  return 1
}

# require_bash MAJOR MINOR [feature-name]
# For a code path that genuinely needs a newer bash: if the running bash is
# too old, print a clear, platform-aware error and return non-zero so the
# caller can refuse gracefully instead of failing with a cryptic syntax error.
require_bash() {
  _rmaj="${1:-4}"; _rmin="${2:-0}"; _feat="${3:-this feature}"
  if bash_at_least "$_rmaj" "$_rmin"; then
    return 0
  fi
  detect_host
  _hint=""
  case "${HASHER_HOST:-}" in
    macos) _hint=" (macOS ships Bash 3.2 as /bin/bash; install a newer bash via Homebrew — 'brew install bash' — and run hasher with it)";;
  esac
  printf '[ERR ] %s requires Bash %s.%s or newer; this is Bash %s.%s%s\n' \
    "$_feat" "$_rmaj" "$_rmin" "${HASHER_BASH_MAJOR:-0}" "${HASHER_BASH_MINOR:-0}" "$_hint" >&2
  return 1
}

# ── Default quarantine root for the detected host ──────────────────────
# Prints (does not export) a directory path suitable as a quarantine root
# when the user has not set QUARANTINE_DIR in hasher.conf.
#
# Synology: previously special-cased to /volume1/hasher/quarantine-DATE.
# v1.3.2: now install-relative on EVERY host ($ROOT_DIR/quarantine-DATE), so
# quarantine always lives beside the tool — even when the install was moved
# out of /volume1/hasher (e.g. to /volume1/Tools/hasher). The Synology
# special-case was a legacy default that silently sent quarantine to the old
# fixed path after a move; this removes that surprise. Users who want a fixed
# location can still set QUARANTINE_DIR in local/hasher.conf.
#
# NOTE: This is the SOURCED copy. The v1.2.4 fix was mistakenly applied only to
# a now-deleted bin/host-detect.sh duplicate, so it never took effect until
# v1.3.2 corrected it here, in the file every script actually loads.
#
# Requires ROOT_DIR to be set by the caller.
default_quarantine_root() {
  detect_host
  date_tag="$(date +%F)"
  printf '%s/quarantine-%s\n' "${ROOT_DIR:-.}" "$date_tag"
}

# ── Default exclude patterns for the detected host ─────────────────────
# Prints one literal-substring exclude pattern per line, suitable for
# feeding to `--exclude PATTERN` on hasher.sh. These are layered ON TOP
# of whatever the user has in local/excludes.txt.
host_default_excludes() {
  detect_host
  # Common to every host
  printf '%s\n' '#recycle' '@Recycle' '@RecycleBin'

  case "$HASHER_HOST" in
    synology)
      printf '%s\n' '@eaDir' '@tmp' '@SynoFinder-log' '@SynoResource'
      ;;
    macos)
      # Spotlight, Time Machine, Trash, FSEvents, document revisions, etc.
      # These dirs can hold tens of thousands of small ephemeral files.
      # FIX (v1.1.10): removed 'Icon\r' — the launcher passes excludes as
      # literal substrings to awk index() match, which can't represent a
      # carriage-return byte cleanly. Custom-folder Icon files are rare
      # enough that hashing them is harmless; better to leave them in
      # the catalog than emit a pattern that just adds noise.
      printf '%s\n' \
        '.Spotlight-V100' \
        '.Trashes' \
        '.fseventsd' \
        '.DocumentRevisions-V100' \
        '.TemporaryItems' \
        '.DS_Store' \
        '.AppleDouble' \
        '.AppleDB' \
        '.AppleDesktop'
      ;;
    linux)
      # Generic Linux: nothing OS-specific worth force-excluding.
      # Users can add their own in local/excludes.txt.
      :
      ;;
  esac
}

# ── Host-specific find-prune arguments ─────────────────────────────────
# Prints shell-safe `-name PATTERN -prune -o` fragments for the current
# host, ONE ARG PER LINE. Callers read them into an array and inject
# BEFORE the primary expression:
#
#   mapfile -t prune_args < <(host_find_prune_args)
#   find "$path" "${prune_args[@]}" -type f -print0
#
# The prune fragment for each dir is `( -name X -prune )` OR'd against the
# rest of the expression. Any directory whose basename matches will be
# skipped WITHOUT find descending into it — so BSD find no longer returns
# exit 1 for volumes containing .Spotlight-V100 / .DocumentRevisions-V100
# (Mary's Mac reproduction). This is the belt-and-braces companion to
# host_default_excludes: prune stops us LOOKING at the dirs; excludes
# stop any leaked entries reaching the CSV.
#
# Empty output on hosts with no special dirs is fine — callers get an
# empty array and find behaves normally.
#
# v1.3.20 (Mary's Mac Tahoe report): added to fix the "BSD find exit 1
# on external volumes" class of failure at source.
host_find_prune_args() {
  detect_host
  local d
  case "$HASHER_HOST" in
    macos)
      # Same dirs as host_default_excludes emits for macos, but PRUNE'd
      # so find never descends. Kept as a static list rather than parsed
      # from host_default_excludes so that a future glob-in-excludes
      # (e.g. `*.part`) doesn't accidentally become a prune expression —
      # prune only takes literal names.
      for d in .Spotlight-V100 .Trashes .fseventsd \
               .DocumentRevisions-V100 .TemporaryItems \
               com.apple.TimeMachine.localsnapshots ; do
        printf -- '(\n-name\n%s\n-type\nd\n-prune\n)\n-o\n' "$d"
      done
      ;;
    synology)
      # @eaDir is present in every folder Synology has indexed for search;
      # pruning it saves a LOT of walk time on media volumes.
      for d in @eaDir '#recycle' @tmp @SynoResource ; do
        printf -- '(\n-name\n%s\n-type\nd\n-prune\n)\n-o\n' "$d"
      done
      ;;
    linux|*)
      : ;;
  esac
}

# ── Default scan root if no paths.txt is configured ────────────────────
# Returns a directory path appropriate to start scanning when the user
# has not provided a paths file. Used by delete-zero-length.sh --scan
# and any future "first run" helpers.
host_default_scan_root() {
  detect_host
  case "$HASHER_HOST" in
    synology) printf '/volume1\n' ;;
    macos)    printf '%s\n' "${HOME:-/Users}" ;;
    linux)    printf '%s\n' "${HOME:-/home}" ;;
    *)        printf '/\n' ;;
  esac
}

# ── Pretty label for the launcher header ───────────────────────────────
host_pretty_label() {
  detect_host
  case "$HASHER_HOST" in
    synology) printf 'Synology DSM\n' ;;
    macos)    printf 'macOS\n' ;;
    linux)    printf 'Linux\n' ;;
    *)        printf 'unknown host\n' ;;
  esac
}

# ── Shared quarantine resolver (v1.3.6) ────────────────────────────────
# Single source of truth for where quarantine lives, used by ALL
# quarantine-capable tools (delete-duplicates.sh, apply-folder-plan.sh,
# delete-zero-length.sh) so they never diverge. Resolution order:
#   1. QUARANTINE_DIR set in local/hasher.conf  (user override; preferred)
#   2. QUARANTINE_DIR set in default/hasher.conf
#   3. QUARANTINE_DIR exported in the environment
#   4. default_quarantine_root()  ($ROOT_DIR/quarantine-DATE, install-relative)
# A literal $(date +%F) inside a conf value is expanded. Requires ROOT_DIR set.
resolve_quarantine_dir() {
  _rqd_raw=""
  if [ -f "${ROOT_DIR:-.}/local/hasher.conf" ]; then
    _rqd_raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "${ROOT_DIR}/local/hasher.conf" | tail -n1 || true)"
  fi
  if [ -z "$_rqd_raw" ] && [ -f "${ROOT_DIR:-.}/default/hasher.conf" ]; then
    _rqd_raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "${ROOT_DIR}/default/hasher.conf" | tail -n1 || true)"
  fi
  _rqd_val="$(printf '%s\n' "$_rqd_raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')"
  # environment override only if conf did not provide one
  if [ -z "$_rqd_val" ] && [ -n "${QUARANTINE_DIR:-}" ]; then
    _rqd_val="$QUARANTINE_DIR"
  fi
  if [ -z "$_rqd_val" ]; then
    _rqd_val="$(default_quarantine_root)"
  else
    # expand a literal $(date +%F) if present in the conf value
    _today="$(date +%F)"
    _rqd_val="$(printf '%s\n' "$_rqd_val" | sed "s/\\\$(date +%F)/$_today/g")"
  fi
  printf '%s\n' "$_rqd_val"
}

# ── Canonical-path and quarantine containment helpers (v1.3.26) ──────
#
# These helpers are shared by the hasher and every quarantine-capable tool.
# They deliberately avoid making `realpath` a hard dependency: Synology DSM,
# macOS and generic Linux expose slightly different utility sets.

# canonical_existing_path PATH
# Print an absolute, physical path for an entry that currently exists.
# Directory symlinks and `.` / `..` components are resolved.  The caller can
# still reject a final-component symlink before invoking this helper when that
# distinction matters (hasher.sh does so).
canonical_existing_path() {
  [ "$#" -eq 1 ] || return 2
  _cep_input=$1
  [ -e "$_cep_input" ] || [ -L "$_cep_input" ] || return 1

  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$_cep_input" 2>/dev/null && return 0
    realpath "$_cep_input" 2>/dev/null && return 0
  fi

  if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readlink -f -- "$_cep_input" 2>/dev/null && return 0
    readlink -f "$_cep_input" 2>/dev/null && return 0
  fi

  if [ -d "$_cep_input" ]; then
    (CDPATH= cd -P -- "$_cep_input" 2>/dev/null && pwd -P)
    return $?
  fi

  _cep_dir=$(dirname -- "$_cep_input" 2>/dev/null || dirname "$_cep_input") || return 1
  _cep_base=$(basename -- "$_cep_input" 2>/dev/null || basename "$_cep_input") || return 1
  _cep_real_dir=$(CDPATH= cd -P -- "$_cep_dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${_cep_real_dir%/}" "$_cep_base"
}

# path_is_within CHILD ROOT
# Return success when CHILD is ROOT itself or lies below ROOT.  Both arguments
# must already be absolute/canonical; this is a component-aware prefix test.
path_is_within() {
  [ "$#" -eq 2 ] || return 2
  _piw_child=$1
  _piw_root=$2
  if [ "$_piw_root" = "/" ]; then
    case "$_piw_child" in /*) return 0 ;; *) return 1 ;; esac
  fi
  case "$_piw_child" in
    "$_piw_root"|"$_piw_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# safe_quarantine_destination ROOT SOURCE
# Create SOURCE's mirrored parent hierarchy below ROOT and print a destination
# that is proven to remain inside ROOT after physical-path resolution.  This
# prevents raw manifest spellings containing `..` — or a symlink planted in
# the quarantine hierarchy — from escaping the configured quarantine root.
safe_quarantine_destination() {
  [ "$#" -eq 2 ] || return 2
  _sqd_root=$1
  _sqd_source=$2

  mkdir -p -- "$_sqd_root" 2>/dev/null || mkdir -p "$_sqd_root" || return 1
  _sqd_root_real=$(canonical_existing_path "$_sqd_root") || return 1
  _sqd_source_real=$(canonical_existing_path "$_sqd_source") || return 1

  # Refuse recursive/self-quarantine layouts.
  path_is_within "$_sqd_source_real" "$_sqd_root_real" && return 3
  path_is_within "$_sqd_root_real" "$_sqd_source_real" && return 3

  _sqd_rel=${_sqd_source_real#/}
  _sqd_candidate="${_sqd_root_real%/}/$_sqd_rel"
  _sqd_parent=$(dirname -- "$_sqd_candidate" 2>/dev/null || dirname "$_sqd_candidate") || return 1
  _sqd_base=$(basename -- "$_sqd_source_real" 2>/dev/null || basename "$_sqd_source_real") || return 1

  mkdir -p -- "$_sqd_parent" 2>/dev/null || mkdir -p "$_sqd_parent" || return 1
  _sqd_parent_real=$(canonical_existing_path "$_sqd_parent") || return 1
  path_is_within "$_sqd_parent_real" "$_sqd_root_real" || return 4

  printf '%s/%s\n' "${_sqd_parent_real%/}" "$_sqd_base"
}
