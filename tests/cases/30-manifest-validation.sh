#!/bin/bash
# 30 — Manifest validation
#
# A damaged manifest must not silently become an actionable delete plan.
# Malformed rows were originally skipped with a warning and exit 0, so a
# truncated file produced a confident-looking plan built from whatever
# happened to parse. Both discovery tools now refuse by default;
# --allow-malformed-rows exists for forensic recovery.
#
# The algo column matters too: an external manifest claiming md5 with
# 64-character values passes a hex/length check but is not a SHA-256
# manifest, and any report built from it would be misleading.

case_description="Manifest validation: malformed rows and wrong algorithms are refused"

run_case() {
  make_sandbox manifest || return 1

  # ── Malformed rows: fatal by default ──────────────────────────────────
  fixture_manifest "$FIXTURES/malformed.csv" malformed
  run_tool find-duplicates.sh --input "$FIXTURES/malformed.csv"
  assert_rc 2 "find-duplicates rejects malformed manifest"
  assert_out_contains "Malformed rows" "malformed-row error"
  assert_out_contains "Refusing" "explicit refusal"

  # No plan may be produced from a manifest that could not be parsed whole.
  assert_glob_count "$SANDBOX/logs/review-dedupe-plan-*.txt" "0" "plans from bad manifest"

  # ── Malformed rows: permitted only when asked for explicitly ──────────
  run_tool find-duplicates.sh --input "$FIXTURES/malformed.csv" --allow-malformed-rows
  assert_rc 0 "--allow-malformed-rows proceeds"
  assert_out_contains "explicitly allowed" "permissive-mode warning"

  # ── Folder discovery applies the same policy ──────────────────────────
  run_tool find-duplicate-folders.sh --input "$FIXTURES/malformed.csv"
  assert_rc 2 "find-duplicate-folders rejects malformed manifest"

  # ── Wrong algorithm ───────────────────────────────────────────────────
  fixture_manifest "$FIXTURES/badalgo.csv" badalgo
  run_tool find-duplicates.sh --input "$FIXTURES/badalgo.csv"
  assert_rc 2 "manifest declaring md5 is refused"

  # ── A valid manifest still works ──────────────────────────────────────
  # Guards against the validation becoming so strict it rejects good input.
  fixture_manifest "$FIXTURES/valid.csv" valid
  run_tool find-duplicates.sh --input "$FIXTURES/valid.csv"
  assert_rc 0 "valid manifest accepted"

  teardown_sandbox
}
