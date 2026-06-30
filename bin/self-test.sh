#!/bin/bash
# self-test.sh — Hasher preflight / integrity check
#
# Purpose: mechanically catch the class of error that recurred during
# development — a correct change landing in a file the running code does not
# load, a script arriving without its executable bit, the conf version drifting
# out of sync, or a sourced helper going missing. These failures are invisible
# until they bite in production; this script surfaces them on demand and at
# launch.
#
# It is deliberately READ-ONLY: it inspects state and reports, and never moves,
# deletes, or rewrites anything. Exit status:
#   0  all checks passed (warnings allowed)
#   1  one or more ERRORS (something is actually broken)
#   2  usage error
#
# Usage:
#   bin/self-test.sh            # full report
#   bin/self-test.sh --quiet    # print only warnings/errors + final summary
#   bin/self-test.sh --strict   # treat warnings as failures (exit 1 on warn)
#
# set -u is safe here; we deliberately avoid -e because this script's whole job
# is to keep going and collect every problem rather than stop at the first.
set -u

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
BIN_DIR="$ROOT_DIR/bin"
LIB_DIR="$ROOT_DIR/lib"
DEFAULT_DIR="$ROOT_DIR/default"
LOCAL_DIR="$ROOT_DIR/local"

QUIET=0
STRICT=0
for a in "$@"; do
  case "$a" in
    --quiet|-q)  QUIET=1 ;;
    --strict)    STRICT=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'Unknown arg: %s\n' "$a" >&2; exit 2 ;;
  esac
done

# Colours (real ESC bytes; TTY only) — same robust pattern as the rest of v1.3.3+
if [ -t 1 ]; then
  GRN="$(printf '\033[0;32m')"; YEL="$(printf '\033[1;33m')"
  RED="$(printf '\033[0;31m')"; CYN="$(printf '\033[0;36m')"
  BOLD="$(printf '\033[1m')";   RST="$(printf '\033[0m')"
else
  GRN=''; YEL=''; RED=''; CYN=''; BOLD=''; RST=''
fi

PASS_N=0; WARN_N=0; ERR_N=0

pass() { PASS_N=$((PASS_N+1)); [ "$QUIET" -eq 1 ] || printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$1"; }
warn() { WARN_N=$((WARN_N+1)); printf '%s[WARN]%s %s\n' "$YEL" "$RST" "$1"; }
fail() { ERR_N=$((ERR_N+1));  printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$1"; }
head_() { [ "$QUIET" -eq 1 ] || printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

# The canonical set of helper scripts the launcher menu can invoke. Keeping this
# list here (rather than parsing the launcher) means self-test also documents
# the expected surface; if a new menu target is added, add it here too.
MENU_TARGETS="
apply-folder-plan.sh
auto-dedup.sh
check-deps.sh
clean-logs.sh
delete-duplicates.sh
delete-junk.sh
delete-zero-length.sh
find-duplicate-folders.sh
find-duplicates.sh
hash-check.sh
hasher.sh
launch-review.sh
review-duplicates.sh
review-folder-plan.sh
run-find-duplicates.sh
"

# Helpers that are SOURCED (not executed). These must exist and be readable;
# the executable bit is irrelevant for sourced files.
SOURCED_HELPERS="
lib/host-detect.sh
"

# Commands the tool needs to function at all.
REQUIRED_CMDS="bash awk sed grep find stat wc tr cut sort head tail date du mktemp"

printf '%sHasher self-test%s — %s\n' "$BOLD" "$RST" "$ROOT_DIR"

# ── 1. Sourced helpers resolve ────────────────────────────────────────────────
head_ "1. Sourced helpers"
for rel in $SOURCED_HELPERS; do
  f="$ROOT_DIR/$rel"
  if [ ! -f "$f" ]; then
    fail "$rel is MISSING — scripts that source it will break"
  elif [ ! -r "$f" ]; then
    fail "$rel exists but is not readable"
  elif ! bash -n "$f" 2>/dev/null; then
    fail "$rel has a syntax error"
  else
    pass "$rel present, readable, parses"
  fi
done

# ── 2. No stale duplicate helpers ─────────────────────────────────────────────
# The exact bug from item 5: a second copy of a sourced helper in bin/ that
# looks newer but is never loaded. Flag any sourced-helper basename that also
# appears outside its canonical directory.
head_ "2. Stale/duplicate helpers"
dup_found=0
for rel in $SOURCED_HELPERS; do
  base="$(basename "$rel")"
  # search anywhere under ROOT_DIR for the same basename
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    # normalise to repo-relative
    relhit="${hit#$ROOT_DIR/}"
    if [ "$relhit" != "$rel" ]; then
      fail "duplicate helper: $relhit shadows the canonical $rel (delete the stray copy)"
      dup_found=1
    fi
  done <<EOF
$(find "$ROOT_DIR" -name "$base" -type f 2>/dev/null)
EOF
done
[ "$dup_found" -eq 0 ] && pass "no duplicate copies of sourced helpers"

# ── 3. Menu targets exist and are runnable ────────────────────────────────────
# "Runnable" means present AND (executable OR readable) — because the launcher's
# run_script falls back to `bash <script>` when +x is missing (v1.3.2). A
# missing file is an ERROR; a present-but-non-executable file is a WARNING
# (works via fallback, but the bit ideally should be set).
head_ "3. Menu targets (exist + runnable)"
nonexec=0
for s in $MENU_TARGETS; do
  f="$BIN_DIR/$s"
  if [ ! -f "$f" ]; then
    fail "bin/$s is MISSING (launcher references it)"
  elif [ -x "$f" ]; then
    pass "bin/$s executable"
  elif [ -r "$f" ]; then
    warn "bin/$s present but NOT executable — will run via bash fallback; consider: chmod +x bin/$s"
    nonexec=$((nonexec+1))
  else
    fail "bin/$s present but neither executable nor readable"
  fi
done
if [ "$nonexec" -gt 0 ]; then
  warn "$nonexec script(s) lack the executable bit (common after GitHub web-UI / zip upload). The launcher tolerates this via its bash fallback."
fi

# ── 4. Version consistency ────────────────────────────────────────────────────
# The eight-release drift: the conf version is tracked in default/hasher.conf,
# but a bumped conf uploaded into the gitignored local/ never reached default/.
# Compare the launcher's displayed version with default/hasher.conf, and warn if
# a local/hasher.conf disagrees (a sign of the same trap).
head_ "4. Version consistency"
launcher_v="$(grep 'James Wintermute' "$ROOT_DIR/launcher.sh" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
conf_v=""
[ -f "$DEFAULT_DIR/hasher.conf" ] && conf_v="$(grep -m1 -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$DEFAULT_DIR/hasher.conf" 2>/dev/null)"
if [ -z "$launcher_v" ]; then
  warn "could not determine launcher version string"
elif [ -z "$conf_v" ]; then
  fail "default/hasher.conf missing or has no version — launcher is $launcher_v"
elif [ "$launcher_v" = "$conf_v" ]; then
  pass "launcher and default/hasher.conf agree ($launcher_v)"
else
  fail "version drift: launcher=$launcher_v but default/hasher.conf=$conf_v (did a bumped conf land in local/ instead of default/?)"
fi
# Detect the specific trap: a local/hasher.conf with a different version
if [ -f "$LOCAL_DIR/hasher.conf" ]; then
  local_v="$(grep -m1 -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$LOCAL_DIR/hasher.conf" 2>/dev/null)"
  if [ -n "$local_v" ] && [ -n "$conf_v" ] && [ "$local_v" != "$conf_v" ]; then
    warn "local/hasher.conf version ($local_v) differs from default/ ($conf_v). local/ is gitignored — version bumps belong in default/hasher.conf."
  fi
fi

# ── 5. Required commands ──────────────────────────────────────────────────────
head_ "5. Required commands"
missing_cmd=0
for c in $REQUIRED_CMDS; do
  if command -v "$c" >/dev/null 2>&1; then
    pass "$c"
  else
    fail "$c not found in PATH"
    missing_cmd=$((missing_cmd+1))
  fi
done
# At least one sha256 tool (hasher can shim via OpenSSL, but warn if truly none)
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  pass "sha256 tool available"
elif command -v openssl >/dev/null 2>&1; then
  warn "no sha256sum/shasum, but openssl present — run check-deps.sh --fix to create shims"
else
  fail "no sha256 tool and no openssl — hashing cannot run (see check-deps.sh)"
fi

# ── 6. Bash version ───────────────────────────────────────────────────────────
head_ "6. Shell"
# v1.3.7: use the shared detection from lib/host-detect.sh (single source of
# truth) when available; fall back to inline if not.
if [ -r "$LIB_DIR/host-detect.sh" ]; then
  # shellcheck disable=SC1090
  . "$LIB_DIR/host-detect.sh"
fi
if command -v bash_at_least >/dev/null 2>&1; then
  detect_bash_version
  if bash_at_least 3 2; then
    pass "bash ${HASHER_BASH_VERSION:-?} (>= 3.2 baseline)"
  else
    warn "bash ${HASHER_BASH_VERSION:-?} is below the 3.2 baseline; some scripts may misbehave"
  fi
  # Informational: note when running the project's oldest supported bash, which
  # is most commonly macOS /bin/bash 3.2.
  if [ "${HASHER_BASH_MAJOR:-0}" -eq 3 ]; then
    [ "$QUIET" -eq 1 ] || printf '       (Bash 3.x — the project 3.2 baseline; common on macOS /bin/bash)\n'
  fi
else
  bmaj="${BASH_VERSINFO:-0}"; bmin="${BASH_VERSINFO[1]:-0}"
  if [ "$bmaj" -gt 3 ] || { [ "$bmaj" -eq 3 ] && [ "$bmin" -ge 2 ]; }; then
    pass "bash ${BASH_VERSINFO:-?}.${BASH_VERSINFO[1]:-?} (>= 3.2 baseline)"
  else
    warn "bash ${bmaj}.${bmin} is below the 3.2 baseline; some scripts may misbehave"
  fi
fi

# ── 7. Config & paths ─────────────────────────────────────────────────────────
head_ "7. Configuration"
if [ -f "$DEFAULT_DIR/hasher.conf" ]; then
  pass "default/hasher.conf present"
else
  fail "default/hasher.conf missing (the tracked default config)"
fi
# paths.txt: not required to exist (first-run may not have created it), but if
# present it should contain at least one non-comment line to be useful.
pf=""
for cand in "$LOCAL_DIR/paths.txt" "$ROOT_DIR/paths.txt"; do
  [ -f "$cand" ] && { pf="$cand"; break; }
done
if [ -z "$pf" ]; then
  warn "no paths.txt yet — run the launcher (first-run setup) or create local/paths.txt before hashing"
elif grep -qvE '^[[:space:]]*(#|$)' "$pf" 2>/dev/null; then
  pass "paths.txt has at least one scan path ($pf)"
else
  warn "paths.txt exists but has no active scan paths ($pf)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%s────────────────────────────────────────%s\n' "$BOLD" "$RST"
printf '%sSummary:%s %s%d passed%s, %s%d warning(s)%s, %s%d error(s)%s\n' \
  "$BOLD" "$RST" \
  "$GRN" "$PASS_N" "$RST" \
  "$YEL" "$WARN_N" "$RST" \
  "$RED" "$ERR_N" "$RST"

if [ "$ERR_N" -gt 0 ]; then
  printf '%sResult: FAIL%s — fix the errors above before relying on the tool.\n' "$RED" "$RST"
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARN_N" -gt 0 ]; then
  printf '%sResult: FAIL (strict)%s — warnings treated as failures.\n' "$RED" "$RST"
  exit 1
fi
printf '%sResult: PASS%s\n' "$GRN" "$RST"
exit 0
