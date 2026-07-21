#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# Hasher — Minimal dependency & readiness check (BusyBox/POSIX safe)
# Usage: bin/check-deps.sh [--fix]
#  - Verifies required tools and directory layout
#  - Reports CPU cores and basic environment
#  - If --fix and OpenSSL is available, creates shims for *sum tools (sha256sum, sha1sum, sha512sum, md5sum)

set -eu

BIN_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$BIN_DIR/.." && pwd -P)"
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

# Colours from the shared module (v1.3.11) — single source of truth, TTY-guarded,
# real ESC bytes. This script keeps its own ok/warn/err below because it uses
# custom column alignment and an [ERROR] label; it only needs the colour vars
# (GRN/YEL/RED/CYN/RST) which lib/log.sh provides as back-compat aliases.
if [ -r "$ROOT_DIR/lib/log.sh" ]; then
  . "$ROOT_DIR/lib/log.sh"
else
  if [ -t 1 ]; then
    GRN="$(printf '\033[0;32m')"; YEL="$(printf '\033[1;33m')"
    RED="$(printf '\033[0;31m')"; CYN="$(printf '\033[0;36m')"
    RST="$(printf '\033[0m')"
  else
    GRN=''; YEL=''; RED=''; CYN=''; RST=''
  fi
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Locally-styled variants (aligned columns, [ERROR] label) — colours from lib/log.sh.
ok()   { printf "%s[OK]%s     %s\n"   "$GRN" "$RST" "$1"; }
warn() { printf "%s[WARN]%s   %s\n"   "$YEL" "$RST" "$1"; }
err()  { printf "%s[ERROR]%s  %s\n"   "$RED" "$RST" "$1"; }

mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/hashes" "$ROOT_DIR/var/zero-length" 2>/dev/null || true

echo "${CYN}System check (deps & readiness)…${RST}"

# OS/arch
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
UNAME_M="$(uname -m 2>/dev/null || echo unknown)"
echo "Platform: $UNAME_S ($UNAME_M)"

# FIX (v1.1.9): show the detected hasher host class so users can see
# at a glance whether host-aware defaults will kick in.
if [ -r "$ROOT_DIR/lib/host-detect.sh" ]; then
  . "$ROOT_DIR/lib/host-detect.sh"
  detect_host
  echo "Hasher host: $(host_pretty_label) ($HASHER_HOST)"
  # v1.3.7: show the running Bash version. The oldest supported (3.2) is most
  # often macOS /bin/bash; flag it so users understand any 3.2-related notes.
  if command -v detect_bash_version >/dev/null 2>&1; then
    detect_bash_version
    if bash_at_least 3 2; then
      echo "Bash version: ${HASHER_BASH_VERSION:-unknown} (>= 3.2 baseline)"
    else
      echo "Bash version: ${HASHER_BASH_VERSION:-unknown} (BELOW 3.2 baseline — may misbehave)"
    fi
  fi
fi

# CPU cores
CORES=""
if have getconf; then
  CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
fi
[ -z "$CORES" ] && have nproc && CORES="$(nproc 2>/dev/null || true)"
[ -z "$CORES" ] && [ -r /proc/cpuinfo ] && CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
[ -z "$CORES" ] && CORES="unknown"
echo "CPU cores: $CORES"

# Open files limit
if have ulimit; then
  # ulimit is a shell builtin; this may run only in interactive shells, so we try via sh -c
  OF="$(sh -c 'ulimit -n' 2>/dev/null || true)"
  [ -n "$OF" ] && echo "ulimit -n (open files): $OF" || echo "ulimit -n (open files): unknown"
fi

echo
echo "Directories:"
[ -d "$ROOT_DIR/logs" ]               && ok "logs/ present"             || warn "logs/ missing"
[ -d "$ROOT_DIR/hashes" ]             && ok "hashes/ present"           || warn "hashes/ missing"
# FIX (v1.1.9): zero-length/ was relocated to var/zero-length/ in v1.1.5;
# this script's check was never updated and would create a stale empty
# zero-length/ at the repo root every run.
[ -d "$ROOT_DIR/var/zero-length" ]    && ok "var/zero-length/ present"  || warn "var/zero-length/ missing"

echo
echo "Required tools:"
REQUIRED="bash awk sed grep find stat wc tr cut sort head tail date"
missing_req=0
for t in $REQUIRED; do
  if have "$t"; then ok "$t"; else err "$t (missing)"; missing_req=1; fi
done

# GNU vs BSD stat check (macOS warning)
if echo "TEST" >/dev/null 2>&1; then
  if ! stat -c %s "$0" >/dev/null 2>&1; then
    warn "Your 'stat' may not support GNU -c (macOS/BSD). On macOS install coreutils and set PATH so 'stat' = 'gstat'."
  fi
fi

echo
# v1.3.18 (peer-review finding #4): hasher.sh explicitly rejects non-SHA-256
# algorithms since v1.3.16, so requiring sha1sum/sha512sum/md5sum was
# misleading — those tools are never invoked. Only sha256sum (or shasum
# with -a 256 fallback, or an OpenSSL shim) is actually needed for dedupe.
echo "Hashing tool (SHA-256 is the only supported algorithm since v1.3.16):"
HAVE_OPENSSL=0
have openssl && HAVE_OPENSSL=1

need_shim=0
if have sha256sum; then
  ok "sha256sum"
elif have shasum; then
  ok "shasum (will use 'shasum -a 256')"
elif [ "$HAVE_OPENSSL" -eq 1 ]; then
  warn "sha256sum/shasum missing → will provide shim via OpenSSL"
  need_shim=1
else
  err "No SHA-256 implementation available (need sha256sum, shasum, or openssl)"
  missing_req=1
fi

# b2sum, sha1sum, sha512sum, md5sum are NOT required or used.
# Report their presence informationally only, no warn/err.
for opt in b2sum sha1sum sha512sum md5sum; do
  have "$opt" && ok "$opt (present; not used by dedupe)" || : # silent when absent
done

# niceness tools
have nice   && ok "nice"   || warn "nice (missing)"
have ionice && ok "ionice" || warn "ionice (optional; not always present on NAS)"

echo
# v1.3.18 (peer-review finding #4): parallel path and stop-hashing depend on
# these; check them explicitly instead of hoping they're present.
echo "Core runtime tools (required by the parallel path and 'k) Stop hashing'):"
for t in xargs comm awk grep sed tr sort; do
  if have "$t"; then ok "$t"; else err "$t (missing) — required"; missing_req=1; fi
done

echo
echo "Process-control capabilities (used by 'k) Stop hashing' and TERM handling):"
if have pgrep; then ok "pgrep"; else warn "pgrep (missing) — descendant-tree walk in the no-setsid fallback will not work"; fi
if have setsid; then
  ok "setsid — hasher runs in its own session (clean group-kill available)"
else
  warn "setsid (missing) — no session isolation; hasher falls back to descendant-tree walk on TERM. Reap of xargs workers is best-effort."
fi
# ps -o pgid= support (required for launcher's PGID checks)
if ps -o pgid= -p $$ >/dev/null 2>&1; then
  ok "ps -o pgid= (PGID query supported)"
else
  err "ps -o pgid= not supported — launcher cannot safely group-signal hashers"
  missing_req=1
fi

# Try to install shims if requested
if [ "$FIX" -eq 1 ] && [ "$need_shim" -eq 1 ] && [ "$HAVE_OPENSSL" -eq 1 ]; then
  echo
  echo "Creating OpenSSL-based shims in bin/…"
  mkdir -p "$BIN_DIR"
  mk_shim() {
    name="$1"; ossl_flag="$2"
    path="$BIN_DIR/$name"
    cat > "$path" <<EOF
#!/bin/sh
# shim generated by check-deps.sh
exec openssl dgst -r -$ossl_flag "\$@"
EOF
    chmod +x "$path"
    ok "shim: $name -> openssl -$ossl_flag"
  }
  have sha256sum || mk_shim sha256sum sha256
  have sha1sum   || mk_shim sha1sum   sha1
  have sha512sum || mk_shim sha512sum sha512
  have md5sum    || mk_shim md5sum    md5
fi

echo
if [ "$missing_req" -eq 0 ]; then
  echo "${GRN}All required dependencies look good.${RST}"
  echo "You can start hashing from the launcher."
  exit 0
else
  echo "${YEL}Some required tools are missing.${RST}"
  echo "Tips:"
  echo "  • Debian/Ubuntu:    sudo apt-get install bash coreutils findutils gawk sed grep"
  echo "  • RHEL/CentOS:      sudo yum install bash coreutils findutils gawk sed grep"
  echo "  • macOS (Homebrew): brew install bash coreutils findutils gawk gnu-sed grep"
  echo "  • Synology:         use ipkg/opkg/Entware where applicable, or enable SSH and install required packages."
  exit 1
fi
