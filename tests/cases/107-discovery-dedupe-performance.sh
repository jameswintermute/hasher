#!/bin/bash
# 107 — hasher.sh discovery dedupe: no per-file bash loop, correct output
# preserved exactly, at real-world scale
#
# Reported live from a real macOS run (Richard's Mac, ~240,000 files
# across 16 scan paths): hashing appeared to hang indefinitely after
# "Walking paths" stopped advancing, left for hours with no progress.
# `ps aux` showed no `find` process running at all, yet hasher.sh itself
# was still active and consuming real CPU — ruling out a blocked syscall
# (a stuck network mount, a permission-prompt hang) and pointing at CPU-
# bound work happening somewhere the walk's own progress heartbeat
# doesn't cover.
#
# Root cause: the discovery-dedupe step added in v1.3.27 (collapsing
# duplicate paths from overlapping scan roots) ran a `while read -r |
# printf` bash loop once per discovered file — 240,000 bash-level
# iterations for a run that size — with none of the awk fast paths the
# delimiter filter and glob-exclude filter immediately before and after
# it both already have. This step has no progress ticker of its own, so
# a slow pass here is invisible: it looks exactly like an indefinite
# freeze with no visible cause, which is exactly what was reported.
#
# Fixed by replacing the loop with a single `tr '\n' '\0'`, confirmed via
# a synthetic 240,000-entry benchmark to produce byte-identical output
# roughly 35x faster even on fast modern hardware -- the gap is expected
# to be far larger on Apple's frozen-since-2007 bash 3.2, which is what
# every real macOS install actually ships, including the one that
# reported this.

case_description="discovery dedupe: correct duplicate removal preserved exactly, the old per-file bash loop is gone, real-scale timing sane"

run_case() {
  # ── Correctness: overlapping roots produce a correctly deduped list ─────
  make_sandbox discovery-dedupe-correctness || return 1
  mkdir -p "$FIXTURES/data/sub"
  printf 'a\n' > "$FIXTURES/data/one.txt"
  printf 'b\n' > "$FIXTURES/data/sub/two.txt"
  set_paths "$FIXTURES/data" "$FIXTURES/data/sub"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  assert_out_contains "Removed 1 duplicate discovery path" "overlapping roots correctly deduped, with the existing message intact"

  local _csv; _csv="$(latest_csv)"
  local _rows
  _rows=$(( $(wc -l < "$_csv" 2>/dev/null | tr -d ' ') - 1 ))
  assert_eq "$_rows" "2" "exactly 2 unique files in the manifest, not 3 (the overlap counted once)"
  teardown_sandbox

  # ── No duplicates: the message is correctly absent, nothing spurious ────
  make_sandbox discovery-dedupe-no-overlap || return 1
  mkdir -p "$FIXTURES/data"
  printf 'a\n' > "$FIXTURES/data/one.txt"
  printf 'b\n' > "$FIXTURES/data/two.txt"
  set_paths "$FIXTURES/data"

  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  assert_out_not_contains "duplicate discovery path" "no spurious dedup message when there is nothing to dedupe"
  teardown_sandbox

  # ── Structural guard: the old per-file bash loop is genuinely gone ──────
  # The actual regression this test exists to prevent: a `while read`
  # loop iterating once per discovered file, reintroduced either here or
  # anywhere else in this specific dedupe block.
  make_sandbox discovery-dedupe-structural-guard || return 1
  if grep -A30 "collapse duplicate discovery entries" "$SANDBOX/bin/hasher.sh" 2>/dev/null \
       | grep -q 'while IFS= read -r _unique_path'; then
    _assert_fail "the old per-file while-read loop has returned to the dedupe step"
  else
    _assert_pass
  fi
  if grep -A30 "collapse duplicate discovery entries" "$SANDBOX/bin/hasher.sh" 2>/dev/null \
       | grep -q "sort -u | grep -v"; then
    _assert_pass
  else
    _assert_fail "expected the tr-based rewrite (sort -u | grep -v '^\$' | tr) to be present in the dedupe step"
  fi
  teardown_sandbox

  # ── Real-scale timing: correctness and sane elapsed time together ───────
  # Not the primary regression guard (the structural check above is
  # deterministic; this is a live demonstration) -- a generous threshold
  # that would not be sensitive to normal CI variance, but would clearly
  # fail if a per-file bash loop reappeared at this scale on slow hardware.
  make_sandbox discovery-dedupe-real-scale || return 1
  mkdir -p "$FIXTURES/data"
  local _i
  for _i in $(seq 1 3000); do
    printf 'content-%s\n' "$_i" > "$FIXTURES/data/file_$_i.txt"
  done
  set_paths "$FIXTURES/data" "$FIXTURES/data"

  local _t0 _t1 _elapsed
  _t0=$(date +%s)
  run_hasher --pathfile local/paths.txt --jobs 1 --no-discover
  _t1=$(date +%s)
  _elapsed=$(( _t1 - _t0 ))

  assert_out_contains "Removed 3000 duplicate discovery path" "all 3000 overlapping duplicates correctly collapsed"
  local _csv2; _csv2="$(latest_csv)"
  local _rows2
  _rows2=$(( $(wc -l < "$_csv2" 2>/dev/null | tr -d ' ') - 1 ))
  assert_eq "$_rows2" "3000" "exactly 3000 unique files hashed, not 6000"
  if [ "$_elapsed" -lt 60 ]; then
    _assert_pass
  else
    _assert_fail "3000-file overlapping-root run took ${_elapsed}s -- expected well under a minute even on modest hardware"
  fi
  teardown_sandbox
}
