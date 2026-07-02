#!/bin/sh
# lib/log.sh — Hasher shared colour + logging helpers (v1.3.11)
#
# Single source of truth for terminal colours and the info/ok/warn/err/work
# logging functions. Sourcing scripts get consistent, correctly-rendered,
# TTY-guarded coloured output without each reinventing it — which is what
# produced two separate colour bugs historically (check-deps.sh in v1.3.3 and
# delete-junk.sh in v1.3.10, both from literal escapes meeting the wrong
# consumer, or from no colour at all).
#
# Design notes:
#   * Colours are built with `printf '\033[...'` so they are REAL escape bytes,
#     not the literal 7-character string "\033[...". This means they render
#     correctly whether emitted via printf %s, printf %b, echo, or echo -e —
#     removing the fragile coupling that caused past bugs.
#   * Colour is emitted only when stdout is a TTY (`[ -t 1 ]`); otherwise the
#     colour variables are empty, so piped/redirected output stays clean.
#   * POSIX sh compatible (no bashisms): safe under bash 3.2, BusyBox ash, and
#     the Synology/macOS shells this project targets.
#   * Idempotent: sourcing twice is harmless.
#
# Canonical scheme (chosen for a calm, consistent look):
#   INFO  = cyan      OK = green     WARN = yellow
#   ERR   = red       WORK = cyan    (BOLD/RST available for headings)
#
# Back-compat: every colour variable name previously used across the codebase
# is defined here as an alias, so scripts that reference raw $CINFO / $C_INFO /
# $GRN / $GREEN / $c_green etc. keep working after they source this file and
# drop their own definitions.

# Guard against double-sourcing.
if [ -n "${HASHER_LOG_SH_LOADED:-}" ]; then
  : # already loaded; still safe to continue
else
  HASHER_LOG_SH_LOADED=1
fi

# Build the palette (real ESC bytes) only when stdout is a terminal.
if [ -t 1 ]; then
  _LC_CYAN="$(printf '\033[0;36m')"
  _LC_GREEN="$(printf '\033[0;32m')"
  _LC_YELLOW="$(printf '\033[1;33m')"
  _LC_RED="$(printf '\033[0;31m')"
  _LC_BLUE="$(printf '\033[0;34m')"
  _LC_BOLD="$(printf '\033[1m')"
  _LC_RST="$(printf '\033[0m')"
else
  _LC_CYAN=''; _LC_GREEN=''; _LC_YELLOW=''; _LC_RED=''; _LC_BLUE=''
  _LC_BOLD=''; _LC_RST=''
fi

# ── Canonical role → colour mapping ────────────────────────────────────
LOG_C_INFO="$_LC_CYAN"
LOG_C_OK="$_LC_GREEN"
LOG_C_WARN="$_LC_YELLOW"
LOG_C_ERR="$_LC_RED"
LOG_C_WORK="$_LC_CYAN"
LOG_C_RST="$_LC_RST"
LOG_C_BOLD="$_LC_BOLD"

# ── Back-compat aliases (so existing $VAR references keep working) ──────
# CINFO family
CINFO="$LOG_C_INFO"; COK="$LOG_C_OK"; CWARN="$LOG_C_WARN"; CERR="$LOG_C_ERR"
CWORK="$LOG_C_WORK"; CRESET="$LOG_C_RST"
# C_INFO family
C_INFO="$LOG_C_INFO"; C_OK="$LOG_C_OK"; C_WARN="$LOG_C_WARN"; C_ERR="$LOG_C_ERR"
C_RST="$LOG_C_RST"
# short caps
GRN="$LOG_C_OK"; YEL="$LOG_C_WARN"; RED="$LOG_C_ERR"; CYN="$LOG_C_INFO"
RST="$LOG_C_RST"; BOLD="$LOG_C_BOLD"
# long caps
GREEN="$LOG_C_OK"; YELLOW="$LOG_C_WARN"; CYAN="$LOG_C_INFO"; BLUE="$_LC_BLUE"
NC="$LOG_C_RST"
# lower snake
c_green="$LOG_C_OK"; c_yellow="$LOG_C_WARN"; c_red="$LOG_C_ERR"
c_reset="$LOG_C_RST"

# ── Standard logging functions ─────────────────────────────────────────
# All write with printf using the colour as a plain %s argument-prefixed
# format, so there is never a dash-leading-format or %b-escaping hazard.
info() { printf '%s[INFO]%s %s\n'  "$LOG_C_INFO" "$LOG_C_RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n'    "$LOG_C_OK"   "$LOG_C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$LOG_C_WARN" "$LOG_C_RST" "$*"; }
err()  { printf '%s[ERR]%s %s\n'   "$LOG_C_ERR"  "$LOG_C_RST" "$*" >&2; }
work() { printf '%s[WORK]%s %s\n'  "$LOG_C_WORK" "$LOG_C_RST" "$*"; }

# A couple of scripts use "next"/"step" style; provide as info aliases.
next() { info "$@"; }
