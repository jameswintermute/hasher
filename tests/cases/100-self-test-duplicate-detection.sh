#!/bin/bash
# 100 — self-test.sh: duplicate-script detection covers launcher.sh too,
# and any future script, without a hand-maintained list
#
# A third occurrence of the same failure pattern, found by a manual
# sanity check on a real uploaded zip: default/launcher.sh, a full stale
# duplicate of the real launcher.sh (differing only in its embedded
# version string, two releases behind), sat completely undetected.
# launcher.sh was never in scope for either of the two existing
# duplicate checks — $SOURCED_HELPERS only covers lib/*.sh,
# $MENU_TARGETS only covers bin/*.sh, and launcher.sh lives at the repo
# root, in neither category.
#
# This is the same shape of gap fixed twice already: bin/import-check.sh
# (v1.4.15) and bin/self-test.sh itself (v1.4.16). Fixed this time by
# removing the hand-maintained list entirely for this specific check —
# canonical scripts are now discovered directly from the filesystem
# (launcher.sh at root, plus whatever .sh files actually exist under
# bin/ and lib/ right now), so a script added next month is
# automatically in scope with nothing to remember to update.

case_description="self-test.sh: duplicate detection covers launcher.sh and any future bin/lib script, not just a fixed list"

run_case() {
  # ── The exact reported scenario: a stale default/launcher.sh ────────────
  make_sandbox dup-launcher-detected || return 1
  cp "$SANDBOX/launcher.sh" "$SANDBOX/default/launcher.sh"

  run_tool self-test.sh
  assert_rc 1 "self-test fails with a stray default/launcher.sh present"
  assert_out_contains "duplicate script: default/launcher.sh shadows the canonical launcher.sh" "correct, specific error message"
  teardown_sandbox

  # ── A brand-new script, never named in any list, still gets covered ─────
  make_sandbox dup-new-script-detected || return 1
  printf '#!/bin/bash\necho hi\n' > "$SANDBOX/bin/brand-new-tool.sh"
  cp "$SANDBOX/bin/brand-new-tool.sh" "$SANDBOX/brand-new-tool.sh"

  run_tool self-test.sh
  assert_rc 1 "self-test fails with a stray duplicate of a script no list ever mentioned"
  assert_out_contains "duplicate script: brand-new-tool.sh shadows the canonical bin/brand-new-tool.sh" "correctly identified with no prior knowledge of this script's name"
  teardown_sandbox

  # ── A clean tree still passes (no false positives from the rewrite) ─────
  make_sandbox dup-clean-tree-passes || return 1
  run_tool self-test.sh
  assert_rc 0 "a genuinely clean tree still passes"
  assert_out_contains "no duplicate copies of any canonical script" "the new unified pass line appears"
  teardown_sandbox

  # ── Both the original two cases still work under the new mechanism ──────
  make_sandbox dup-original-cases-still-work || return 1
  cp "$SANDBOX/bin/import-check.sh" "$SANDBOX/import-check.sh"
  cp "$SANDBOX/bin/self-test.sh" "$SANDBOX/self-test.sh"

  run_tool self-test.sh
  assert_rc 1 "both v1.4.15 and v1.4.16's original scenarios still caught"
  assert_out_contains "duplicate script: import-check.sh shadows the canonical bin/import-check.sh" "v1.4.15 case still works"
  assert_out_contains "duplicate script: self-test.sh shadows the canonical bin/self-test.sh" "v1.4.16 case still works"
  teardown_sandbox
}
