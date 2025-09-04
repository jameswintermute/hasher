#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# bin/lib_paths.sh — centralise app layout discovery (Splunk-style)
# Resolves paths whether scripts are called from bin/ or elsewhere.

# Resolve APP_HOME (repo root)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

# Core dirs
BIN_DIR="$APP_HOME/bin"
DEFAULT_DIR="${DEFAULT_DIR:-$APP_HOME/default}"
LOCAL_DIR="${LOCAL_DIR:-$APP_HOME/local}"
LOG_DIR="${LOG_DIR:-$APP_HOME/logs}"
HASHES_DIR="${HASHES_DIR:-$APP_HOME/hashes}"   # <- was lookups/, now hashes/
VAR_DIR="${VAR_DIR:-$APP_HOME/var}"
ZERO_DIR="${ZERO_DIR:-$VAR_DIR/zero-length}"
LOW_DIR="${LOW_DIR:-$VAR_DIR/low-value}"
QUAR_DIR="${QUAR_DIR:-$VAR_DIR/quarantine}"

# Back-compat fallbacks if old layout exists
[ -d "$APP_HOME/zero-length" ] && ZERO_DIR="$APP_HOME/zero-length"
[ -d "$APP_HOME/low-value" ]   && LOW_DIR="$APP_HOME/low-value"

# Config overlay (local overrides default)
CONF_DEFAULT="$DEFAULT_DIR/hasher.conf"
CONF_LOCAL="$LOCAL_DIR/hasher.conf"
CONF_FILE="$CONF_DEFAULT"
[ -r "$CONF_LOCAL" ] && CONF_FILE="$CONF_LOCAL"

# Excludes: prefer local/excludes.txt, then default/excludes.txt
EXCLUDES_LOCAL="$LOCAL_DIR/excludes.txt"
EXCLUDES_DEFAULT="$DEFAULT_DIR/excludes.txt"
EXCLUDES_FILE_CANDIDATE=""
if   [ -r "$EXCLUDES_LOCAL"   ]; then EXCLUDES_FILE_CANDIDATE="$EXCLUDES_LOCAL"
elif [ -r "$EXCLUDES_DEFAULT" ]; then EXCLUDES_FILE_CANDIDATE="$EXCLUDES_DEFAULT"
fi
