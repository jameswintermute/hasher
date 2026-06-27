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

# ── Default quarantine root for the detected host ──────────────────────
# Prints (does not export) a directory path suitable as a quarantine root
# when the user has not set QUARANTINE_DIR in hasher.conf.
#
# v1.2.4: quarantine now defaults to live ALONGSIDE the tool on every host
# ($ROOT_DIR/quarantine-DATE). Previously Synology was special-cased to a
# hardcoded /volume1/hasher/quarantine-DATE — a legacy default that predated
# installs living anywhere other than /volume1/hasher. Once the tool was
# moved (e.g. to /volume1/Tools/hasher), quarantine still went to the old
# fixed path, so a user could not find their quarantined data next to the
# tool, and the apply step depended on /volume1/hasher being writable. Making
# the quarantine install-relative removes that surprise: quarantine is always
# beside the tool that created it, on every platform. Users who genuinely want
# a fixed location can still set QUARANTINE_DIR explicitly in local/hasher.conf.
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
