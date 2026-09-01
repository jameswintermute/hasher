#!/bin/bash
# 105 — macOS family-folder discovery: detects every user account's
# Documents/Downloads/Pictures, offers to add them all with a y/n prompt
# during first-run setup, and changes nothing on any other platform
#
# Raised directly: a Mac shared by a whole family typically has one
# account per person under /Users, each with the usual personal folders.
# Someone running Hasher as just their own account has no way to know
# their partner's or kid's account holds duplicate copies of the same
# photos or documents unless every account's folders are explicitly
# listed in local/paths.txt — and firstrun_paths() (the only place in
# the launcher where scan paths get configured through the UI at all)
# previously only ever offered a single manual path entry, one at a
# time.
#
# lib/host-detect.sh's macos_discover_family_folders() finds the
# candidates (Documents/Downloads/Pictures under every real user
# account, skipping /Users/Shared and hidden entries, silently skipping
# any subfolder that doesn't exist yet); launcher.sh's
# offer_macos_family_folders() shows what was found and asks once,
# before the generic single-path prompt runs. Both are deliberately
# no-ops with zero output on any non-macOS host.

case_description="macOS family-folder discovery: correct detection, correct y/n offer behaviour, zero effect on non-macOS hosts"

# Builds a fixture /Users-like tree under $SANDBOX/.fake-users and
# returns (via the FIXTURE_HOSTDETECT global) the path to a copy of
# lib/host-detect.sh patched to look there instead of the real /Users —
# the same technique used in 103-hasher-macos-hashcmd-and-host-label.sh
# for testing other host-detect.sh functions without touching the real
# filesystem.
_build_fake_users_tree() {
  mkdir -p "$SANDBOX/.fake-users/Users/alice/Documents"
  mkdir -p "$SANDBOX/.fake-users/Users/alice/Downloads"
  mkdir -p "$SANDBOX/.fake-users/Users/alice/Pictures"
  mkdir -p "$SANDBOX/.fake-users/Users/alice/Library"
  mkdir -p "$SANDBOX/.fake-users/Users/bob/Documents"
  mkdir -p "$SANDBOX/.fake-users/Users/bob/Pictures"
  # bob has no Downloads yet -- must be silently skipped, not an error
  mkdir -p "$SANDBOX/.fake-users/Users/Shared"
  mkdir -p "$SANDBOX/.fake-users/Users/.localized"

  FIXTURE_HOSTDETECT="$SANDBOX/.fake-host-detect.sh"
  sed "s|/Users/\*/|$SANDBOX/.fake-users/Users/*/|; s|\[ -d /Users \]|[ -d $SANDBOX/.fake-users/Users ]|" \
    "$SANDBOX/lib/host-detect.sh" > "$FIXTURE_HOSTDETECT"
}

run_case() {
  # ── Discovery: correct folders, correct exclusions ──────────────────────
  make_sandbox family-folders-discovery-correct || return 1
  _build_fake_users_tree

  local _out
  _out="$(bash -c '
    HASHER_HOST="macos"
    . "'"$FIXTURE_HOSTDETECT"'"
    macos_discover_family_folders
  ')"

  case "$_out" in
    *"/alice/Documents"*)  _assert_pass ;;
    *) _assert_fail "alice's Documents not discovered" ;;
  esac
  case "$_out" in
    *"/alice/Downloads"*)  _assert_pass ;;
    *) _assert_fail "alice's Downloads not discovered" ;;
  esac
  case "$_out" in
    *"/alice/Pictures"*)   _assert_pass ;;
    *) _assert_fail "alice's Pictures not discovered" ;;
  esac
  case "$_out" in
    *"/alice/Library"*) _assert_fail "Library must never be included" ;;
    *) _assert_pass ;;
  esac
  case "$_out" in
    *"/bob/Documents"*)    _assert_pass ;;
    *) _assert_fail "bob's Documents not discovered" ;;
  esac
  case "$_out" in
    *"/bob/Downloads"*) _assert_fail "bob's nonexistent Downloads must be silently skipped, not fabricated" ;;
    *) _assert_pass ;;
  esac
  case "$_out" in
    *"/Shared"*) _assert_fail "/Users/Shared is not a personal account and must be excluded" ;;
    *) _assert_pass ;;
  esac
  case "$_out" in
    *".localized"*) _assert_fail "hidden entries must be excluded" ;;
    *) _assert_pass ;;
  esac
  local _n
  _n="$(printf '%s\n' "$_out" | grep -c .)"
  assert_eq "$_n" "5" "exactly 5 candidate folders found (3 for alice, 2 for bob)"
  teardown_sandbox

  # ── Non-macOS: completely silent, zero output ────────────────────────────
  make_sandbox family-folders-noop-on-linux || return 1
  _build_fake_users_tree
  _out="$(bash -c '
    HASHER_HOST="linux"
    . "'"$FIXTURE_HOSTDETECT"'"
    macos_discover_family_folders
  ')"
  assert_eq "$_out" "" "no output at all on a non-macOS host, even with a matching directory tree present"
  teardown_sandbox

  # ── The launcher offer: accepted, adds paths, dedups against existing ───
  make_sandbox family-folders-offer-accepted || return 1
  _build_fake_users_tree
  mkdir -p "$SANDBOX/local"
  printf '%s/.fake-users/Users/alice/Documents\n' "$SANDBOX" > "$SANDBOX/local/paths.txt"

  cat > "$SANDBOX/.offer-harness.sh" << HARNESS
#!/bin/bash
ROOT_DIR="$SANDBOX"
LOCAL_DIR="$SANDBOX/local"
BOLD=""; RST=""
info() { printf "[INFO] %s\n" "\$*"; }
warn() { printf "[WARN] %s\n" "\$*"; }
HASHER_HOST="macos"
HARNESS
  cp "$FIXTURE_HOSTDETECT" "$SANDBOX/lib/host-detect.sh"
  sed -n '/^offer_macos_family_folders() {/,/^}/p' "$SANDBOX/launcher.sh" >> "$SANDBOX/.offer-harness.sh"

  RUN_OUT="$SANDBOX/.run-out.$$"
  ( echo "y" | bash -c ". '$SANDBOX/.offer-harness.sh'; offer_macos_family_folders" ) > "$RUN_OUT" 2>&1
  RUN_RC=$?

  assert_rc 0 "offer accepted returns 0 (caller should skip the generic prompt)"
  assert_out_contains "Add these to local/paths.txt?" "the explanation and prompt were shown"
  assert_out_contains "Nothing" "the explanation states what's explicitly excluded"

  local _lines
  _lines="$(grep -c . "$SANDBOX/local/paths.txt")"
  assert_eq "$_lines" "5" "5 unique paths total: 1 pre-existing (deduped) + 4 newly added"
  teardown_sandbox

  # ── The launcher offer: declined, nothing written ────────────────────────
  make_sandbox family-folders-offer-declined || return 1
  _build_fake_users_tree
  mkdir -p "$SANDBOX/local"

  cat > "$SANDBOX/.offer-harness.sh" << HARNESS
#!/bin/bash
ROOT_DIR="$SANDBOX"
LOCAL_DIR="$SANDBOX/local"
BOLD=""; RST=""
info() { printf "[INFO] %s\n" "\$*"; }
warn() { printf "[WARN] %s\n" "\$*"; }
HASHER_HOST="macos"
HARNESS
  cp "$FIXTURE_HOSTDETECT" "$SANDBOX/lib/host-detect.sh"
  sed -n '/^offer_macos_family_folders() {/,/^}/p' "$SANDBOX/launcher.sh" >> "$SANDBOX/.offer-harness.sh"

  RUN_OUT="$SANDBOX/.run-out.$$"
  ( echo "n" | bash -c ". '$SANDBOX/.offer-harness.sh'; offer_macos_family_folders" ) > "$RUN_OUT" 2>&1
  RUN_RC=$?

  assert_rc 1 "offer declined returns 1 (caller should fall through to the generic prompt)"
  assert_out_contains "Skipped" "decline is acknowledged"
  if [ ! -s "$SANDBOX/local/paths.txt" ]; then
    _assert_pass
  else
    _assert_fail "paths.txt should remain empty when the offer is declined, got: $(cat "$SANDBOX/local/paths.txt")"
  fi
  teardown_sandbox

  # ── firstrun_paths(): the full integration, offer accepted skips the ────
  # generic single-path prompt entirely; declined falls through to it
  # exactly as before, unchanged.
  make_sandbox firstrun-paths-integration || return 1
  _build_fake_users_tree
  mkdir -p "$SANDBOX/local"

  cat > "$SANDBOX/.firstrun-harness.sh" << HARNESS
#!/bin/bash
ROOT_DIR="$SANDBOX"
LOCAL_DIR="$SANDBOX/local"
BOLD=""; RST=""
info() { printf "[INFO] %s\n" "\$*"; }
warn() { printf "[WARN] %s\n" "\$*"; }
HASHER_HOST="macos"
HARNESS
  cp "$FIXTURE_HOSTDETECT" "$SANDBOX/lib/host-detect.sh"
  sed -n '/^determine_paths_file() {/,/^}/p' "$SANDBOX/launcher.sh" >> "$SANDBOX/.firstrun-harness.sh"
  sed -n '/^offer_macos_family_folders() {/,/^}/p' "$SANDBOX/launcher.sh" >> "$SANDBOX/.firstrun-harness.sh"
  sed -n '/^firstrun_paths() {/,/^}/p' "$SANDBOX/launcher.sh" >> "$SANDBOX/.firstrun-harness.sh"

  RUN_OUT="$SANDBOX/.run-out.$$"
  ( echo "y" | bash -c ". '$SANDBOX/.firstrun-harness.sh'; firstrun_paths" ) > "$RUN_OUT" 2>&1
  RUN_RC=$?
  assert_out_not_contains "Hasher needs at least one directory to scan" "generic prompt correctly skipped when the offer succeeds"
  assert_out_contains "Added" "offer's own success message appears"
  teardown_sandbox
}
