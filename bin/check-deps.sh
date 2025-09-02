#!/usr/bin/env bash
# check-deps.sh — Hasher host readiness & dependency checker
# Copyright (C) 2025
# License: GPLv3

set -Eeuo pipefail
IFS=$'\n\t'

# ───────────────────────── Helpers ─────────────────────────
is_tty() { [[ -t 1 ]]; }
if is_tty; then
  C_GRN="\033[0;32m"; C_YLW="\033[1;33m"; C_RED="\033[0;31m"; C_CYN="\033[0;36m"; C_MGN="\033[0;35m"; C_DIM="\033[2m"; C_RST="\033[0m"
else
  C_GRN=""; C_YLW=""; C_RED=""; C_CYN=""; C_MGN=""; C_DIM=""; C_RST=""
fi

have() { command -v "$1" >/dev/null 2>&1; }
ts() { date +"%Y-%m-%d %H:%M:%S"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
HASHES_DIR="$ROOT_DIR/hashes"
REPORT="$LOG_DIR/syscheck-$(date +'%Y-%m-%d-%H%M%S').txt"

OK=0; WARN=0; FAIL=0
pass() { printf "%b[OK]%b     %s\n" "$C_GRN" "$C_RST" "$1"; ((OK++)); }
warn() { printf "%b[WARN]%b   %s\n" "$C_YLW" "$C_RST" "$1"; ((WARN++)); }
fail() { printf "%b[MISSING]%b %s\n" "$C_RED" "$C_RST" "$1"; ((FAIL++)); }

# ───────────────────────── Host info ───────────────────────
OS_KERNEL="$(uname -s 2>/dev/null || echo unknown)"
OS_ARCH="$(uname -m 2>/dev/null || echo unknown)"
OS_DIST="unknown"
if [[ "$OS_KERNEL" == "Linux" && -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_DIST="${PRETTY_NAME:-$NAME}"
elif [[ "$OS_KERNEL" == "Darwin" ]]; then
  OS_DIST="macOS $(sw_vers -productVersion 2>/dev/null || true)"
fi

pkg_mgr=""
for pm in apt apt-get dnf yum zypper pacman apk brew port opkg ipkg; do
  if have "$pm"; then pkg_mgr="$pm"; break; fi
done

cpu_cores() {
  if have nproc; then nproc
  elif have getconf; then getconf _NPROCESSORS_ONLN
  elif [[ "$OS_KERNEL" == "Darwin" ]] && have sysctl; then sysctl -n hw.ncpu
  else echo 1; fi
}

df_path() {
  df -h "$ROOT_DIR" 2>/dev/null | awk 'NR==2{print $4" free on " $1}'
}

mem_info() {
  if [[ "$OS_KERNEL" == "Linux" ]] && [[ -r /proc/meminfo ]]; then
    awk '/MemTotal/{printf "%.1f GB RAM total", $2/1024/1024}' /proc/meminfo
  elif [[ "$OS_KERNEL" == "Darwin" ]] && have sysctl; then
    bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    awk -v b="$bytes" 'BEGIN{printf "%.1f GB RAM total", b/1024/1024/1024}'
  else
    echo "RAM unknown"
  fi
}

# ─────────────────── Required & optional deps ──────────────
REQUIRED_CMDS=(bash awk sed find xargs sort uniq grep wc cut tr date mkdir tee head tail nohup nice)
OPTIONAL_CMDS=(ionice pv stdbuf gstdbuf htop)
# hashing toolchains — we need at least one viable path for SHA256
# (hasher also supports other algos; we sanity-check the main one)
HASH_TOOLS=(
  "sha256sum::sha256sum"
  "shasum -a 256::shasum"
  "openssl dgst -sha256::openssl"
)

# ────────────────────────── Flags ──────────────────────────
AUTO_FIX_DIRS=false
[[ "${1:-}" == "--fix" ]] && AUTO_FIX_DIRS=true

mkdir -p "$LOG_DIR" || true

# ────────────────────── Begin report header ────────────────
{
  echo "=== hasher System Check Report ==="
  echo "Timestamp: $(ts)"
  echo "Project:   $ROOT_DIR"
  echo "OS:        $OS_KERNEL ($OS_DIST) on $OS_ARCH"
  echo "Pkg mgr:   ${pkg_mgr:-none-detected}"
  echo "CPU:       $(cpu_cores) cores"
  echo "Memory:    $(mem_info)"
  echo "Storage:   $(df_path)"
  echo
  echo "— Required commands —"
} | tee -a "$REPORT" >/dev/null

printf "%bHost:%b %s • %s • %s cores • %s • pkg:%s\n" \
  "$C_CYN" "$C_RST" "$OS_KERNEL/$OS_DIST" "$(hostname 2>/dev/null || echo unknown)" \
  "$(cpu_cores)" "$(mem_info)" "${pkg_mgr:-none}" | tee -a "$REPORT" >/dev/null
printf "%bWorking dir:%b %s (free: %s)\n\n" "$C_CYN" "$C_RST" "$ROOT_DIR" "$(df_path)" | tee -a "$REPORT" >/dev/null

# ───────────────────── Required commands check ─────────────
for c in "${REQUIRED_CMDS[@]}"; do
  if have "$c"; then pass "$c"; echo "[OK] $c" >>"$REPORT"
  else fail "$c"; echo "[MISSING] $c" >>"$REPORT"
  fi
done

echo | tee -a "$REPORT" >/dev/null
echo "— Hashing toolchain (need at least one) —" | tee -a "$REPORT" >/dev/null
HASH_CMD=""
for spec in "${HASH_TOOLS[@]}"; do
  cmd="${spec%%::*}"
  probe="${spec##*::}"
  if have "$probe"; then
    pass "$cmd"
    [[ -z "$HASH_CMD" ]] && HASH_CMD="$cmd"
    echo "[OK] $cmd" >>"$REPORT"
  else
    warn "not found: $cmd"
    echo "[WARN] missing $cmd" >>"$REPORT"
  fi
done
[[ -z "$HASH_CMD" ]] && fail "No SHA256 toolchain found (sha256sum | shasum -a 256 | openssl dgst -sha256)"

echo | tee -a "$REPORT" >/dev/null
echo "— Optional utilities —" | tee -a "$REPORT" >/dev/null
for c in "${OPTIONAL_CMDS[@]}"; do
  if have "$c"; then pass "$c (optional)"; echo "[OK] optional $c" >>"$REPORT"
  else warn "$c (optional, will degrade UX if missing)"; echo "[WARN] optional $c" >>"$REPORT"
  fi
done

# stdbuf/gstdbuf note
if ! have stdbuf && ! have gstdbuf; then
  warn "stdbuf not found (progress output may be less smooth). On macOS: 'brew install coreutils' (uses 'gstdbuf')."
fi

# ───────────────────── Project structure check ─────────────
echo | tee -a "$REPORT" >/dev/null
echo "— Project structure —" | tee -a "$REPORT" >/dev/null

[[ -f "$ROOT_DIR/hasher.sh" ]] && pass "hasher.sh present" || fail "hasher.sh missing"
[[ -f "$ROOT_DIR/launcher.sh" ]] && pass "launcher.sh present" || warn "launcher.sh missing (not fatal)"
[[ -f "$ROOT_DIR/find-duplicates.sh" ]] && pass "find-duplicates.sh present" || warn "find-duplicates.sh missing"
[[ -f "$ROOT_DIR/delete-duplicates.sh" ]] && pass "delete-duplicates.sh present" || warn "delete-duplicates.sh missing"

if [[ -d "$HASHES_DIR" && -w "$HASHES_DIR" ]]; then
  pass "hashes/ exists & writable"
else
  if $AUTO_FIX_DIRS; then
    mkdir -p "$HASHES_DIR" && pass "created hashes/"
  else
    warn "hashes/ missing or not writable (use --fix to create)"
  fi
fi

if [[ -d "$LOG_DIR" && -w "$LOG_DIR" ]]; then
  pass "logs/ exists & writable"
else
  if $AUTO_FIX_DIRS; then
    mkdir -p "$LOG_DIR" && pass "created logs/"
  else
    warn "logs/ missing or not writable (use --fix to create)"
  fi
fi

# Synology/busybox hints
if have busybox; then
  warn "busybox detected — commands like awk/find may be busybox variants (generally fine)."
fi
if [[ "$OS_KERNEL" == "Darwin" ]]; then
  warn "macOS detected — GNU tools may be under 'g*' names if installed via Homebrew (e.g., gsed, ggrep)."
fi

# ───────────────────── Install guidance (best-effort) ──────
echo | tee -a "$REPORT" >/dev/null
echo "— Install guidance (best-effort) —" | tee -a "$REPORT" >/dev/null
case "$pkg_mgr" in
  apt|apt-get)
    echo "Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y coreutils findutils gawk grep sed util-linux pv" | tee -a "$REPORT" >/dev/null
    ;;
  dnf|yum)
    echo "RHEL/Fedora: sudo $pkg_mgr install -y coreutils findutils gawk grep sed util-linux pv" | tee -a "$REPORT" >/dev/null
    ;;
  zypper)
    echo "openSUSE: sudo zypper install -y coreutils findutils gawk grep sed util-linux pv" | tee -a "$REPORT" >/dev/null
    ;;
  pacman)
    echo "Arch: sudo pacman -S --needed coreutils findutils gawk grep sed util-linux pv" | tee -a "$REPORT" >/dev/null
    ;;
  apk)
    echo "Alpine: sudo apk add coreutils findutils gawk grep sed util-linux pv" | tee -a "$REPORT" >/dev/null
    ;;
  brew)
    echo "macOS (Homebrew): brew install coreutils findutils gawk grep gnu-sed pv" | tee -a "$REPORT" >/dev/null
    ;;
  port)
    echo "macOS (MacPorts): sudo port install coreutils findutils gawk grep gsed pv" | tee -a "$REPORT" >/dev/null
    ;;
  opkg|ipkg)
    echo "Synology/Entware: opkg install coreutils findutils gawk grep sed pv" | tee -a "$REPORT" >/dev/null
    ;;
  *)
    echo "No package manager detected. Install coreutils/findutils/gawk/grep/sed manually for full features." | tee -a "$REPORT" >/dev/null
    ;;
esac

# ───────────────────────── Summary & exit ──────────────────
echo | tee -a "$REPORT" >/dev/null
printf "%bSummary:%b OK=%d, WARN=%d, MISSING=%d\n" "$C_MGN" "$C_RST" "$OK" "$WARN" "$FAIL" | tee -a "$REPORT" >/dev/null
echo "Report: $REPORT" | tee -a "$REPORT" >/dev/null
echo

if (( FAIL > 0 )); then
  printf "%bHasher is NOT ready%b (missing required tools). See report above.\n" "$C_RED" "$C_RST"
  exit 1
elif (( WARN > 0 )); then
  printf "%bHasher is ready with warnings%b (optional tools missing). You can still run.\n" "$C_YLW" "$C_RST"
  exit 0
else
  printf "%bHasher is ready to run%b — all checks passed.\n" "$C_GRN" "$C_RST"
  exit 0
fi
