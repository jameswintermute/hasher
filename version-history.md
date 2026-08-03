# Version History
Contact: **jameswintermute@protonmail.ch**
---
## 2022‑12‑14 — v0.0.1  
Initial prototype  
- Created as a SANS DFIR exercise  
- Single-script SHA‑1 hashing  
- Basic CSV output  
- No dedupe logic  
---
## 2023–2024 — v0.x.x Series  
Foundation era  
- Multi-root hashing introduced  
- `paths.txt` added  
- Improved CSV structure  
- Early duplicate grouping  
- **Legacy note:** hashing was SHA‑1; later converted to SHA256-compatible format  
---
## 2025‑03 → 2025‑07 — v1.0.0  
First structured release  
- Full repo reorganisation (`bin/`, `logs/`, `local/`)  
- New launcher  
- Background hashing (nohup-safe)  
- File/folder dedupe model  
- Quarantine workflow  
---
## 2025‑08 — v1.0.5 – v1.0.8  
Feature expansion  
- Interactive duplicate reviewer  
- Order modes, ETA, progress bars  
- Zero-length scanner  
- Folder dedupe pipeline  
- Legacy CSV converter  
---
## 2025‑09 — v1.0.9  
Safety + exceptions  
- Hash exceptions list (`local/exceptions-hashes.txt`)  
- "A = add to exceptions" in review  
- Safer numeric input loop  
- Run-ID stamping  
---
## 2025‑10 — v1.1.0 – v1.1.2  
Performance & stability  
- Faster hashing on BusyBox  
- System check module  
- Log follower  
- Improved @eaDir cleaner  
- Initial junk cleaner  
---
## 2025‑11 — v1.1.3  
Junk + exception overhaul  
- `excluded-from-dedup.txt` model  
- Junk cleaner with size columns  
- Menu consolidation  
- SHA256 lookup tool  
- Concurrency guard for hash runs  
- Config cleanup  
- Stats & cron templates  
---
## 2025‑11 — v1.1.4  
**Milestone release — production-proven**  
- Full pipeline validated on real NAS  
- Successfully deduped **19,000+ files** safely  
- Review‑duplicates hardened with size fallback + "??" handling  
- Better warnings for unreachable paths  
- Large-scale junk cleanups validated  
- README and documentation rewritten for GitHub  
- Project now considered *stable & production ready*
---
## 2026‑02 — v1.1.5  
**Codebase audit & correctness pass** *(assisted by Claude/Anthropic)*

### Bug fixes
- **`launch-review.sh`** — critical fix: `exec review-duplicates.sh "$dups_csv"` was passing the report path as a bare positional argument, which `review-duplicates.sh` silently ignored, causing it to fall back to its default report path. Fixed to `exec review-duplicates.sh --from-report "$dups_csv"`. Menu option 4 now reliably uses the correct report.
- **`launcher.sh`** — SHA256 validation regex tightened (`grep -qE '^[0-9a-fA-F]{64}$'` with anchors, preventing false positives on longer strings); `apply-file-plan.sh` legacy fallback removed from plan-apply path — `delete-duplicates.sh` is now the sole executor; pidfile-based process detection replaced the fragile `ps | grep` approach for concurrency guard; `action_apply_plan()` rewritten to surface both file and folder plans correctly; `sample_files_quick()` safety-capped at 10,001 lines; `action_clean_internal()` consolidated from 3 `find` passes to 1.
- **`hasher.sh`** — all working directory paths (`HASHES_DIR`, `LOGS_DIR`, `ZERO_DIR`) were relative strings (`"hashes"`, `"logs"`, `"zero-length"`) which caused files to be created in the wrong location when the script was called from outside the repo root. All paths now anchored to `ROOT_DIR`. Config autoload updated to prefer `local/hasher.conf` then `default/hasher.conf` (was looking for `./hasher.conf`).
- **`review-duplicates.sh`** — file size display restored for all sort modes (was broken for name/newest/oldest/shortpath/longpath); missing counter increment fixed (files displayed as `0)` instead of numbered); `wc -l | tr -d ' '` replaced with `awk 'END{print NR}'` for BSD/BusyBox portability; `cat | sort` antipattern removed; `grab_N()` robustness improved with awk regex fallback.

### Working file locations corrected
- `FILES_LIST` (`files-$RUN_ID.lst`) moved from `logs/` → `var/`
- `ZERO_PROGRESS_FILE` (`zero-scan-$RUN_ID.count`) moved from `logs/` → `var/`
- `ZERO_DIR` consolidated from repo root `zero-length/` → `var/zero-length/`

### Dead code removed
- `bin/review-batch.sh` — circular self-reference; header named wrong file; not called by any script
- `bin/schedule-hasher.sh` — superseded by launcher option 13 (inline cron templates)
- `bin/lib_paths.sh` — defined path variables but was not sourced by any script; used `BASH_SOURCE[0]` making it incompatible with `sh` scripts anyway
- `bin/review-latest.sh` — thin wrapper superseded by `launch-review.sh`
- `bin/apply-file-plan.sh` — format incompatible with current plan format (`DEL|path` vs raw path); launcher already preferred `delete-duplicates.sh`
- `bin/csv-dedupe-by-path.sh` — unreferenced standalone utility

### New features
- **Launcher option 15 — Clean logs** — wires `bin/clean-logs.sh` into the launcher menu for log rotation and pruning of old hash CSVs, run logs, and dedupe plans

### Consistency
- Standardised file header applied to all 16 shell scripts: `#!/bin/bash` shebang, project name, copyright, licence, and warranty disclaimer in a consistent 5-line block. Previously scripts used a mix of `#!/bin/sh`, `#!/usr/bin/env bash`, inconsistent or missing copyright lines, and script-specific comments appearing before the copyright block.

---
## 2026‑04 — v1.1.6
**apply-folder-plan: collision-proof quarantine naming** *(assisted by Claude/Anthropic)*

### Bug fix
- **`apply-folder-plan.sh`** — destination slot now derived from the full
  source path (leading `/` stripped, remaining `/` replaced with `__`) rather
  than just `basename`.  Previously, multiple sibling directories sharing the
  same name (e.g. several `RAW/` subdirectories under different parent paths)
  would collide in the flat quarantine root: the first `mv` succeeded, then
  every subsequent `mv` of a same-named dir failed with
  `Directory not empty`.  The flattened-path scheme makes every destination
  unique regardless of basename, so all planned moves now succeed.

---
## 2026‑04 — v1.1.7
**Auto-dedup: non-interactive keep-shortest-path mode** *(assisted by Claude/Anthropic)*

### New feature
- **`bin/auto-dedup.sh`** — new script that generates a dedup plan for all
  duplicate groups without any interactive prompts.  For each group, a single
  copy is selected to keep according to the chosen strategy; all others are
  written as `DEL|path` entries in a plan file compatible with
  `delete-duplicates.sh`.  Keep strategies: `shortest-path` (default),
  `longest-path`, `newest`, `oldest`.  Respects `local/exceptions-hashes.txt`.
  Supports `--dry-run` to preview decisions without writing a plan file.
- **`bin/launcher.sh`** — option 16 added under Stage 3 (Clean up):
  "Auto-dedup (keep shortest path — no prompts)".  Presents a brief strategy
  selector before calling `auto-dedup.sh`.  Version string bumped to v1.1.7.

---
## 2026‑04 — v1.1.8
**README rewrite + apply-plan UX fix** *(assisted by Claude/Anthropic)*

### Changes
- **`readme.md`** — full rewrite: stale script references removed, correct clone
  URL, current launcher menu reproduced, recommended workflows for both
  auto-dedup (option 16) and interactive review (option 4), plan file format
  documented, troubleshooting entry added for option 6 / auto-dedup plan
  detection, cross-reference to hasher-py added.
- **`bin/launcher.sh`** — version string bumped to v1.1.8.

---
## 2026‑05 — v1.1.9
**Cross-platform hardening + plan-format fix** *(assisted by Claude/Anthropic — Opus 4.7)*

### Critical bug fixes

- **`bin/find-duplicates.sh`** — `--mode bulk` now produces a plan file
  compatible with `delete-duplicates.sh`. Previously bulk mode wrote
  bare paths (one per line) but `delete-duplicates.sh` only acts on
  lines matching `^DEL|`, so the apply step silently treated every plan
  as empty and exited with `"No DEL entries found in plan (nothing to
  do)"`. Now emits proper `KEEP|path` and `DEL|path` markers, honouring
  the `--keep-strategy` flag (`shortest-path` default, `longest-path`
  also supported in awk; mtime-based strategies remain in
  `auto-dedup.sh` because they need stat()).

- **`bin/delete-zero-length.sh`** — quarantine mode no longer collides
  on duplicate basenames. Previously `mv` used `basename "$f"` as the
  destination, so two empty files with the same name in different
  directories (e.g. `/dirA/empty.log` and `/dirB/empty.log`) would
  overwrite each other in the flat quarantine root. Same fix pattern
  as v1.1.6 applied to `apply-folder-plan.sh`: strip leading `/` and
  replace remaining `/` with `__`, encoding the full path in a flat
  collision-free name.

- **`bin/apply-folder-plan.sh`, `bin/delete-zero-length.sh`** — replaced
  bash-4-only `${var,,}` parameter expansion with portable
  `tr '[:upper:]' '[:lower:]'`. `${var,,}` is a parse error (not just
  a runtime error) on bash 3.2, which means the affected scripts would
  not start at all on stock Synology DSM (default bash 3.2.57) or on
  macOS `/bin/bash` (frozen at 3.2.57). The same scripts already used
  the portable idiom elsewhere; this restores consistency.

### Cross-platform / host-awareness

- **`lib/host-detect.sh`** — new POSIX-sh-safe sourceable helper.
  Detects `synology` / `macos` / `linux` / `unknown` and exposes:
    - `default_quarantine_root` — Synology gets
      `/volume1/hasher/quarantine-DATE`; everywhere else gets
      `<repo>/quarantine-DATE`. No more dead `/volume1` paths on Macs.
    - `host_default_excludes` — adds OS-specific noise dirs to the
      hasher excludes: `@eaDir/@tmp/@SynoFinder-log` on Synology;
      `.Spotlight-V100/.Trashes/.fseventsd/.DocumentRevisions-V100/`
      `.TemporaryItems/.DS_Store/.AppleDouble` on macOS.
    - `host_default_scan_root` — sensible fallback when no `paths.txt`
      exists: `/volume1` on Synology, `$HOME` on macOS/Linux.
    - `host_pretty_label` — shown in the launcher header.

- **`launcher.sh`** — sources `lib/host-detect.sh`, prints the detected
  host in the header, replaces the hardcoded
  `--exclude "#recycle" --exclude "@Recycle" --exclude "@RecycleBin"`
  with `host_default_excludes` output (covers the legacy three plus
  host-specific additions), and replaces the `default_root="/volume1"`
  in `action_clean_caches` with `host_default_scan_root`.

- **`bin/delete-zero-length.sh`** — `--scan` mode no longer hardcodes
  `find /volume1 …` as the fallback when no paths file exists. Uses
  `host_default_scan_root` instead, so on macOS or generic Linux the
  fallback is `$HOME` rather than a non-existent path that returns no
  results silently.

- **`bin/apply-folder-plan.sh`** — quarantine fallback now uses
  `default_quarantine_root` from the host-detect lib.

- **mktemp portability** — `bin/delete-zero-length.sh` now uses the
  `mktemp "${TMPDIR:-/tmp}/zero-list.XXXXXX"` form, which behaves the
  same way on GNU mktemp (Linux/Synology/BusyBox) and BSD mktemp
  (macOS); the previous `mktemp -t zero-list.XXXXXX` form has subtly
  different semantics between the two implementations.

### Stale code removed

The following files were marked as removed in the v1.1.5 release notes
but had been reintroduced or never actually deleted:

- `bin/launcher.sh` — out-of-date v1.1.5 copy of the launcher; missing
  option 16 (auto-dedup) and the multi-source plan resolution. Anyone
  who ran `bin/launcher.sh` instead of `./launcher.sh` got a stale
  menu silently.
- `bin/review-batch.sh` — circular self-reference per v1.1.5 audit;
  also used bash-4 `${RESUME,,}` which would prevent it from running
  on Synology DSM or macOS regardless.
- `bin/review-latest.sh` — thin wrapper superseded by `launch-review.sh`.

### Other consistency fixes

- **`bin/check-deps.sh`** — directory check updated from
  `$ROOT_DIR/zero-length` to `$ROOT_DIR/var/zero-length` (the former
  was relocated in v1.1.5 but this script's check was missed and
  recreated an empty stale dir at the repo root every system check).
  Also now reports the detected host class.

- **`default/hasher.conf`** — version bumped from `v1.0.0` (eight
  versions stale) to `v1.1.9`. The hardcoded
  `QUARANTINE_DIR="/volume1/hasher/quarantine-$(date +%F)"` is now
  commented out by default — the host-detect lib derives a sensible
  default per host. Users who want the legacy Synology path can
  uncomment one line.

---
## 2026‑05 — v1.1.10
**macOS hardening: fail-loud on missing paths + bash 3.2 array safety** *(assisted by Claude/Anthropic — Opus 4.7)*

Patches issues uncovered during real-world macOS testing of v1.1.9.
Symptom: hasher.sh appeared to "silently fail" when run against a
mount point that wasn't actually mounted (e.g. external USB disk
plugged in but not yet mounted by Finder). Investigation found three
distinct issues, all addressed here.

### Bug fixes

- **`bin/hasher.sh`** — array-expansion safety under `set -u`. The line
  `local patterns=("${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}")`
  raised `EXTRA_EXCLUDES[@]: unbound variable` and aborted hasher.sh
  whenever it was invoked with no `--exclude` flags. This is a known
  bash 3.2/4.0–4.3 quirk: `${arr[@]}` on an empty (but declared) array
  is treated as unbound under `nounset`. The launcher always passes
  several `--exclude` flags so it never tripped this; direct
  invocations of `bin/hasher.sh` did. Fixed by adding the `:-` guard
  (`"${arr[@]:-}"`) and filtering the empty-string sentinel that
  produces. Apple's stock `/bin/bash` is permanently 3.2.57; same
  applies on Synology DSM.

- **`bin/hasher.sh`** — fail-loud when all paths are missing.
  Previously, if every path in `local/paths.txt` referred to something
  that didn't exist (the use case: external drive not mounted, NAS
  share offline, typo in volume name), each one warned, the script
  continued, found 0 files post-exclude, and reported
  `"Hashed 0/0 files"` as if it had succeeded. That looked
  indistinguishable from a hang or a silent failure. Hasher.sh now
  tracks how many paths.txt entries were valid and exits with code 3
  and a clear error message ("All N path(s) listed in paths.txt are
  missing or unreadable") if none resolved. Stdin-piped invocations
  are exempt (we can't tell a legitimately-empty stream from an
  all-missing one).

- **`launcher.sh`** — robust post-spawn detection. The previous check
  was `tail -n 5 logs/background.log | grep -q 'Run-ID:'` after a
  1-second sleep. On a fast or zero-file run (which now includes the
  new "all paths missing" exit above), hasher.sh completes in well
  under a second; by the time the launcher tails, the log has
  scrolled past the Run-ID line into the recommended-next-steps
  block, the grep fails, and the launcher warns "Hasher may not be
  running" for a process that already finished cleanly. Now searches
  the last 200 log lines for Run-ID *or* Run-complete markers, and
  also detects the new path-error exit and surfaces it as a hard
  error with the offending paths listed.

- **`launcher.sh`** — explicit warning on zero-file completion. When
  hasher.sh runs but produces a 0/0 result (e.g. all files were
  excluded, or paths.txt was empty), the launcher now displays a
  clear warning rather than letting the user think the run succeeded
  silently.

### Cosmetic fixes

- **`lib/host-detect.sh`** — removed the broken `'Icon\r'` macOS
  exclude pattern. Intent had been to skip macOS's custom-folder-icon
  metadata files (literally named `Icon` followed by a CR byte), but
  the current `--exclude` framework does literal substring match on
  cooked path strings and can't match a CR byte through shell quoting.
  The pattern was passing through as the four literal characters
  `\`, `r`, etc., never matching anything. Excluding by `Icon` alone
  would over-match (any path containing the substring 'Icon'
  anywhere). Better to leave these in the catalog and let the dedup
  pipeline handle them naturally.

- **`launcher.sh`, `default/hasher.conf`** — version strings bumped to
  v1.1.10.

---
## 2026‑05 — v1.1.11
**find-failure resilience: don't let one bad path kill the run** *(assisted by Claude/Anthropic — Opus 4.7)*

Patches a real-world silent-death bug uncovered during further macOS
testing of v1.1.10. Symptom: hasher.sh died silently with no error
message between the "Working dir:" log line and any subsequent output,
exiting with status 1, leaving no diagnostic trail in
`logs/background.log`. The v1.1.10 fail-loud-on-missing-paths fix did
not fire because the path in question *did* satisfy `[[ -d ]]` — but
`find` couldn't actually walk it.

### Bug fix

- **`bin/hasher.sh`** — `find "$path" -type f -print0` previously had
  no failure handling. Under `set -e`, any non-zero exit from `find`
  (most commonly: I/O error descending into an unmounted volume stub,
  or permission denied on a subtree) terminated the entire script
  silently — no error log line, no warning, no exit-trap diagnostic.
  This was particularly brutal on macOS 26 where failed external
  volume mounts leave empty stub directories under `/Volumes/` that
  satisfy `[[ -d ]]` but cause `find` to error on descent (the
  filesystem is technically present in the VFS but has no mounted
  backing storage).

  Now wraps the `find` call in a status-capturing idiom
  (`find ... || find_status=$?`) that converts find's non-zero exit
  into a logged WARN rather than a script-killing error. The path
  is treated as invalid for the purposes of the "all paths missing"
  check, so a paths.txt where every entry triggers a find failure
  still produces the v1.1.10 fail-loud exit code 3 rather than
  silent death.

  Affects any host where a path can be `-d` true but unreadable.
  macOS phantom mount points are the most common trigger; permission-
  denied subtrees on locked-down Linux/Synology shares are the
  second most common.

### Other

- **`launcher.sh`, `default/hasher.conf`** — version strings bumped
  to v1.1.11.

---
## 2026‑05 — v1.1.12
**BSD awk portability: find-duplicate-folders works on macOS** *(assisted by Claude/Anthropic — Opus 4.7)*

Patches an awk portability issue uncovered while running option 2
(Find duplicate folders) on macOS. Symptom: hard awk crash with
`extra ] at source line 27` and `nonterminated character class [^`
the moment the embedded awk program tried to parse the regex that
extracts basename and directory from a path. Worked on GNU awk
(Synology BusyBox, Linux); failed on BSD awk (macOS stock
`/usr/bin/awk`, one-true-awk lineage).

### Bug fixes

- **`bin/find-duplicate-folders.sh`** — the regex `/[^/]*$/` (match
  the trailing path segment with no slashes) contains a literal `/`
  inside a character class inside a `/.../`-delimited regex. BSD awk
  parses the inner `/` as end-of-regex and chokes on the remainder
  as broken syntax. GNU awk and mawk both accept it. The POSIX-
  portable form is to escape the inner slash: `/[^\/]*$/`. Single
  character change, no semantic difference. Verified to produce
  identical results on GNU awk; now also works on macOS BSD awk.

- **`bin/find-duplicate-folders.sh`** — same script had
  `/^path,/i` for case-insensitive header detection. The trailing
  `i` flag is Perl/grep flavour; neither GNU nor BSD awk supports
  it. The expression has been silently always-false in production
  (any CSV with the literal lowercase `path,` header still worked,
  because the regex matched literally; uppercase headers would
  have been treated as data rows). Replaced with the portable
  idiom `tolower(t) ~ /^path,/` which does what was intended.

### Other

- **`launcher.sh`, `default/hasher.conf`** — version strings bumped
  to v1.1.12.

### Pattern recognition

This is the fourth round of cross-platform portability fixes since
v1.1.9. The pattern is consistent: code written assuming GNU/Linux
userland behaviour, tripping on macOS's older BSD-derived equivalents.
v1.1.9 was bash 4 `${var,,}`; v1.1.10 was bash 3.2 array-under-`set -u`;
v1.1.11 was `find` exit-code under `set -e`; v1.1.12 is BSD awk regex
character classes and case flags. Scripts not yet exercised on macOS
in real-world testing (review-duplicates, delete-junk, delete-zero-
length when called against large trees) may still hold similar latent
issues.

---
## 2026‑06 — v1.1.13
**Menu refresh + interactive folder-plan reviewer + scope statement** *(assisted by Claude/Anthropic — Opus 4.7)*

The menu numbering had accumulated history rather than design — options
were added one at a time, each grabbing the next free number, until 0, 1,
8, 16, 5, 6, 10, 11 sat side-by-side with no logic to them. This release
rebuilds the menu around workflow order, adds letter shortcuts for meta
and infrequent operations, and ships a new interactive reviewer for
folder-dedup plans.

### New: interactive folder-plan reviewer (`bin/review-folder-plan.sh`)

Folder dedup previously produced a plan and prompted the user to run
option 6 (apply). The apply step asked "proceed? y/N" without showing
*what* it was about to do — totals only, no per-group context, no way
to spot-check. Users had to trust the plan blind.

The new reviewer (menu option `r`, or auto-launched at the end of option
3) walks the user through each duplicate-folder group:

- Shows KEEP and DEL directories with file counts and sample filenames
- Allows per-group decisions: accept, skip, swap keeper, or quit early
- `[d]` option shows the full file-by-file listing for the group
  (paged through `less` if available)
- `[a]` option applies the last decision to all remaining groups
  (e.g. "I've eyeballed the first 5; rubber-stamp the rest with yes")
  with a confirmation prompt
- Verbose per-group decision logging plus an end-of-review summary
  totalling decisions by type
- Writes a reviewed plan to
  `logs/duplicate-folders-plan-reviewed-DATETIME.txt`, preserving the
  original raw plan for audit

The reviewer's plan output is compatible with the existing
`apply-folder-plan.sh` — one directory per line, all listed get
quarantined, the unlisted entry per group is the implicit keeper.

### New: groups TSV sidecar

`bin/find-duplicate-folders.sh` now persists the per-group decision
context as `logs/duplicate-folders-groups-DATE.tsv` alongside the plan.
This is what the reviewer consumes; it has the keeper+del pairings and
reclaim sizes that the raw plan format lacks.

### Menu rewrite

Numbers reserved for the core workflow, in workflow order:

```
Stage 1 — Hash:    1   (a, s for variants)
Stage 2 — Identify: 2, 3   (f for hash lookup)
Stage 3 — Clean:    4, 5, 6, 7, 8, 9   (r for folder review)
Other:              d, l, t, v, c, q
```

Notable changes from the old menu:

- Option **2** now means "find duplicate FILES" (was option 3); option
  **3** means "find duplicate FOLDERS" (was option 2). The workflow
  recommendation puts files first because that's the more common task;
  folder dedup is the higher-leverage option but used less often.
- Option **5** is now auto-dedup (was option 16). Plain `5` reads better
  than `16` and groups it with the other clean-up options.
- Option **0** ("Check hashing status") is now letter **s**.
- Option **7** ("System check") is now letter **d** (diagnostics; `?`
  was rejected because users hit it expecting "help").
- Options 9–15 dropped — replaced with letter shortcuts grouped under
  Other: `l` (follow logs), `t` (stats & cron), `v` (clean var/),
  `c` (clean logs).

### Apply step: prefer reviewed plans, warn on raw

`launcher.sh` action_apply_plan now distinguishes between raw and
reviewed folder plans. If both exist, the reviewed one is preferred
automatically. If only a raw plan exists, applying it triggers an
explicit "this plan has NOT been reviewed, proceed without review?"
confirmation prompt. The intent is to make review the natural path
without forcing it.

### README rewrite

A new **Scope** section near the top makes the project's narrow remit
explicit:

> Hasher is a content-integrity tool. It catalogues files by SHA-256
> hash, identifies duplicates, removes them safely (quarantine-first),
> and produces a CSV that other tools can use for downstream analysis
> — including silent-deletion detection. Hasher is deliberately narrow.
> Workflow tooling that consumes Hasher's CSV is out of scope and
> belongs in separate projects.

The launcher menu, directory tree, and workflow recommendations have all
been updated to match v1.1.13.

### Other

- **`default/hasher.conf`** — version bumped to v1.1.13. (This also
  catches the v1.1.11 and v1.1.12 conf bumps that were missed at the
  time, restoring sync between conf and launcher version strings.)
- Helper scripts (`auto-dedup.sh`, `launch-review.sh`,
  `run-find-duplicates.sh`) updated to reference the new option numbers.

---
## 2026‑06 — v1.2.0
**Parallel hashing + just-in-time re-verification + dedup correctness fix** *(assisted by Claude/Anthropic — Opus 4.8)*

A minor-version bump because two of the three changes alter behaviour
in ways worth flagging: hashing can now run in parallel, and the dedup
plan format gained a third field. Both are backward compatible.

### Parallel hashing (item 4 — was in the earliest xargs-based designs)

`bin/hasher.sh` previously hashed strictly one file at a time, forking
three processes per file (two `stat`, one hash binary). On large
small-file corpora (photo libraries) that fork overhead — not the
hashing itself — dominated wall-clock. A benchmark of 2,000 tiny files
showed ~11s serial vs ~0.1s with `xargs -P4`.

The hashing loop now fans the file list out to N workers via `xargs -P`
when `HASH_JOBS > 1`. `HASH_JOBS=1` preserves the exact historical
serial path with no `bash -c` overhead. Workers emit CSV rows whose
single-`printf` writes stay under PIPE_BUF, so rows from concurrent
workers never interleave; failures are counted via a sentinel channel.
Verified: serial and parallel produce byte-identical hash sets,
including filenames with spaces and embedded quotes.

Controls:
- `--jobs N` flag on hasher.sh
- `[performance] jobs = N` in hasher.conf
- `HASH_JOBS` environment variable
- **New launcher menu option `p` (Performance settings)** — interactive
  picker (serial / recommended / aggressive / custom), persisted in
  `var/jobs.conf`, with core detection and HDD-thrashing guidance.
  Default remains conservative (serial) so nothing changes unless the
  user opts in.

### Just-in-time re-verification before quarantine (item 1b)

Previously the pipeline hashed at T0, planned at T1, and applied at T2 —
potentially days apart — and `delete-duplicates.sh` checked only that a
file still *existed* before quarantining it, never that its content
still matched the hash that justified calling it a duplicate. A file
modified between plan and apply would be quarantined on stale data.

The dedup plan format now carries the expected hash as a third field:
`DEL|path|expectedhash`. At apply time, `delete-duplicates.sh` re-hashes
each candidate and **skips any whose content no longer matches**,
reporting expected vs actual. This closes the stale-plan window — and
does so cheaply, re-hashing only the handful of files about to be
deleted rather than the whole corpus.

All four plan producers updated to emit the hash: `auto-dedup.sh`,
`find-duplicates.sh` (bulk mode), `review-duplicates.sh` (both delete-all
and keep-one paths). Old-format plans (`DEL|path`, no hash) are still
accepted — `delete-duplicates.sh` warns once and falls back to the
existence check. Verified across three scenarios: unchanged file
quarantines normally; changed file is skipped and protected; old plan
falls back cleanly.

### Dedup grouping correctness fix (item 2)

`bin/find-duplicates.sh` used `grep -F -f "$HASHES_TMP" "$TMP"` to keep
rows belonging to duplicate hashes. `grep -F` matches each hash as an
unanchored substring against the whole line — including the *path*
column. Content-addressed files (git objects, nix/ipfs stores,
hash-named thumbnail caches, dedup backups) can have a hash string
embedded in their path, which would pull unrelated rows into a duplicate
group and silently corrupt the grouping. Replaced with an `awk` join
keyed strictly on the hash column. Verified with a collision case: a
file named `/cache/aaaa1111.dat` (content hash `bbbb2222`) is no longer
mis-grouped with the real `aaaa1111` duplicates.

### Other

- **`default/hasher.conf`** — version bumped to v1.2.0, finally syncing
  the conf version string with the launcher (it had drifted at v1.1.10
  through three releases). New `[performance]` section documents `jobs`.
- Portability: avoided a bash-4 `${kind^}` that slipped into the new
  parallel failure-reporting path; replaced with the plain value.

---
## 2026‑06 — v1.2.1
**Folder reviewer swap-prompt fix** *(assisted by Claude/Anthropic — Opus 4.8)*

Found during real-world folder-dedup review on a 280,944-file NAS corpus
(238 duplicate groups). The `[s] Swap keeper` option required pressing
Enter twice to take effect.

### Bug fix

- **`bin/review-folder-plan.sh`** — `prompt_swap_choice()` is invoked
  inside a `$(...)` command substitution (`chosen="$(prompt_swap_choice "$i")"`),
  so everything it wrote to stdout was captured as the return value —
  including the menu text and the "Choice:" prompt. Two consequences:
  the prompt never appeared live (the user was effectively typing blind,
  which felt like needing a second Enter), and the captured `$chosen`
  contained the whole menu string plus the number rather than just the
  number. Downstream numeric validation masked the second problem, so
  swaps still worked — but awkwardly.

  Fixed by sending all human-facing UI (menu, prompt) to stderr (`>&2`)
  and writing only the chosen number to stdout. The prompt now appears
  immediately and a single Enter advances. Verified end-to-end: a 3-way
  group swap correctly leaves the chosen folder as the implicit keeper
  and lists the other two for quarantine.

### Note for a future iteration

Real-world use surfaced an asymmetry worth recording: the v1.2.0
just-in-time content re-verification protects the FILE dedup path
(`delete-duplicates.sh` re-hashes each candidate before quarantine) but
NOT the FOLDER dedup path (`apply-folder-plan.sh` moves whole directory
trees without re-verifying their contents against the groups TSV). For
folder plans the matching is by content signature so coincidental
false-positives are unlikely, but a folder whose contents changed
between hashing and applying would still be moved. A symmetric fix —
re-verifying folder contents before the move — is a candidate for a
later release.

---
## 2026‑06 — v1.2.2
**Stateful folder review + high-fidelity audit log** *(assisted by Claude/Anthropic — Opus 4.8)*

Addresses a workflow gap found applying folder dedup across multiple
sessions on the 280k-file NAS corpus: after applying a reviewed plan to
~20 folders and returning later, the reviewer looped back to group 1,
re-presenting groups whose duplicates had already been quarantined. It
had no awareness of what had already been done.

### Design principle: logs record, disk decides

The fix deliberately does NOT read a log to decide what to skip. A log
that is read back to drive a root-running bulk-deletion tool becomes a
forgeable control input — a line injected into the log could steer
deletions. Instead:

- **The disk is the source of truth.** The reviewer checks whether each
  group's DEL folder still exists at its original path. If it's gone
  (quarantined in a prior session, or removed by any other means) there
  is nothing left to quarantine, so the group is auto-skipped. This fact
  cannot be forged by editing a log.
- **The log is write-only.** A new high-fidelity audit log records what
  was done, for humans and audit — and is never read back by the tool.

### `bin/review-folder-plan.sh` — stateful skip

- At startup, pre-scans all groups against current disk state and reports
  e.g. "18 of 238 group(s) already applied (DEL folders gone) — these
  will be skipped. 220 group(s) remain to review." This explains why the
  walk may start partway through the list.
- Groups whose DEL folders are all gone are auto-skipped (decision
  recorded as `already_done`, never written to the reviewed plan).
- The `[a]` apply-last-to-all path also skips already-gone groups rather
  than re-listing absent folders for quarantine.
- End summary gains an "Already applied" line, separate from accept /
  skip / swap / not-reviewed, with corrected quit-early arithmetic.

### `bin/apply-folder-plan.sh` — audit log + counter fix

- Writes a single persistent `logs/folder-actions.log` (no per-run log
  spread). Tab-separated records: ISO-8601 UTC timestamp, action
  (QUARANTINED / DELETE_METADATA / *_FAILED), source, destination,
  size in KB — preceded by a human-readable per-session header. This is
  the high-fidelity audit trail; the tool never reads it back.
- Fixed a latent counter bug: the success path called the `ok()` helper
  but never incremented the move counter, so "Moved: N" always reported
  0. Now reports the true count.

### Still deferred

Folder-content re-verification before the move (the file-path equivalent
landed in v1.2.0) remains a candidate for a future release. The v1.2.2
skip logic keys on folder *presence*, not content; a folder still present
but changed since hashing would still be actioned.

---
## 2026‑06 — v1.2.3
**Critical fix: reviewed folder plans now actually apply** *(assisted by Claude/Anthropic — Opus 4.8)*

Found in real use: after reviewing ~35 folder groups and choosing to
apply, **nothing arrived in quarantine**. The folder dedup apply step
was silently doing nothing for reviewed plans.

### Root cause

`review-folder-plan.sh` writes its reviewed plan with an 8-line
`#`-prefixed comment header (provenance + format notes). But
`apply-folder-plan.sh` read the plan without skipping comment lines.
The failure chain:

1. The `du` size-estimate loop ran `du` on a non-existent path named
   `# Reviewed folder dedup plan`, which returned an empty size.
2. The accumulator `du_total_k=$((10#${kb:-0}))` with an empty `kb`
   is a fatal bash arithmetic error (`10#` followed by nothing).
3. Under `set -Eeuo pipefail`, that error **terminated the entire
   script before the move loop ran** — so not a single folder was
   moved, and the quarantine directory was created but left empty.

Raw plans (from `find-duplicate-folders.sh`) have no comment header, so
they applied fine — which is why this stayed hidden until reviewed plans
were applied at scale. The mismatch was introduced in v1.1.13 when the
reviewer began writing the comment header, but the apply step was never
taught to skip it.

### Fix

- **`bin/apply-folder-plan.sh`** — the plan is now normalised once into a
  comment-free, blank-free temporary file (`PLAN_CLEAN`), and every
  downstream read (directory count, metadata scan, `du` estimate, move
  loop) uses it. The move loop also skips `#` lines defensively. The
  `du` accumulator is hardened against empty/non-numeric sizes so a
  vanished path can never again abort the run via arithmetic error.

### Verified

- Reviewed plan (with comment header): both folders correctly moved to
  quarantine; "Moved: 2 | Failed: 0"; quarantine populated; originals
  gone. Previously: silent no-op, empty quarantine.
- Raw plan (no header): still works (regression check).
- Audit log accumulates correctly across both session types.

### Also

- **`default/hasher.conf`** — version string synced to v1.2.3 (it had
  been left at v1.1.10 in the live repo despite the v1.2.0 sync; the
  `[performance]` section documenting parallel `jobs` was also missing
  and has been restored).

---
## 2026‑06 — v1.2.4
**Quarantine lives beside the tool (no more hardcoded /volume1/hasher)** *(assisted by Claude/Anthropic — Opus 4.8)*

Surfaced when a user who had moved their install to /volume1/Tools/hasher
found their quarantine directories at the old /volume1/hasher path
instead — and had to go hunting for where quarantined data had gone.

### Root cause

`lib/host-detect.sh`'s `default_quarantine_root()` special-cased
Synology to a hardcoded `/volume1/hasher/quarantine-DATE` — a legacy
default from before installs lived anywhere else. Every other host
already used an install-relative `$ROOT_DIR/quarantine-DATE`. Once the
tool was moved out of /volume1/hasher, the quarantine target didn't
follow it: data was quarantined to a fixed path unrelated to where the
tool actually lived. For a tool whose safety model is "moved, not
deleted — recoverable," the user not knowing where "moved" went
undermines the guarantee.

### Fix

- **`lib/host-detect.sh`** — `default_quarantine_root()` now returns
  `$ROOT_DIR/quarantine-DATE` on **every** host, including Synology. The
  quarantine always lives beside the tool that created it. Verified: a
  Synology install at /volume1/Tools/hasher now quarantines to
  /volume1/Tools/hasher/quarantine-DATE.
- This automatically corrects every consumer that resolves quarantine
  via `default_quarantine_root()`: `apply-folder-plan.sh` (folder dedup)
  and `delete-zero-length.sh`. Stale comments in both updated.
- `delete-duplicates.sh` (file dedup) was already install-relative
  (`$ROOT_DIR/quarantine`) and was never affected — so all three
  quarantine paths are now consistent.
- **`default/hasher.conf`** — quarantine documentation updated to
  describe the install-relative default. Users wanting a fixed location
  can still set `QUARANTINE_DIR` explicitly.

### Migration note

Any existing quarantine directories under the old `/volume1/hasher/`
path can be moved or deleted at the user's discretion. (In this user's
case they were empty — a consequence of the separate v1.2.3 apply bug,
now fixed — so nothing needed migrating.)

---
## 2026‑06 — v1.3.0
**First-run guided setup** *(assisted by Claude/Anthropic — Opus 4.8)*

Until now a new user (or a fresh install) was dropped straight into the
full menu with no guidance — they had to know to run dependency checks,
set a performance level, and populate paths.txt before anything worked.
The conf carried a `first_run_help = true` key that nothing ever read.

### New: first-run detection + skippable guided setup

- **Detection** is by sentinel file `local/.setup-complete` (gitignored,
  per-install). Absent ⇒ first launch ⇒ offer guided setup. The sentinel
  is written whether the user completes OR skips, so the prompt appears
  on the first launch only and never on upgrade. Delete the file to see
  setup again.
- **The flow is fully skippable** — declining at the top still writes the
  sentinel and goes to the menu; every individual step can be skipped too.
  Everything remains reachable from the menu afterwards.

Four guided steps:
1. **Dependencies & readiness** — runs the existing `check-deps.sh`. If no
   sha256 tool is found, offers to create OpenSSL shims (`--fix`).
2. **Performance** — detects CPU cores, recommends `min(cores,4)`, persists
   to `var/jobs.conf` (same mechanism as the `p` menu).
3. **Scan paths** — if `paths.txt` has no real entries, prompts for one
   directory, validates it exists before appending, or lets the user skip
   and edit the file themselves later. No forced editor launch.
4. **Quarantine location** — shows where quarantine will be created (the
   v1.2.4 install-relative path), so the user knows where removed items
   go. Read-only reassurance, no change.

### Other

- **`default/hasher.conf`** — `[setup]` section now documents that the
  sentinel file is the real first-run mechanism; version → v1.3.0.

### Note

The sentinel lives in `local/` (persistent config), not `var/` (working
state), so "clean internal working files" (menu `v`) never accidentally
re-triggers onboarding.

---
## 2026‑06 — v1.3.1
**Critical: comma-in-filename data-loss fix + honest safety docs** *(assisted by Claude/Anthropic — Opus 4.8)*

Both items from an external code review. The first is a genuine data-loss
risk that had been latent in the core file-dedup path.

### Item 1 (critical) — CSV parsing broke on commas in filenames

`bin/find-duplicates.sh` parsed the hash CSV with `awk -F','` and fixed
field numbers, even though `hasher.sh` writes RFC4180 CSV that
double-quotes any path containing a comma. A file like
`"/photos/Smith, John.jpg",1024,...,sha256,<hash>` shifted every field:
the parser took the literal string `sha256` as the "hash" and truncated
the path at the first comma. Consequences, both serious:

- **Mis-grouping:** every comma-named file collapsed onto the same fake
  key (`sha256`) and was treated as a mutual duplicate regardless of
  real content.
- **Wrong delete plans:** generated `DEL|` lines pointed at truncated,
  non-existent paths (`/photos/Smith`) — a path that, if it happened to
  exist, would be the wrong file to quarantine.

The v1.2.0 re-verification offered only accidental protection (the
truncated path usually wouldn't exist, so the move was skipped) — luck,
not design.

**Fix:** replaced the naive split with a proper quote-aware (RFC4180)
CSV field parser in `find-duplicates.sh`, and switched the script's
internal intermediate format from comma-joined to TAB-separated so that
paths containing commas survive every downstream `awk` stage (the hash
join, the canonical/group render, and the bulk-plan emitter all updated).
Paths containing a literal tab are sanitised to a space in the
intermediate (tabs in filenames are vanishingly rare).

Verified with a regression matrix of pathological names — comma, double
quote, pipe, space, and leading-dash — each as an identical-content pair:
all four pairs grouped correctly on their real hash, plans carried
complete intact paths and correct hashes, and applying the plan
quarantined exactly the intended files while keepers survived.

### Item 4 (cheap) — README safety claim was stronger than the code

The README stated "Nothing is ever deleted outright. Every removal moves
files to a recoverable quarantine." That is true for **deduplication**
(the core workflow) but false for the **housekeeping helpers**:
`delete-zero-length.sh` deletes by default (with `--quarantine` opt-in),
and `delete-junk.sh` / cache cleaning use `rm`. The top-of-readme
safety note and the Safety Model section now state plainly that dedup is
quarantine-first and never deletes, while the housekeeping helpers delete
by default. (The over-strong wording was introduced in the v1.3.0 README
rewrite; this corrects it.)

### Still outstanding from the same review (not in this release)

- Item 2: "recursive" folder dedup matches leaf directories, not whole
  trees — the label overpromises. (Honest rename or true tree signatures.)
- Item 3: the launcher pidfile guard clears itself immediately (a subshell
  cannot `wait` a sibling), so the duplicate-run guard is illusory.
- Item 5: a stale duplicate `bin/host-detect.sh` carries the v1.2.4
  quarantine fix while the *sourced* `lib/host-detect.sh` still hardcodes
  `/volume1/hasher` — so the v1.2.4 fix is not actually in effect; plus
  some scripts lack the executable bit in the zip.

---
## 2026‑06 — v1.3.2
**Item 5: the v1.2.4 quarantine fix finally takes effect** *(assisted by Claude/Anthropic — Opus 4.8)*

External review found that the v1.2.4 "quarantine lives beside the tool"
fix had never actually been in effect, plus related release-hygiene drift.
Three linked problems, all fixed here.

### 1. The quarantine fix was in the wrong (unused) file

There were two `host-detect.sh` files. The v1.2.4 install-relative fix had
been applied to `bin/host-detect.sh`, but every script sources
`lib/host-detect.sh` — and that copy still hardcoded
`/volume1/hasher/quarantine-DATE` for Synology. So on a Synology install
moved out of `/volume1/hasher` (e.g. to `/volume1/Tools/hasher`),
quarantine was *still* being written to the old fixed path, exactly the
bug v1.2.4 was meant to cure. This is the same wrong-file class of error
as the conf-version drift (bumped conf landing in gitignored `local/`).

**Fix:** `lib/host-detect.sh` — `default_quarantine_root()` is now
install-relative on every host (`$ROOT_DIR/quarantine-DATE`), so the fix
is in the file that is actually loaded. Verified: a simulated Synology
install at `/volume1/Tools/hasher` now resolves quarantine to
`/volume1/Tools/hasher/quarantine-DATE`.

### 2. Deleted the stale duplicate helper

`bin/host-detect.sh` is removed. Nothing sourced it; keeping a
newer-looking duplicate of a sourced library is precisely what let the
v1.2.4 fix land in the wrong place and sit there unused. One canonical
`lib/host-detect.sh` remains.

> **Upgrade note:** because this *deletes* a tracked file, removing it must
> be done explicitly in the repo (a file upload won't delete it). Delete
> `bin/host-detect.sh` when committing this release.

### 3. Executable-bit resilience

`bin/auto-dedup.sh` and `bin/review-folder-plan.sh` shipped without the
executable bit in the zip, while the launcher gated them behind `[ -x ]`
and hard-failed otherwise — breaking auto-dedup (option 5) and folder
review on installs created via the GitHub web UI / zip upload (which does
not preserve +x, and where chmod on the NAS is awkward).

**Fix:** the exec bits are set in this release, AND the launcher no longer
depends on them. New `run_script` helper runs a helper directly when it is
executable, and otherwise falls back to `bash <script>` (after a
best-effort `chmod +x`). The `[ -x ]` gates became `script_runnable`
(executable *or* readable). Verified: with the +x bit stripped, folder
review and auto-dedup still run via the bash fallback.

### Still outstanding from the same review

- Item 2: "recursive" folder dedup matches leaf directories, not whole trees.
- Item 3: the launcher pidfile guard clears itself immediately (subshell
  cannot `wait` a sibling), so the duplicate-run guard is illusory.

A `bin/self-test.sh` preflight (checking exec bits, sourced-helper paths,
required commands, Bash version, and that every menu target is runnable)
would mechanically catch this whole wrong-file/missing-bit class of error
and is a strong candidate for a future release.

---
## 2026‑06 — v1.3.3
**Items 2 & 3: real duplicate-run guard + honest folder-scope label** *(assisted by Claude/Anthropic — Opus 4.8)*

The last two findings from the external review.

### Item 3 (high) — the duplicate-run guard was illusory

The launcher wrote a pidfile, then ran
`( wait "$bgpid" 2>/dev/null; clear_pidfile ) &` to clear it on exit. But a
subshell cannot `wait` on a sibling process: `wait` returned immediately,
so the pidfile was cleared within milliseconds of launch — while the hash
run continued for hours. `is_hasher_running()` therefore always reported
"not running", and the option-1 guard against starting a second concurrent
hash never fired. Reproduced directly: the cleanup fired at t≈0 with the
background process still alive.

**Fix:** pidfile ownership moved into `bin/hasher.sh`, the process that
actually runs. It writes its own PID (`$$`) at the start of `main()` and
removes the pidfile in its existing `cleanup()` EXIT trap (only if the file
still holds its own PID). The launcher still writes the pidfile immediately
on launch so the guard is active in the brief window before hasher.sh
claims it, but the broken subshell is removed. Verified: across a
multi-second real hash run the pidfile persisted in every poll while the
process was alive (previously: gone almost immediately) and was cleaned up
on completion.

### Item 2 (high) — "recursive" folder dedup was a misnomer

`--scope recursive` was accepted and displayed, but the tool fingerprints
each directory by its DIRECT file contents (basename + hash + size of the
files immediately inside it) and matches at the leaf level. Given `/A/sub`
and `/B/sub` with identical files it reports `/A/sub` vs `/B/sub`, never
`/A` vs `/B`. It does not build whole-tree signatures. The "recursive"
label overstated the behaviour.

**Fix (honest rename, not a behaviour change):** the default scope is now
`leaf-folders`, which accurately describes what happens. `recursive` is
still accepted as a deprecated alias (existing scripts/menus keep working)
but emits a one-time note explaining the misnomer. The info line now reads
"Scope: leaf-folders (matches directories by their direct file contents)".
The launcher passes `--scope leaf-folders` and prints a short explanation;
the README's What section and a new note in the folder-first workflow
describe leaf-level matching plainly (the previous "entire identical
directory trees" wording is corrected). For typical layouts
(`year/event/files`) leaf-level matching is the desired behaviour; true
whole-tree signatures remain a possible future feature, not a bug fix.

### Also — first-run cosmetic fix

First-run testing on the NAS showed raw `\033[0;36m` escape codes printing
literally during the dependency-check step. `bin/check-deps.sh` defined its
colour variables as single-quoted literals (`'\033[...]'` — the characters,
not real ESC bytes) and then emitted them with `printf "%s"` / plain `echo`,
neither of which interprets backslash escapes (and BusyBox `echo` on
Synology never does). Fixed by building real ESC bytes with
`printf '\033[...'`, matching the pattern used elsewhere. Audited the other
scripts: `apply-folder-plan.sh`, `delete-zero-length.sh`,
`find-duplicates.sh` and `hasher.sh` use `printf "%b"`, format-string
colours, or `echo -e` under a `#!/bin/bash` shebang, so they render
correctly — `check-deps.sh` was the only broken one.

### Review status

All five findings from the 2026-06-27 external review are now addressed:
item 1 (comma CSV parsing) and item 4 (safety docs) in v1.3.1; item 5
(quarantine wrong-file + exec bits) in v1.3.2; items 2 and 3 here. A
`bin/self-test.sh` preflight (exec bits / sourced-helper paths / required
commands / Bash version / menu-target runnability) remains the strongest
candidate for catching the recurring wrong-file/missing-bit class of error
before it reaches production.

---
## 2026‑06 — v1.3.4
**bin/self-test.sh — integrity preflight** *(assisted by Claude/Anthropic — Opus 4.8)*

Addresses the recurring meta-problem behind several earlier bugs: a correct
change landing in a file the running code does not load. This struck at
least three times — a version-bumped conf uploaded into gitignored
`local/` (never reaching tracked `default/`), the v1.2.4 quarantine fix
applied to an unused `bin/host-detect.sh` while the sourced
`lib/host-detect.sh` stayed wrong, and helper scripts arriving without
their executable bit after a GitHub web-UI/zip upload. Each was invisible
until it bit in production.

### New: `bin/self-test.sh`

A read-only preflight (it inspects and reports; never moves, deletes, or
rewrites). Checks:

1. **Sourced helpers** resolve, are readable, and parse (`lib/host-detect.sh`).
2. **No stale duplicates** — flags any second copy of a sourced helper
   (the exact `bin/` vs `lib/` host-detect trap).
3. **Menu targets** all exist and are runnable — missing is an error;
   present-but-non-executable is a warning (the launcher's bash fallback
   handles it).
4. **Version consistency** — launcher vs `default/hasher.conf` must agree;
   also warns if a `local/hasher.conf` disagrees (the drift trap).
5. **Required commands** and a SHA-256 tool are present.
6. **Bash** meets the 3.2 baseline.
7. **Config/paths** sanity.

Exit `0` pass, `1` on errors; `--quiet` and `--strict` modes.

### Wiring

- Runs silently at launcher startup; prints a banner only if it finds
  ERRORS, then points to option `x`. A clean install sees nothing.
- New menu entry **`x) Self-test (integrity preflight)`** for on-demand
  full reports.
- Invoked via `run_script`, so a missing +x bit on self-test.sh itself is
  not fatal.

### Verified

Fault-injection across all the real failure classes: recreated the stale
`bin/host-detect.sh` (flagged), stripped a menu target's +x bit (warned,
not fatal), forced conf version drift (flagged), removed a sourced helper
(flagged), removed a menu target (flagged) — each caught; clean tree
passes; startup banner appears only on error and is silent otherwise.

### Review status

This completes the response to the 2026-06-27 external review: all five
findings fixed (items 1 & 4 in v1.3.1, item 5 in v1.3.2, items 2 & 3 in
v1.3.3), the first-run colour bug fixed in v1.3.3, and the reviewer's
suggested `self-test.sh` / "make audit" preflight delivered here.

---
## 2026‑06 — v1.3.5
**Second peer review: zero-length parsing, folder re-verification, and quarantine consistency** *(assisted by Claude/Anthropic — Opus 4.8)*

A second external review found five operational edge cases, all verified
against the live code and fixed here.

### Item 3 (high) — zero-length CSV parsing repeated the comma bug

`delete-zero-length.sh` still parsed the hash CSV with a fixed-field
`awk -v FS=`, so a zero-length file whose quoted path contained a comma
(e.g. "a, b.txt") had its size column misread and was silently NOT
detected. Fixed two ways: (1) prefer the clean, already-correct
`var/zero-length/zero-length-DATE.txt` report that hasher.sh writes during
the run (one path per line, built with a quote-aware parser — no CSV
parsing needed); (2) if no report exists, parse the CSV with the same
quote-aware RFC4180 splitter used by find-duplicates.sh. Verified the
comma-named zero-length file is now detected.

### Item 2 (high) — folder dedup now has apply-time re-verification

File dedup re-hashes before quarantine; folder dedup did not, so a folder
plan made on Monday would still move a directory on Tuesday even if a
unique file had been added to it meanwhile. `apply-folder-plan.sh` now
recomputes each DEL folder's CURRENT direct-file signature from disk and
compares it to its keeper (from the groups TSV, auto-discovered or passed
via `--verify-against`); any DEL folder that no longer matches its keeper
is skipped and logged, not moved. `--no-verify` disables it. Verified:
identical folders still move; a folder with a newly-added unique file is
skipped and preserved. This closes the file/folder safety asymmetry first
noted in v1.2.1.

### Item 4 (medium) — no more empty "successful" folder plans

With a unique-only CSV, `find-duplicate-folders.sh` used to print "Plan
written" and create empty plan/group files; the launcher then offered an
empty plan for review because it tested `-n "$plan"` (non-empty string)
rather than `-s` (non-empty file). Now: zero groups → "No duplicate
folders found", no files written, exit 0; and the launcher tests `-s`
throughout for folder plans and group TSVs.

### Item 5 (medium) — quarantine resolution standardised; mv -n risk removed

File dedup quarantined to a static `$ROOT_DIR/quarantine` while folder and
zero-length used the dated, configurable `default_quarantine_root()`.
`delete-duplicates.sh` now uses the shared resolver too (honouring
`QUARANTINE_DIR`), so all three quarantine-capable tools agree. Also
replaced `mv -n` — which can return success while silently NOT moving when
the destination exists, leaving a duplicate live at its source and
miscounting it as quarantined — with explicit collision handling (numeric
`.dupN` suffix) and a post-move check that the source is actually gone.

### Item 5b / Item 1 (wording) — safety messaging aligned

First-run setup said "When you remove duplicates or junk, Hasher MOVES
them to quarantine (it never deletes outright)", which contradicted the
housekeeping helpers. Reworded to state dedup is quarantine-first while
housekeeping (zero-length/junk/cache) deletes by default. The README intro
line "whole identical folders" is corrected to "folders with identical
direct contents", matching the leaf-level behaviour.

---
## 2026‑06 — v1.3.6
**Third cross-check: regressions and gaps in the v1.3.5 fixes** *(assisted by Claude/Anthropic — Opus 4.8)*

A follow-up review found five issues, three of them regressions introduced
by v1.3.5's own fixes. All verified and corrected.

### Concern 1 (critical) — zero-length report could override an explicit --input

v1.3.5 made `delete-zero-length.sh` prefer a pre-built
`var/zero-length/zero-length-DATE.txt` report, but the fallback also
accepted the *latest* report when no date-matched one existed — so an
explicit `--input some.csv` could be silently overridden by an unrelated
cached report, deleting/quarantining the wrong files. Fixed: a pre-built
report is used ONLY when its date exactly matches the CSV's date;
otherwise the supplied CSV is parsed (quote-aware). No "latest report"
fallback.

### Concern 2 (high) — no-date CSV killed the script under pipefail

`date_guess="$(... grep -oE ... | head -1)"` had no `|| true`; a CSV
filename without a date made the pipe fail under `set -Eeuo pipefail`,
exiting silently before doing any work. Added `|| true`.

### Concern 3 (high) — file dedup ignored local/hasher.conf QUARANTINE_DIR

v1.3.5 claimed `delete-duplicates.sh` honoured the conf, but it only read
the QUARANTINE_DIR *environment variable*, not the conf setting. Added a
shared `resolve_quarantine_dir()` to `lib/host-detect.sh` (reads
local/ then default/ hasher.conf, then env, then the install-relative
default) and switched `delete-duplicates.sh` to use it. Verified: a
QUARANTINE_DIR in local/hasher.conf now takes effect for file dedup.

### Concern 4 (high) — swap-keeper plans bypassed apply-time verification

Folder verification (v1.3.5) keyed on the ORIGINAL groups TSV (del→keep).
When the reviewer swapped a keeper, the reviewed plan deletes the original
keeper, for which the original TSV had no mapping — so it moved without
verification. Fixed: the reviewer now also writes a reviewed groups
sidecar (`duplicate-folders-groups-reviewed-STAMP.tsv`) recording the
FINAL keeper for every delete after accept/swap, and `apply-folder-plan.sh`
prefers that sidecar (matched to the reviewed plan's timestamp). Verified:
a swapped keeper that changes after planning is now correctly skipped.

### Concern 5 (high) — apply-folder-plan required Bash 4+

v1.3.5 used `declare -A` (associative array), Bash 4+ only, breaking the
project's Bash 3.2 baseline (macOS /bin/bash). Replaced with a 3.2-safe
lookup: a normalised temp TSV (del<TAB>keep) queried per-delete via awk
exact match. No associative arrays remain anywhere in the codebase.

### Hygiene

- `default/hasher.conf` quarantine documentation corrected to describe the
  install-relative default (was still showing the old `/volume1/hasher`).
- All three quarantine-capable tools now resolve quarantine consistently
  and honour QUARANTINE_DIR from the conf.

---
## 2026‑06 — v1.3.7
**Runtime Bash-version detection in host detection** *(assisted by Claude/Anthropic — Opus 4.8)*

Following the v1.3.6 Bash-4 regression (a `declare -A` that would have
broken macOS), Bash-version awareness is now a first-class part of host
detection rather than an afterthought in self-test.

### Important nuance corrected

The intuition "Mac new, Synology ancient" is backwards for the version
that actually bites this project. **macOS ships Bash 3.2.57 as
`/bin/bash`** (frozen since 2007 to avoid GPLv3) — so a `#!/bin/bash`
script on a Mac runs under the OLDEST bash. Many Synology DSM builds
carry a newer 4.x bash. The 3.2 baseline this project has always held is
therefore primarily a macOS concern.

### New in `lib/host-detect.sh`

- `detect_bash_version` — sets `HASHER_BASH_MAJOR`, `HASHER_BASH_MINOR`,
  `HASHER_BASH_VERSION` (works even when sourced from a non-bash shell by
  asking the bash binary on PATH).
- `bash_at_least MAJOR MINOR` — guard for optional fast paths.
- `require_bash MAJOR MINOR [feature]` — for a path that genuinely needs a
  newer bash: prints a clear, platform-aware error (including the Homebrew
  hint on macOS) and returns non-zero so callers refuse gracefully instead
  of dying on a cryptic syntax error.

### Wiring

- **Launcher header** now shows `Bash: <version>` beside `Host:`, and a
  startup warning fires if running below the 3.2 baseline.
- **check-deps.sh** diagnostics show the Bash version and whether it meets
  the baseline.
- **self-test.sh** now uses the shared `bash_at_least` (single source of
  truth) instead of its own inline check, and notes when Bash 3.x is in
  use (common on macOS).

No behavioural change to hashing or dedup; this is environment awareness
and future-proofing so any later Bash-4-only optimisation must be guarded
with `require_bash`/`bash_at_least` rather than silently breaking 3.2.

### Fourth cross-check review (5 concerns)

A further review found five issues; all fixed and verified.

**Concern 1 (urgent) — folder dedup could move unique nested data.**
The signature compares a directory's DIRECT files, but apply moves the
directory recursively. So `B` with a matching `B/common.txt` but a unique
`B/sub/unique.txt` was planned for deletion, and applying it moved the
unique nested file. Fixed by making "leaf-folders" literal: any directory
that is a parent of another directory in the catalogue is excluded from
candidacy. A true leaf has no sub-folders, so its direct-file signature IS
its complete content — compare-shallow and move-deep become equivalent.
Verified: `B` is excluded; genuine leaf folders still match.

**Concern 2 — zero-length report matching was date-only.** Daily reports
(`zero-length-DATE.txt`) couldn't be reliably tied to per-run CSVs
(`hasher-DATE-HHMM.csv`); a same-day explicit `--input` could still be
overridden by an unrelated report. Fixed: an explicit `--input` ALWAYS
parses that CSV; a report is used ONLY via an explicit new `--report FILE`
flag. Removed report auto-selection from the CSV path entirely.

**Concern 3 — folder apply could verify against the wrong sidecar and
move unverified.** Auto-discovery preferred the newest reviewed sidecar
even for an explicit raw plan, found no keeper mapping, and proceeded.
Fixed two ways: (a) resolve the sidecar STRICTLY from the plan being
applied (reviewed plan → exact reviewed sidecar by stamp; raw plan → the
same-date original groups TSV; never "newest"); (b) FAIL-SAFE — when
verification is active but a planned delete has no keeper mapping, SKIP it
by default. Override with `--allow-unverified`; disable checks entirely
with `--no-verify`. Verified all three modes.

**Concern 4 — hasher.sh recommended invalid zero-length commands.** It
suggested a positional report path and `--quarantine DIR`, but the script
takes `--input CSV` and `--quarantine` is boolean. Added `--report FILE`
and `--dry-run` to delete-zero-length.sh and corrected the recommendations
to `--report "$out" --dry-run` / `--report "$out" --force [--quarantine]`.
Verified the recommended commands now run.

**Concern 5 — release hygiene.** Versions realigned (launcher, conf, and
README all v1.3.7). Executable bits are stripped by the upload but the
launcher's `run_script` fallback covers menu use; self-test flags any that
don't survive.

---
## 2026‑06 — v1.3.8
**Fifth recheck: apply-time leaf safety, plan-resolution order, O(n²) fix, resolver unification** *(assisted by Claude/Anthropic — Opus 4.8)*

A recheck found five issues; the first is a genuine safety gap, the rest
correctness/performance/consistency. All fixed and verified.

### Concern 1 (urgent) — apply-time leaf check

v1.3.7 excludes non-leaf folders at PLAN time, but a folder that was a leaf
when the plan was written can gain a subdirectory before the plan is
applied. Apply moves directories recursively, so a now-non-leaf folder
would relocate nested data that was never compared — and the content
re-verification didn't catch it (the direct-file signature still matched).
Added an apply-time leaf check in `apply-folder-plan.sh`: immediately before
moving, re-check from disk that both the delete folder and its keeper are
still leaves (no child directories); skip if not. Holds even under
`--no-verify`; `--allow-unverified` is the single escape hatch. Verified: a
folder that gains a subdirectory after planning is skipped and its nested
data preserved; genuine leaves still move.

### Concern 2 — default plan resolution order

Verification-sidecar discovery ran before the default (no `--plan`)
PLAN_FILE was resolved, so direct `apply-folder-plan.sh --force` found no
matching groups TSV and (under the fail-safe) skipped everything. Reordered:
parse args → default+validate PLAN_FILE → discover sidecar → apply. Verified
default usage now applies the latest plan with verification.

### Concern 3 — O(n²) leaf detection replaced

The plan-time non-leaf detection compared every directory against every
other (~18s for 11k dirs here). Replaced with a sort/`comm`-based approach
that emits each directory's ancestors and intersects with the catalogue —
~0.04s for the same 11k dirs (~400× faster), with identical output, and
preserving transitive semantics (an ancestor several levels up is still
flagged).

### Concern 4 — quarantine resolver unified

`apply-folder-plan.sh` and `delete-zero-length.sh` kept private
`resolve_quarantine_dir()` copies that ignored an exported `QUARANTINE_DIR`
environment variable. Both now source `lib/host-detect.sh` and call the
shared resolver (conf → env → install-relative default). Verified an
exported `QUARANTINE_DIR` is now honoured by both.

### Concern 5 — executable bits

Still stripped by the GitHub web-UI/zip upload; the launcher's run_script
fallback covers menu use and self-test flags them. Set in the released
files; re-applying on the NAS (`chmod +x bin/*.sh`) clears the warnings and
enables direct CLI use.

---
## 2026‑06 — v1.3.9
**Folders-first workflow guidance** *(assisted by Claude/Anthropic — Opus 4.8)*

A UX change to protect the correct dedup order. File dedup and folder dedup
are not commutative: removing duplicate files collapses folder contents,
changing those folders' direct-file signatures, so two folders that are
currently identical may no longer match afterwards — and the high-leverage,
one-decision folder cleanup is lost. Users effectively get one shot at the
folder opportunity, and going files-first quietly forecloses it.

Changes (medium-strength steering — guide, never block):

- **Stage 2 reordered** so "Find duplicate folders" is listed first and
  marked "← recommended first", with a short note explaining the ordering.
  Key bindings are unchanged (3 = folders, 2 = files) so muscle memory and
  the many "option 2/3" references across code and docs stay valid.
- **Folders-first guard**: choosing file dedup (option 2) or auto-dedup
  (option 5) before any folder plan/groups file exists prints a clear
  warning about the irreversible signature change and asks for confirmation.
  It's a single keypress, never blocks, and does not fire once a folder plan
  exists (from this or a previous session). Implemented as a shared
  `folders_first_guard` helper.
- **README** auto-dedup workflow corrected to fold in folders-first, with a
  "Why folders first?" callout.

No change to hashing, dedup logic, or safety behaviour — this is workflow
guidance only.

---
## 2026‑07 — v1.3.10
**delete-junk.sh: fix printf abort on dash-leading output, and restore colour** *(assisted by Claude/Anthropic — Opus 4.8)*

Two bugs surfaced running option 8 (delete junk) on a real NAS catalogue.

### The abort (important)

`delete-junk.sh` printed its table separators with
`printf "--------  ---..."`. Because the format string starts with `--`,
`printf` treats it as an end-of-options marker and rejects `--------` as an
invalid option: `printf: --: invalid option`. Under the script's `set -eu`,
that non-zero return ABORTED the whole run — after the preview header but
before the confirmation prompt or any deletion — so junk cleanup silently
failed on any invocation that reached those lines (both the short and long
list branches). Fixed by passing the dashes as DATA under a `%s` format:
`printf '%s\n' "--------  ---..."`, which printf never parses as options.
Audited the rest of the codebase — no other dash-leading printf formats.

### Colour restored

The script used plain `echo "[INFO] ..."` with no colour, so its messages
were uncoloured unlike the rest of the tool. Added TTY-guarded colour
variables built with `printf '\033[...'` (real ESC bytes) and routed all
messages through `info`/`ok`/`warn`/`err` helpers, matching the pattern used
across the codebase.

Verified end-to-end: a junk file whose name starts with `-` no longer
triggers the error, both the short and long (>10 files) list branches
complete, and messages render in colour on a TTY.

---
## 2026‑07 — v1.3.11
**lib/log.sh — shared colour + logging module** *(assisted by Claude/Anthropic — Opus 4.8)*

Addresses the root cause behind two separate colour bugs (check-deps.sh in
v1.3.3, delete-junk.sh in v1.3.10): every script reinvented colour handling,
with six different naming conventions and five different definition styles,
so each new script was a fresh chance to get it wrong.

### New: `lib/log.sh`

A single POSIX-sh source of truth for terminal colour and the
`info`/`ok`/`warn`/`err`/`work` functions. Colours are built with
`printf '\033[...'` (real ESC bytes, not literal strings), TTY-guarded
(`[ -t 1 ]`), and emitted via printf with the colour as a plain `%s`
argument — so there is no dash-leading-format or `%b`-escaping hazard.
Every legacy colour variable name previously used across the codebase
(`CINFO`, `C_INFO`, `GRN`, `GREEN`, `c_green`, …) is defined as a
back-compat alias, so scripts referencing raw colour vars keep working.

Canonical scheme: INFO=cyan, OK=green, WARN=yellow, ERR=red, WORK=cyan.
A few migrated scripts' colours shift slightly to this standard — an
intentional consistency change.

### Migrated in this pass (conservative)

The two bug-prone scripts plus the recently-heavily-edited ones now source
`lib/log.sh` instead of defining their own: `check-deps.sh`,
`delete-junk.sh`, `self-test.sh`, `apply-folder-plan.sh`,
`find-duplicate-folders.sh`. Scripts with special logging (self-test's
counter-maintaining pass/warn/fail, check-deps' column-aligned output) keep
their own functions but take colours from the shared module. The remaining
stable scripts will be migrated gradually — no need to churn 19 files at
once. Each migration keeps a minimal inline fallback if `lib/log.sh` is
somehow absent.

### Self-test

`lib/log.sh` is now in self-test's sourced-helpers check, so a missing or
broken shared module is caught at launch (verified: a syntax error in
lib/log.sh makes self-test FAIL). Check count is now 38.

---
## 2026‑07 — v1.3.12
**Fix launcher crash on unbound ${YELLOW}; self-test now guards this class** *(assisted by Claude/Anthropic — Opus 4.8)*

### The crash

The launcher runs under `set -eu`. The Stage 2 menu (added in v1.3.9)
referenced `${YELLOW}`, but the launcher defines its warning colour as
`${YEL}` — so `${YELLOW}` was an unbound variable. Under `set -u` this
aborts the moment the menu renders: the tool printed Stage 1 and then died
with `line 167: YELLOW: unbound variable`. `bash -n` does not catch this
(it is not a syntax error), which is why it passed the syntax sweep and
reached the NAS. Fixed by using the defined `${YEL}`.

### The real fix — self-test now catches unbound colour vars

A launch-blocking crash that the preflight missed is a preflight gap.
Added self-test check 8: it greps the launcher for colour-style `${VAR}`
references and fails if any lacks a matching assignment. Verified it PASSES
on the fix and FAILS if `${YELLOW}` is reintroduced. Had this existed, the
bug would have been caught before shipping. (Check count now 39.)

### Note on the delete-junk printf error in the same report

The `delete-junk.sh: line 99: printf: --: invalid option` in the report was
the pre-v1.3.10 behaviour ("before the latest MR", as noted); the deployed
zip already carries the v1.3.10 fix (dashes passed as `%s` data), verified
against the long-list branch. No further change needed there.

### Follow-up (not done here)

The launcher still maintains its own colour block rather than sourcing
lib/log.sh. Migrating it would define every colour alias (YELLOW included)
and make this class structurally impossible, but the launcher's colour setup
sits inside the `set -eu` startup path and is best migrated deliberately
rather than reactively. Deferred to the gradual lib/log.sh rollout.

---
## 2026‑07 — v1.3.13
**Maturity release: stale-code removal, honest config, timestamped artefacts** *(assisted by Claude/Anthropic — Opus 4.8)*

Implements the internal audit's top-3 (A1–A3) plus all ten items from the
sixth peer review — a codebase-maturity pass rather than new features.

### Removals (delete these explicitly in the GitHub web UI)
- **bin/du-summary.sh** — stale artefact model (expected groups.summary.txt
  etc., which no longer exist) and a line-106 quoting bug that crashed with
  `RUN: No such file or directory`. Removed rather than rewritten.
- **bin/review-junk.sh** — legacy junk cleaner superseded by delete-junk.sh
  (its own header even said delete-junk.sh). One implementation per job.
- **lib/hasher.conf** — stray stale v1.3.11 copy from a wrong-directory
  upload. Config lives ONLY in default/ and local/. **Self-test now FAILS on
  any hasher.conf outside those two homes** (new check).
- **local/excluded-from-dedup.txt** references — documented as a dedup
  exclusion control but no code read it; an unimplemented safety promise is
  worse than none. Removed from README.

### Config honesty (recheck item 5)
Removed keys no code consumes from default/hasher.conf: the whole [review]
section, LOW_VALUE_THRESHOLD_BYTES (its comment claimed review-duplicates.sh
reads it — verified false), ZERO_APPLY_EXCLUDES, EXCLUDES_FILE, CRON_SPEC.

### Timestamped folder artefacts (recheck item 4)
find-duplicate-folders.sh now writes
`duplicate-folders-plan-YYYY-MM-DD-HHMMSS.txt` and matching groups TSV —
same-day runs no longer overwrite each other. apply-folder-plan.sh matches
the raw sidecar by exact stamp, with a date-only fallback for pre-v1.3.13
artefacts. Verified: two same-day runs coexist; apply picks the exactly
matching sidecar (not the newest); old date-only plans still verify+apply;
reviewed plans still pick their reviewed sidecar over a same-stamp raw decoy.

### Correctness fixes
- **hash-check.sh** (item 3): comma paths were misreported by a naive
  `awk -F,` split. Now uses the same RFC4180 quote-aware parser as
  find-duplicates.sh. Verified `a,b.txt` reports fully and unquoted.
- **launcher sh→bash fallbacks** (item 7): both non-executable fallbacks
  (`nohup sh` background, `sh` interactive) now invoke `bash` — the targets
  are Bash scripts and sh (dash/ash) would break on bashisms.
- **delete-junk.sh macOS sizes** (audit F1/A3): `stat -c` now falls back to
  BSD `stat -f %z`, so macOS no longer shows every junk file as 0B.
- **clean-logs.sh** (item 8): retention patterns updated to current artefact
  names (reviewed folder plans/groups, apply-folder-plan/delete-zero-length
  logs, groups TSVs — which now accumulate under timestamping), rotate
  folder-actions.log, and **reject arguments honestly** — `--dry-run` was
  silently ignored while logs were actually pruned; it now exits 2 with an
  explanation.
- **apply summary wording** (item 9): the skip counter covers content
  mismatch, missing keeper mapping, and non-leaf skips, so the summary now
  says "changed, lost verification context, or were no longer safe to move".
- **README** (A2): Stage 2 menu listing updated to the folders-first order
  shipped in v1.3.9; file tree updated for removals.
- **Dead code** (item 10): removed unused append_csv_row() from hasher.sh
  and unused path_len() from auto-dedup.sh (review-duplicates.sh keeps its
  own, which is used).

Self-test: 40 checks, PASS. Full syntax sweep across 20 files.

---
## 2026‑07 — v1.3.14
**Interactive review: N/potential misreport fixed; review colours standardised** *(assisted by Claude/Anthropic — Opus 4.8)*

Reported from a live NAS dedup run: group headers showed `N=2` for groups
that visibly listed 3–4 files, with `potential` equal to a single file's
size — i.e. `(N-1)=1` — so per-group savings were understated and the
size-ordering of the whole review was skewed. Both screenshots shared that
`potential == size` signature: the display's index lookup was failing on
the NAS and silently falling back to the hard default `Nval=2`.

### Root cause and fix

`review-duplicates.sh` derived N by re-parsing the report header through
`grab_N` (a gawk-only three-argument `match()` with a sed fallback) and
writing an index row with `printf %llu` (a C length modifier not every
bash builtin printf accepts) — two environment-sensitive constructs that
behave differently under the NAS's bash 4.4/BusyBox toolchain than under a
desktop shell, then a display lookup that defaulted to 2 on any failure.

v1.3.14 removes the fragility rather than patching it:
- **Pass 1 now COUNTS N from the member path lines** of each group — the
  same lines the review displays. grab_N is deleted entirely; the header's
  `(N=…)` is no longer trusted for anything.
- **The header display derives N and potential from the very listing shown
  beneath it** (`$ORDERED`), so the header can never disagree with the
  files on screen, regardless of environment.
- `%llu` → `%s` in the index row (values are already plain decimal).

Verified: a 4-member group with spaces in paths shows `N=4,
potential=3×size`; headers deliberately corrupted to carry NO parseable N
still display correct counts (the failure mode is structurally impossible
now); groups are still presented in savings-descending order; the plan
file format (`KEEP|…` / `DEL|…|hash`) is unchanged.

### Colours (second report: [INFO] not coloured)

Continued the gradual lib/log.sh migration to the review pair:
- **launch-review.sh** had NO TTY guard — colours were emitted
  unconditionally (escape codes leaked into piped output) and [INFO] was
  green. Now sources lib/log.sh: cyan [INFO], guarded, clean when piped.
- **review-duplicates.sh** guarded on stderr (`-t 2`) rather than stdout
  and coloured [INFO] green. Now takes its palette from lib/log.sh
  (INFO=cyan, canonical), keeping its stderr-routed wrappers and dim style.

Remaining unmigrated colour scripts (hasher.sh, find-duplicates.sh,
delete-duplicates.sh, delete-zero-length.sh, clean-logs.sh, hash-check.sh,
run-find-duplicates.sh, launcher.sh) continue on the gradual rollout; if a
plain [INFO] appears again, note which stage printed it.

---
## 2026‑07 — v1.3.15
**New menu action: k) Stop hashing — plus concurrent-run prevention** *(assisted by Claude/Anthropic — Opus 4.8)*

Field report: three concurrent `hasher.sh` runs (started within a minute of
each other) had to be found with `ps aux | grep hasher` and killed one PID
at a time with `kill -9` as root. Two gaps: no way to stop hashing from the
menu, and the pidfile duplicate-run guard only knows about the MOST RECENT
launch — orphans from crashed or duplicate sessions are invisible to it.

### k) Stop hashing (Stage 1)

New launcher action that finds every live hasher.sh process — parents,
`--jobs` worker subshells, and pidfile-untracked orphans alike — via a
ps scan, shows the full process lines, asks for confirmation, sends TERM,
waits up to 8s for clean shutdown, and only escalates to KILL for
stragglers. Clears the pidfile and notes the stop in background.log.

**Precision matters**: the scan matches only processes EXECUTING hasher.sh
(an interpreter token immediately followed by the script path — exactly how
the launcher, the shebang, and DSM's ps render it), never processes that
merely mention the file. Verified: a `tail -f bin/hasher.sh` is not
matched; three orphaned runs are all found and stopped. (The test harness
managed to kill its own session twice by matching its own command line
before this precision rule was in place — which is exactly the accident
this rule prevents in the field.)

### hasher.sh: graceful TERM/INT

An untrapped signal makes bash exit WITHOUT running the EXIT trap, so a
TERM would previously have left the pidfile and working files behind.
hasher.sh now traps TERM/INT: runs its cleanup (progress tickers, working
files, pidfile), logs the stop, exits 143/130. Verified against a real
3000-file run: pidfile present during the run, gone after TERM.

### Start guard hardened

`ensure_no_running_hasher` now also ps-scans for orphans after the pidfile
check. Starting a new run while untracked hasher processes exist warns,
lists them, recommends 'k', and requires explicit confirmation — so the
three-concurrent-runs situation can no longer arise silently.

Also carries forward v1.3.14 (review N-count fix + review colour
migration) for deployments that skipped it.

---
## 2026‑07 — v1.3.16
**Peer-review findings 1–5: safety, correctness, run isolation, parallel-worker termination, plan verification** *(assisted by Claude/Anthropic — Opus 4.8)*

Five findings from an external review; **all five confirmed in v1.3.15 with
reproductions**, all five fixed here. Finding #1 is the most serious defect
this project has shipped: exclusions have been silent no-ops on every
parallel-safe run since NUL-delimited processing landed.

### #1 (critical) — exclusion filter was silently no-op

`build_file_list` piped candidates through an awk block that filtered on
NUL records but emitted retained paths with `printf "%s", $0` — omitting
the NUL terminator that `ORS='\0'` was supposed to add. Every filtered
output had zero NUL records; a fallback then **restored the unfiltered
list** on the reasoning that "exclusions removed everything must be a
mistake". Result: `@eaDir`, `#recycle`, `.part`, `.bak`, `/Cache`,
`/.Trash`, `@tmp`, `@SynoResource` and every user-supplied exclusion have
been included in every CSV. Fix: `print $0` under `ORS='\0'` (awk emits the
terminator); the "restore unfiltered" fallback is REMOVED — if exclusions
legitimately empty the candidate list, the honest message is "nothing to
hash this run", not a silent re-include.

### #2 (high) — advertised algorithms didn't work end-to-end

hasher.sh accepted `--algo sha1|sha512|md5|blake2`, but downstream
(`delete-duplicates.sh`, `find-duplicates.sh`, plan format) only recognises
64-hex SHA-256. An MD5 plan's 32-char hash was absorbed into the pathname
during apply; the tool then reported "no planned files existed". Rather
than plumb the algorithm through every downstream tool (a much larger
change), be honest: **hasher.sh now rejects non-sha256 algorithms up front
with rc=2** and the usage/help lines no longer advertise them.

### #3 (high) — run isolation

Two problems: `CSV_TAG` was minute-precision so same-minute runs shared a
name, and `write_csv_header` **silently appended** to an existing manifest
if it wasn't empty. Fix: `CSV_TAG` is now `%F-%H%M%S-$$` (distinct per run
including PID), and `write_csv_header` **refuses to open a non-empty output
unless `--append` is passed** (explicit opt-in). Separately, hasher.sh now
takes its own **atomic lock** in `main()` via `mkdir "$VAR_DIR/hasher.lock"`
so direct-CLI and cron starts get the same concurrency protection that the
launcher's pidfile guard provided; stale locks from crashed runs are
adopted after checking the recorded PID isn't alive.

### #4 (high) — Stop hashing left parallel workers alive

`list_hasher_pids` matches only interpreter processes executing
`bin/hasher.sh`. The `--jobs N` path fans work out through `xargs -0 -P N`,
`bash -c` workers and hash commands — none of which have `bin/hasher.sh`
in their cmdline. TERM to the parent left every descendant orphaned; the
8-second wait then reported "Hashing stopped" while xargs and the workers
were still running. Fix: **hasher.sh becomes its own session leader** via
a `setsid` re-exec at startup (stdin redirected from `/dev/null` to avoid
deadlocking on inherited pipes). The launcher resolves each parent's PGID
and signals the whole group: `kill -TERM -PGID` catches xargs, workers,
hash commands, sleeps — everything spawned since the setsid. hasher.sh's
TERM/INT traps do the same internally. Verified end-to-end: 20 descendants
in the pgroup, one signal reaps all of them.

### #5 (high) — unhashed plans were applied fail-open

`delete-duplicates.sh` accepted old-format `DEL|path` entries (no hash)
with only a warning, then moved any file that still existed. A one-line
legacy plan pointing to a unique file moved it to quarantine — bypassing
the stale-plan safety guarantee that per-entry re-verification provides.
Fix: **unhashed plans refused by default** (rc=2 with a clear message and
two options — regenerate, or override). The override is
`--allow-unverified-plan` PLUS an interactive confirmation requiring the
user to type `apply-unverified` verbatim. Also cleaned up delete-duplicates
arg parsing along the way (proper `--plan/-p` flag; the old positional `$1`
still works for backward compatibility).

---
## 2026‑07 — v1.3.17
**Peer-review recheck 1–5: piped input restored, plan classification, delimiter policy, run isolation, cron parity** *(assisted by Claude/Anthropic — Opus 4.8)*

Five follow-up findings after v1.3.16. All confirmed live; four were
regressions or edge cases I introduced or missed, one was pre-existing.

### #1 — Session isolation cleaned up (was breaking the documented pipe interface)

Three sub-issues in the v1.3.16 setsid work:

- **1a (regression I introduced):** `exec setsid "$0" "$@" </dev/null`
  unconditionally redirected stdin, breaking the documented piped-paths
  interface (`echo /path | hasher.sh`, `find … | hasher.sh`). Now only
  redirects when stdin is a TTY; a piped stdin is preserved. The v1.3.16
  hang I saw came from a test harness with a closed pipe, not real usage.
- **1b:** the `--nohup` re-invocation inherited `HASHER_SESSION_LEADER=1`,
  so the child skipped its own re-exec and stayed in the parent shell's
  process group — group-signalling that PID would then hit the caller.
  Now unset the guard before the child spawn.
- **1c:** if setsid is unavailable, we no longer risk signalling the
  caller's process group. Both hasher.sh's TERM trap and the launcher
  check `PGID == PID` before using `kill -PGID`; when it isn't, they walk
  the descendant tree with `pgrep -P` and TERM each child individually.
  Also switched leadership detection from `getsid` (returns 0 in some
  container/namespace configs) to PGID equality (portable).

### #2 — Plan classification made whole-plan-honest

Two fail-open paths in delete-duplicates.sh:

- Classification sampled only the FIRST DEL line. A mixed plan (some
  entries with hashes, some without) was tagged "hashed" and the unhashed
  entries then moved with no verification. Now scans EVERY DEL line;
  mixed plans are refused outright with a clear message.
- If the plan was hashed but no hash tool was available, the code
  silently downgraded `PLAN_HAS_HASHES=0` and continued through the
  verified path — moving files without re-verifying anything. Now
  refuses (rc=2): the whole point of the hashes is re-verification.
- Belt-and-braces: at apply-time, an empty `DEL_HASH` on a plan
  classified as hashed safety-skips the entry rather than falling
  through to existence-only checks.

### #3 — Tab/newline filename policy: detect and skip

find-duplicates.sh's awk block silently rewrote tabs in paths to spaces
(`gsub(/\t/," ",p)`), producing a report/plan whose paths didn't match
files on disk — dedup could act on the wrong file. Hasher.sh now filters
these at discovery: paths containing TAB, LF, or CR are skipped with a
WARN and logged to `var/skipped-delimiter-paths.log` (with `<TAB>`/`<LF>`/
`<CR>` markers so users can identify the exact files to rename). A NUL-
delimited internal manifest across all tools is the fuller fix and stays
on the roadmap; this policy closes the correctness gap in the meantime.

### #4 — "Clean internal working files" refuses while hashing is active

`action_clean_internal` (menu option 'v') did `find | rm -rf` on
everything under `var/` with no active-run check. Removing `hasher.pid`,
`hasher.lock`, `files-*.lst`, or `zero-length/*` during a live run
unblocked concurrent runs (defeating the v1.3.16 lock) and corrupted
in-flight reporting. Now uses the same two-signal detection as the start
guard: refuses if `is_hasher_running` returns true OR if any hasher.sh
process is visible in ps. Recommends 'k' (Stop hashing) first.

### #5 — Cron path fixed; direct-CLI now inherits local/excludes.txt

- **5a:** The "Stats & scheduling hints" screen showed
  `./hasher.sh --pathfile …` (path doesn't exist). Corrected to
  `bin/hasher.sh --pathfile …`, and added a note that hasher.sh loads
  conf on startup so cron and menu runs use the same exclusion set.
- **5b:** The launcher used to translate `local/excludes.txt` into a
  series of `--exclude` flags, but hasher.sh itself never read the file
  — direct-CLI and cron invocations produced a *different* manifest than
  the menu. Now hasher.sh auto-loads `local/excludes.txt` on startup (one
  pattern per line, blank/comment lines ignored), so all invocations see
  the same exclusion set.

Self-test: 40 passed, 0 warnings, 0 errors. All 20 files pass syntax.

---
## 2026‑07 — v1.3.18
**Peer-review recheck 1–5: housekeeping newline safety, real glob excludes, prompt TERM, right-sized diagnostics, honest stdin handling** *(assisted by Claude/Anthropic — Opus 4.8)*

Five follow-ups after v1.3.17. All confirmed live; all five fixed here.

### #1 (critical) — Housekeeping tools no longer delete unrelated files on newline paths

`delete-junk.sh` and `delete-zero-length.sh --scan` both discovered
candidates NUL-safely but then flattened them into newline-delimited text
lists (`tr '\0' '\n'` and `find -print` respectively). A path containing
an embedded newline split into two "candidates"; the delete loop then
matched — and removed — an unrelated file whose relative name happened
to coincide with a fragment. Both tools now apply the same TAB/LF/CR
detect-and-skip policy the hasher already uses: newline-bearing
candidates are filtered out and recorded to a `*-skipped-delimiter.log`
sibling file for operator follow-up. The two safe tools then convert the
already-filtered NUL stream to the text list they need.

Live verification: created a file whose name literally contained `\n`
alongside a coincidentally-matching real file — the newline file was
listed in the skip log, the real file was correctly deleted, the
unrelated file that a split would have matched was untouched.

### #2 (high) — Cron/CLI/menu exclusions now share ONE implementation

The launcher was silently mangling exclude patterns (`sed 's/\*//g;
s://*:/:g; s:/*$::'`) before passing them to hasher.sh, and hasher.sh
was applying case-sensitive literal-substring matching. Result:
`*.part` in `local/excludes.txt` excluded `.part` under the menu (which
stripped the `*`) but NOT under direct/cron (which saw the useless
literal `*.part`). The claimed cron/menu parity in v1.3.17 was not real.

Fix: hasher.sh now implements the DOCUMENTED semantics — case-insensitive
globs — inside a single awk block that owns exclusion matching. Rules:

- `*` matches any run of characters (including empty)
- `?` matches exactly one character
- `.` is a literal dot
- matching is case-insensitive
- a pattern containing `/` matches against the FULL path; otherwise
  the basename only (the natural extension/name convention)
- a pattern with NO glob metacharacters keeps the pre-v1.3.18 literal
  substring semantics against the full path — so `#recycle`, `@eaDir`,
  `.DS_Store` continue to work exactly as before

The launcher stops translating patterns — it now only trims whitespace
and forwards each line as-is. Live: `*.part` correctly excludes
`file.part` from both direct-CLI and menu runs; `*.PART` case-insensitively
does the same; `a?.log` excludes `a1.log` and `ab.log` but not `abc.log`;
`#recycle` still catches `/tmp/foo/#recycle/x.txt`.

### #3 (high) — `kill $(cat var/hasher.pid)` now stops promptly

Bash defers signal traps while a FOREGROUND pipeline is running. The
parallel path was `xargs -P N | while read row; ...` — a foreground
pipeline — so sending TERM to the PID left the trap queued until the
pipeline exited naturally. The launcher's group-kill worked (v1.3.17),
but the advertised "just kill the PID" did not.

Fix: run the parallel pipeline as a background job and `wait` on its
PID. `wait` on a specific PID IS interruptible by signals, so the
TERM/INT trap fires immediately and `_stop_group` reaps the backgrounded
pipeline along with everything else in the group. Live verification: 22
descendants running; `kill -TERM $(cat var/hasher.pid)`; parent gone in
1 second (was 5+); 0 survivors; lock and pidfile both cleared.

### #4 (medium-high) — Dependency diagnostics match the supported product

`check-deps.sh` was still marking sha1sum/sha512sum/md5sum as REQUIRED
and setting an error if they were missing — but hasher.sh has rejected
those algorithms since v1.3.16. Meanwhile, tools we DO now depend on
weren't tested at all.

- Required: SHA-256 implementation (sha256sum, or shasum, or OpenSSL
  shim); xargs, comm, awk, grep, sed, tr, sort; `ps -o pgid=` support.
- Nice-to-have: pgrep (needed for descendant-tree walk in the no-setsid
  fallback), setsid (needed for clean session isolation and one-signal
  group kills). Missing pgrep/setsid warn with degraded-mode explanation.
- Absent sha1sum/sha512sum/md5sum/b2sum: silent (not used).

### #5 (medium-high) — Empty stdin errors; piped directories are walked

Two bugs on the piped-input path:

- `had_input=true` was set the moment stdin wasn't a TTY, before any
  read. `hasher.sh </dev/null` returned rc=0 with a header-only manifest
  and "Hashed 0/0 files". Empty input now exits rc=2 with a clear message.
- Piped paths were forwarded verbatim to the file list. A directory
  piped in was then handed to sha256sum, which failed on it — the run
  still "succeeded" with a failure count. Piped paths are now expanded
  the same way `--pathfile` entries are: directories → `find -type f
  -print0`, regular files → added directly, non-existent → warn.
  If EVERY piped path is missing/unreadable, exit rc=3.

Live: empty stdin → rc=2; piped directory → 2 files hashed (both walked
from the directory); piped file paths still work; piped NUL-delimited
find output still works; nonexistent piped path → rc=3.

Self-test: 40 passed, 0 warnings, 0 errors. All 20 files pass syntax.

---
## 2026‑07 — v1.3.19
**Peer-review recheck 1–5: BusyBox compatibility, TERM handler self-signalling, honest deletion accounting, manifest algorithm gate, per-run derived reports** *(assisted by Claude/Anthropic — Opus 4.8)*

Five findings after v1.3.18. All confirmed live; all five fixed. The
critical one is #1 — since v1.3.16, exclusion filtering and delimiter
skip on Synology DSM (BusyBox awk) has been broken in a mode that
produced silently-empty CSVs.

### #1 (critical) — BusyBox awk compatibility via auto-detect

`awk -v RS='\0' -v ORS='\0'` was used in four sites. gawk and mawk handle
NUL RS/ORS correctly; **BusyBox awk (Synology DSM, Alpine) processes
only the first NUL record and drops the ORS**. Reviewer reproduced a
four-file hash run producing a header-only CSV and a "all four files
matched exclusions" message. Empirically verified locally: BusyBox
1.36.1 on our 3-record input emits 2 bytes vs gawk/mawk's 9.

Fix: new `lib/awk-detect.sh` module. At startup, hasher probes the
local awk's NUL behaviour with a canonical 3-record test — expects 6
bytes back. If it gets that, uses the awk fast path; otherwise
transparently switches to a pure-bash `while IFS= read -r -d ''` path
that reproduces the same semantics byte-for-byte. Two helpers exposed:

- `hasher_nul_filter_delim(in, skiplog)` — splits a NUL stream into
  clean records (stdout, NUL-delimited) and TAB/LF/CR-bearing records
  (skiplog, newline-delimited with `<TAB>`/`<LF>`/`<CR>` substitutions).
- `hasher_nul_filter_globs(in, patterns...)` — case-insensitive glob
  exclusion filter (same documented semantics as v1.3.18).

All four sites (hasher.sh × 2, delete-junk.sh, delete-zero-length.sh)
now call the helpers rather than inlining awk. On a normal Linux/macOS
host the awk path runs (fast). On DSM with BusyBox awk, the bash path
runs (correct). Verified: forced-bash and natural-awk paths produce
byte-identical output on the same fixtures.

**Also 1b**: `find-duplicate-folders.sh` ancestor regex used `\/[^/]+$`
which BusyBox awk rejects as "bad regex". Replaced with `[/][^/]+$`
(character class) — accepted by gawk, mawk, nawk, AND BusyBox.

### #2 (critical) — Internal TERM handler no longer self-signals

`_stop_group()` ran `kill -TERM -$$` from inside its own process group.
Bash executes handler statements one at a time; the kill line signalled
every group member INCLUDING $$, so the shell terminated at that line
and never reached the wait/KILL escalation or descendant verification.
With cooperative workers (ordinary sha256sum) descendants exited within
milliseconds and the bug was masked. With uncooperative workers, the
parent died and released its lock/pidfile while workers kept running;
a fresh run could then start alongside them.

Fix: enumerate group members EXCLUDING `$$` and signal only those. If
descendants survive the KILL escalation, print an explicit warning so
the operator knows the lock/pidfile release that follows may be
premature (rather than silently claiming success). The launcher's
external `kill -TERM -PGID` is unaffected — it runs in a different
group and won't self-kill.

### #3 (high) — delete-junk deletion accounting is honest

`rm -f -- "$p" 2>/dev/null || true` swallowed every error; `del=$((del+1))`
fired regardless. Read-only files, mounted-read-only volumes, and
permission-denied cases all reported "Deleted: N files" while the
files remained on disk. Fix: check rm's rc AND `[ ! -e "$p" ]`
post-condition; increment success only when both pass; increment
failure counter otherwise; log every failure to a sibling
`*-delete-failures.log`; exit rc=1 if any deletion failed. Verified
via a PATH-shim that makes `rm` fail on `.part` files: rc=1, "Deleted: 0",
"Failed to delete 1", failure log written, file untouched.

### #4 (medium-high) — find-duplicates rejects non-SHA-256 manifests

`find-duplicates.sh` accepted hash columns named md5/sha1/sha512/blake2
and passed them through. `auto-dedup.sh` then generated plans that
`delete-duplicates.sh` couldn't apply — the wrong-length hashes were
absorbed into the pathname. Fix: two-stage validation at start of
find-duplicates.sh — column name must be `hash`/`digest`/`checksum`/
`sha256`; and the first data row's hash value must be exactly 64
hexadecimal characters. Otherwise exit rc=2 with a clear message
pointing at hasher.sh regeneration.

### #5 (medium) — Derived reports are per-run

`post_run_reports` wrote `zero-length-YYYY-MM-DD.txt` and
`YYYY-MM-DD-duplicate-hashes.txt` — date-only, so a second run on the
same day overwrote the first. Since source CSVs became run-unique in
v1.3.16 (`%F-%H%M%S-$$`), the "next-step commands" printed by an earlier
run could later point at a report from an entirely different scan.

Fix: reports now include the full run tag —
`zero-length-YYYY-MM-DD-HHMMSS-PID.txt` and
`duplicate-hashes-YYYY-MM-DD-HHMMSS-PID.txt`. Two convenience symlinks
(`*-latest.txt`) always point at the most recent report of each kind
so next-step commands remain stable across time. Falls back to a
rewritten copy on filesystems that reject symlinks (rare NAS SMB
shares). Verified: two same-second runs produce two distinct reports;
latest symlink points at the newer one.

Self-test: 40 passed, 0 warnings, 0 errors. All 21 files pass syntax
(the +1 is the new `lib/awk-detect.sh`).

---
## 2026‑07 — v1.3.20
**Peer-review recheck 1–5 + 3 additional observations: quote-aware SHA-256 preflight, portable process enumeration, strict arg parsing, per-run zero-length reports, hierarchy-preserving quarantine** *(assisted by Claude/Anthropic — Opus 4.8)*

Eight items after v1.3.19. All confirmed live; all fixed. #2 is the
most important — safety controls silently disappearing when a
dependency is absent is exactly the class of maturity defect this
project has been iterating on.

### #1 (high) — Whole-manifest quote-aware SHA-256 preflight

The v1.3.19 preflight had two bugs: it used naïve `awk -F,` on the
sample row (so a quoted path containing a comma like `"a,b.txt"` mis-split
and reported a 6-character hash), and it only checked the first data row
(so a mixed manifest with a valid SHA-256 first row and later MD5 rows
was accepted). Reviewer reproduced both.

Fix: replaced the sample parser with an awk block that uses the SAME
quote-aware `csv_split` function the main parser uses, and validates
EVERY actionable row — length exactly 64 and hex-only. Any row failing
either check exits rc=2 with the row number and value. Live: comma-path
CSVs accepted; mixed manifest rejected with `[ERROR] Row 4: hash column
has length 32`.

### #2 (critical) — Portable process enumeration; lock survives failed stop

Every stop-path branch used `pgrep`; check-deps only *warned* if it was
absent. On a host without pgrep, `pgrep -g $$` returned empty, no
signals were sent, `_n=0` looked like a clean shutdown, cleanup ran and
released the lock — while xargs, workers, and hash tools kept running.
A fresh run could then start alongside orphans. Reviewer reproduced 12
descendants surviving on a two-worker run with uncooperative TERM.

Fix:
- New `_enum_group_pids` and `_enum_children` helpers that prefer
  `pgrep` but fall back to `ps -eo pid=,pgid=` / `ps -eo pid=,ppid=`.
  ps output is present on every target (DSM BusyBox, macOS BSD, GNU procps).
- Startup probe refuses to run (exit 3) if BOTH pgrep and ps-eo are
  unusable — worker shutdown cannot silently degrade.
- `check-deps.sh` promotes pgrep/ps-eo from "warn-if-missing" to "at
  least one required".
- `HASHER_STOP_INCOMPLETE=1` — if `_stop_group` verifies survivors after
  the KILL escalation, cleanup **refuses to release the lock or pidfile**.
  Operator cleanup required. Better a stuck lock than a fresh run
  starting alongside orphaned workers.
- 0.5s settle before the survivor verification (addresses reviewer's
  additional observation about false-positive survivor warnings).

Live: `PATH=/tmp/nopgrep bash bin/hasher.sh --jobs 3` with uncooperative
workers → 18 group members before TERM, 0 survivors after.

### #3 (high) — Strict arg parsing on delete-junk

Argument parser had no default arm and no `-h`. Typo `--dryrun --force`
silently ignored `--dryrun`, accepted `--force`, and deleted the file.
Now: `-h/--help` prints usage; `--paths-file` requires a value; any
unknown option exits rc=2. Live: `--dryrun --force` → rc=2 refused;
`--dry-run --force` → rc=0 no-delete; `--help` → rc=0 usage; missing
`--paths-file` value → rc=2 refused.

### #4 (high) — Zero-length-only reports are per-run

`post_run_reports` was updated in v1.3.19, but the fast zero-length-only
path at line 1029 still used `DATE_TAG`. Two same-day zero-length-only
scans overwrote each other. Now uses `CSV_TAG` (F-HMS-PID) and
maintains `zero-length-latest.txt`, matching the normal-path convention.

### #5 (medium-high) — Quarantine mirrors source hierarchy

`delete-zero-length.sh` and `apply-folder-plan.sh` encoded destinations
by replacing `/` with `__`. Not reversible: `/a/b__c/f1` and `/a__b/c/f2`
both flatten to `a__b__c__f1`/etc, and the second mv silently
replaced the first while the tool reported success. Reviewer confirmed
the collision.

Fix: mirror the source's absolute path under the quarantine root
(the pattern `delete-duplicates.sh` has used since v1.3.5). Collisions
disambiguated with `.dup{n}` suffix and warned, not silently overwritten.
Also added the belt-and-braces `[ ! -e "$src" ]` post-condition check
so a partial move never counts as successful. Live: reviewer's exact
`b__c` / `a__b` reproduction → both files preserved with distinct
hierarchical paths.

### Additional observations (3)

- **stdin blocking with --pathfile**: `[ ! -t 0 ]` triggered even when
  `--pathfile` was supplied, so `cat > tmp_in` blocked on unrelated
  parent stdin (SSH, orchestration wrappers). Now: if `--pathfile` is
  set, stdin is left alone entirely.
- **`--exclude` help text stale**: still described the semantics as
  "literal substring match" from before v1.3.18. Updated to describe
  the actual case-insensitive glob semantics with the `#recycle`-style
  literal fallback.
- **`clean-logs.sh` retention pattern stale**: `20*-duplicate-hashes.txt`
  didn't match v1.3.19's `duplicate-hashes-YYYY-...` naming, so new
  per-run reports would accumulate indefinitely. Added a matching
  glob for the new naming + retention for per-run zero-length reports
  under `var/zero-length/`. Legacy pattern kept for upgrade paths.

Self-test: 40 passed, 0 warnings, 0 errors. All 21 files pass syntax.

### Mac flexibility (Mary's iMac Tahoe report)

Live diagnosis on a real macOS 15.x install revealed a v1.1.11-era
regression that had made Hasher effectively unusable on Mac external
volumes since 2024. `bash -x` trace showed the failure signature:
`[[ -d "/Volumes/Photo-Disk/" ]]` succeeded, then
`find "$path" -type f -print0` returned exit 1 because
`.DocumentRevisions-V100` in the volume root has mode `d--x--x--x`
(no read bit) and BSD find exits non-zero the moment ANY subtree
fails, even when 99% of the walk succeeds.

Two fixes:

**Partial-walk acceptance in build_file_list.** `find`'s stderr is now
captured. If exit is non-zero AND every stderr line is "Permission
denied", the root is treated as valid with a warning like
`4 subtree(s) skipped (permission denied on system dirs)`. If stderr
contains other error classes, or is empty (I/O error / unmounted stub),
we fall back to the old skip-this-root behaviour. Volumes with a mix
of readable data and permission-locked system dirs now scan cleanly.

**Host-specific find-prune arguments.** New `host_find_prune_args()`
in `lib/host-detect.sh` emits a `-name X -type d -prune -o` clause
per system dir per host. Loaded once at `build_file_list()` entry
and applied to every find invocation. On macOS this prunes
`.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`,
`.TemporaryItems`, `com.apple.TimeMachine.localsnapshots` — so find
never descends into the permission-restricted dirs in the first
place, eliminating the exit-1 condition at source. Synology hosts
prune `@eaDir`, `#recycle`, `@tmp`, `@SynoResource` — massive
speed-up on media volumes. Linux gets an empty prune list and
find behaves normally. Bash 3.2 (macOS stock) compatible via
`while read` rather than `mapfile`. Belt-and-braces companion to
the existing case-insensitive glob excludes in `host_default_excludes`.

Not addressed here (intentionally): guided-setup probing of
`/Volumes/*` for menu-driven path selection, and quieter check-deps
messaging for structurally-absent tools on macOS (setsid, ionice).
Both are quality-of-life improvements, not gaps in load-bearing
functionality. Waiting until another Mac user materialises or a
genuine need surfaces.

---
## 2026‑07 — v1.3.21
**Walk-phase heartbeat: no more silent minutes during discovery** *(assisted by Claude/Anthropic — Opus 4.8)*

Field report from Mary's iMac: after `[INFO] Working dir: ...`, the
background log stayed frozen for 10-15 minutes while `find` walked a
large external drive. Process was alive, but tailing the log gave zero
indication of that — indistinguishable from a hang.

Root cause: `build_file_list()` runs `find` synchronously with no
periodic output. On a small NAS share the walk completes in under a
second and the silence is invisible; on a large Mac external volume
it can genuinely take many minutes. Progress emission
(`start_hash_progress`) only begins AFTER discovery finishes.

Fix: new heartbeat subshell at the top of `build_file_list()`, killed
at exit via both an explicit call and a `RETURN` trap (belt-and-braces
in case an `error/exit` bails out mid-function). Every
`$PROGRESS_INTERVAL` seconds (default 15s) it writes to `$BACKGROUND_LOG`:

```
[timestamp] [RUN uuid] [PROGRESS] Walking paths: N file(s) discovered so far | elapsed=00:00:15
```

The count is read from `$FILES_LIST.tmp` — where find output accumulates
before exclusion filtering — by counting NUL delimiters. Zero on the
first tick is normal (find still running); rises as the walk progresses;
transitions to normal Hashing progress once discovery completes and
the main loop starts.

Applies universally — Mac, Synology, Linux — because the "silent walk"
problem exists on any host with a large filesystem. On a small tree
the walk completes before the first tick and nothing is emitted, so
existing quick runs are unaffected. Self-test: 40 passed, 0 warnings.

---
## 2026‑07 — v1.3.22
**Sorted CSV output — deterministic, fail-safe, cross-run diffable** *(assisted by Claude/Anthropic — Opus 4.8)*

User request: sort the output CSV by path after hashing. Motivation:
deterministic output for cross-run diffing (someone hashing quarterly
can now `diff old.csv new.csv` and see exactly what changed), human
scan-ability of the manifest, and reproducible outputs for
hash-of-hash workflows. Currently rows land in worker-race order —
useless for the above.

Design principle: **the original CSV is NEVER touched until the sorted
candidate has been fully validated.** A 5-hour hashing session must
not be corrupted by a bad sort. Concretely:

1. Snapshot pre-sort state: line count, byte count, header line.
2. Sort to a sibling temp file (same directory, so `mv` is atomic).
3. Validate: line count matches, header intact, byte-count within 1
   byte of original (allowing for a trailing-newline difference).
4. Only then atomic-rename onto the original.
5. On any failure at any step, keep the original untouched and warn.

Additional design choices:
- `LC_ALL=C sort` — byte-order determinism across locales.
- Full-row sort (not path-keyed) — sidesteps the CSV-quoted-comma
  parsing trap. Works correctly because path is the first column;
  in practice full-row sort ≈ path sort.
- Refuse to sort if the header doesn't start with `path` — protects
  against shuffling a rogue first data row into position when the
  header is missing.

Default on. Config toggle `sort_output = true|false` under `[logging]`
in hasher.conf. CLI overrides `--sort` and `--no-sort`. First-run
notice emitted to `$BACKGROUND_LOG` on the very first hashing run of
a fresh install (marker file `var/.sort-notice-shown`), explaining
the behaviour and how to disable it.

Verified live:
- **Normal case**: 13 files hashed in reverse-alphabetical order →
  CSV output byte-identical to `LC_ALL=C sort`. First-run notice
  appears on first run only.
- **--no-sort flag**: rows preserved in worker-race order, no sort
  attempted.
- **Sort failure recovery**: PATH-shim exits `sort` with rc=1 →
  three warnings logged, CSV survives unaltered with header + all
  data rows intact. No corruption.

Downstream tools (`find-duplicates.sh`, `find-duplicate-folders.sh`)
already re-sort their inputs internally, so pre-sorted CSVs cause
no behaviour change there.

Self-test: 40 passed, 0 warnings.

---
## 2026‑07 — v1.3.23
**Peer-review recheck 1–5 + 5 additional observations: pgrep behavioural probe, orphan-worker lock protection, post-hash re-stat, exit-code fidelity, dedup artefact per-run tagging, job cap, extended manifest validation, dead-code cleanup** *(assisted by Claude/Anthropic — Opus 4.8)*

Ten items from the recheck. The recurring theme in this round was
**class-extensions of earlier fixes that hadn't been fully propagated**.
v1.3.20 #2 fixed pgrep-vs-ps at the enumerator sites but relied on
`command -v` — reviewer's #1a: also behaviourally probe. v1.3.19 #5
fixed the CSV_TAG in `hasher.sh` post_run_reports but not in
`find-duplicates.sh` or `find-duplicate-folders.sh` — reviewer's #5:
propagate. Recognising the pattern was as valuable as any single fix.

### #1a (critical) — Behavioural pgrep probe

`command -v pgrep` returns success as long as the binary exists. A broken
build (missing /proc access, unimplemented -g/-P) would then pass the
guard and every enumeration would silently return empty. Startup now runs
`pgrep -g $PGID` and expects at least one PID back; `pgrep -P $$` must
exit cleanly (0=matches, 1=no matches). If either check fails,
`HASHER_USE_PGREP=0` and every subsequent enumeration takes the ps
fallback path. `command -v` gate removed from the enum helpers. Fix
along the way: `pgrep -P $$` returns exit 1 (no children) which `set -e`
was treating as a script failure — added `|| _probe_p_rc=$?` guard.

### #1b (high) — Bounded settle wait

Previous shutdown used a fixed `sleep 0.5` before checking for
surviving descendants. On a busy NAS the kernel may not have finished
reaping KILL'd processes in 0.5s, and pgrep would count them as
"survivors" — triggering the "descendants survived" error path and
refusing to release the lock even after a clean shutdown. Now polls
every 100ms up to 3 seconds, exits early when the count drops to 0.
False-positive "survivor" errors go away; genuinely stuck workers
still block lock release, as intended.

### #2 (critical) — Rich lock ownership, orphan-worker protection

Previous stale-lock adoption checked only whether the recorded PID was
alive. If the operator `SIGKILL`'d the hasher parent, the workers
survived under the old PGID but the parent PID was dead; a subsequent
run saw a "stale" lock, removed it, and started fresh — with the OLD
workers still reading the disk. Concurrent hashing on the same corpus.

Lock now stores four fields: `pid`, `pgid`, `boot_id` (from
`/proc/sys/kernel/random/boot_id` on Linux, `sysctl -n kern.boottime`
on macOS/BSD), and `start_ts`. Adoption logic:

- Recorded PID alive → refuse (as before).
- Different boot ID → adopt cleanly (all old PIDs and PGIDs are
  provably dead across reboots).
- Same boot, dead PID, but PGID has live processes → refuse with
  explicit instructions: `kill -TERM $orphans`, wait ~5s, then
  `kill -KILL $orphans`, then `rm -rf $lockdir`.
- Same boot, dead PID, PGID has no survivors → adopt with warning.

Live-verified: `HASHER_SESSION_LEADER=1 hasher.sh --jobs 3` with
uncooperative worker shim, `kill -9` the parent → 15 workers alive
under stale PGID; second run correctly refused adoption (rc=2) with
the exact "orphaned workers" message.

### #3 (high) — Post-hash re-stat, best-effort record

The worker previously stat'd once before hashing; a file modified
DURING the hash produced a CSV row with old size + old mtime + new
content hash. Now re-stats after hashing. If size or mtime drifted,
the worker emits a `\036CHANGED\036` marker alongside its normal
row; the main loop routes markers to `$changed_file`, which becomes
`logs/hash-changed-$CSV_TAG.log` at run end. The CSV row still uses
pre-hash values (best-effort policy — chosen over retry-and-skip)
so no rows are dropped, but the operator sees which files were
unstable and can re-hash them if a consistent snapshot matters.
Live: 2 files mutated mid-hash by a sha256sum shim → 2 CHANGED
entries logged with size/mtime diffs, WARN emitted, rc=0.

### #4 (high) — Destructive tools return non-zero on failure

`delete-zero-length.sh`, `apply-folder-plan.sh`, `delete-duplicates.sh`
each tracked `fail` counters but ended with unconditional `exit 0`.
Cron/automation saw "success" while files remained. Same class of
bug fixed in `delete-junk.sh` at v1.3.19 that hadn't propagated.
All three now `exit 1` if `fail > 0`. "Skipped because content
changed" is treated as a safety outcome, not a failure — still
returns 0 with a warning.

### #5 (high) — Dedup artefacts get per-run tags

`find-duplicates.sh` used `date +'%Y-%m-%d-%H%M%S'` and
`find-duplicate-folders.sh` used `date +%F-%H%M%S` — both
second-precision, no PID. Two runs within the same second (which
absolutely happen in scripted workflows or menu chains) overwrote
each other. Now both append `-$$` per the CSV_TAG convention
established in v1.3.16 for `hasher.sh`. `find-duplicates.sh`
canonical file also changed from
`${date_tag}-duplicate-hashes.txt` (date only) to
`duplicate-hashes-$timestamp.txt` (full run tag) with a
`-latest.txt` symlink for stable next-step references. Mirrors
`hasher.sh` post_run_reports pattern from v1.3.19.

### Observations (5)

- **Obs A**: `--jobs` accepted any positive integer, so `--jobs 99999`
  or a config typo `jobs = 10000` would spawn thousands of workers.
  Cap at `min(cores*2, 64)` using `nproc` or `sysctl -n hw.ncpu`
  for detection, clamped values logged as WARN. Override via
  `HASHER_MAX_JOBS=N` for deliberate operators.
- **Obs B**: `find-duplicates.sh` preflight now validates the `algo`
  column when present — every row must be `sha256` (case-insensitive).
  Older manifests without an algo column still work (they get the
  hash-length preflight only).
- **Obs C**: malformed CSV rows (fewer columns than needed) were
  silently ignored, so a truncated manifest could quietly drop files.
  Preflight now COUNTS rejected rows and reports the first offending
  line number to stderr. Non-fatal by default (proceeds with valid
  rows); `HASHER_STRICT_ROWS=1` makes them fatal.
- **Obs D**: `${ZERO_LENGTH_ONLY:+(zero-length-only mode) }` fired
  whenever the variable was non-empty — including the string
  "false". Every normal --nohup run displayed "(zero-length-only
  mode)". Replaced with explicit `$ZERO_LENGTH_ONLY && ...` test.
- **Obs E**: `_resolve_hash_cmd` had branches for sha1/sha512/md5/blake2
  that were unreachable since v1.3.16's ALGO check. Removed dead
  code and left an explicit "unreachable if callers validate first"
  comment on the default arm.

Self-test: 40 passed, 0 warnings, 0 errors. All 21 files pass syntax.

---
## 2026‑07 — v1.3.24
**Peer-review recheck 2, 3, 4 + lower-priority cleanup: same-PGID orphan hole, snapshot-integrity exclude-and-log, TOTAL==0 short-circuit, SHA-256 policy tidy-up, self-test CI mode, sentinel-free unstable log** *(assisted by Claude/Anthropic — Opus 4.8)*

Second recheck round on top of v1.3.23. Reviewer flagged five items;
cross-check disqualified one and requested policy revision on another.

**Reviewer's #1 (RETURN trap functrace leak)** — investigated and
declined. Claim was that `set -E` enables `functrace`, so the
`_stop_walk_hb` RETURN trap installed by `build_file_list` would
fire from every subsequent function's return with `walk_hb_pid`
unbound. Verified with `set -o | grep functrace`: bash's `set -E`
enables `errtrace` only; `functrace` remains off. The RETURN trap
correctly fires from `build_file_list` alone. No fix needed.

**Reviewer's #2 (same-PGID orphan-check hole)** — CRITICAL, fixed.
v1.3.23's stale-lock adoption only checked orphaned workers when
the recorded PGID differed from ours: `if [[ ... "$_lockpgid" !=
"$_my_pgid" ]]`. In the no-session-isolation code path (setsid
absent or bypassed), two consecutive hasher invocations from the
same terminal share a PGID — so the check was skipped and the
lock adopted even if the previous run's workers were still alive
inside the shared PGID. Fix: fail closed whenever the recorded
parent is dead and the PGID has any live non-self PIDs, regardless
of whether the PGID matches ours. The error message acknowledges
that in the shared-PGID case we can't distinguish orphans from
siblings — either way, we don't dare adopt. Live-verified with
a fake sibling process in our PGID + a synthetic stale lock;
second run correctly refused (rc=2).

**Reviewer's #3 (files changing during hash)** — HIGH, policy
revised. In v1.3.23 I chose "best-effort: warn but record with
pre-hash stats" per user direction. Reviewer's counter-argument
on data-integrity grounds: a CSV row
`path,size=6,mtime=T,algo=sha256,hash=<of size-19 content>`
describes a state that never existed as one consistent snapshot;
downstream tools trust hash + size + mtime as a unit, so an
inconsistent row is worse than a missing row. User accepted
reversal. Fix: worker now emits ONLY the `\036CHANGED\036`
marker (no CSV row) when pre/post-hash stats disagree. Main-loop
dispatcher routes the marker to `logs/unstable-files-<run>.log`
(renamed from hash-changed for accuracy). Sentinel is stripped
before write, per lower-priority cleanup item. Completed
message shows `unstable=N` when non-zero:
`Completed. Hashed 5/5 files (failures=0, unstable=5)`.
`DONE = hashed + failed + unstable`, so tally always sums to
TOTAL. Live-verified with an sha256sum shim that mutates its
input mid-hash: 5 files mutated → 0 CSV rows, unstable-files log
lists all 5 with size/mtime diffs, rc=0.

**Reviewer's #4 (empty dir with `--jobs 2`)** — HIGH, fixed.
Root cause: `xargs` invoked with empty stdin behaves differently
across platforms. GNU xargs with `-r` skips (which we can't
rely on — BSD/macOS xargs has no `-r`). BSD xargs runs the
command once with no arguments, so `_hash_worker $1` receives
`$1=""`, stats fail, and the CSV summary reads
`Completed. Hashed 1/0 files (failures=1)` — a fabrication.
Fix: handle `TOTAL <= 0` before workers are spawned. Write the
CSV header, run the sort pipeline (still fail-safe), skip the
progress emitter entirely, run `post_run_reports` (which correctly
reports 0 duplicates and 0 zero-length files), and return.
Verified: empty dir + `--jobs 2` → rc=0, one INFO line
`No files to hash (0 discovered). CSV contains header only`,
header-only CSV, no fake failure count.

**Reviewer's #5 (malformed rows warn-and-continue)** — declined
as policy choice. Reviewer requested fatal-by-default with an
`--allow-malformed-rows` opt-out. v1.3.23 shipped the inverse:
non-fatal by default with `HASHER_STRICT_ROWS=1` opt-in. User
retained the deployed default. Both are defensible; documenting
the choice so the next reviewer sees it was deliberate.

### Lower-priority cleanup

- **ALGO comment**: `sha256|sha1|sha512|md5|blake2` line was
  stale — SHA-256 has been the only supported algorithm since
  v1.3.16. Updated to `# SHA-256 only since v1.3.16`.
- **check-deps.sh --fix**: removed the sha1sum/sha512sum/md5sum
  shim-creation calls that had been unreachable for many
  releases. b2sum was never invoked. Doc header updated.
- **self-test.sh modes**: `--strict` was unsuitable for CI on a
  fresh checkout because an empty paths.txt is expected there
  (nobody has configured scan paths yet). Split into
  `--installation-strict` (old behaviour, alias for `--strict`,
  suits deployed NAS) and `--ci-strict` (fails on all warnings
  EXCEPT paths.txt-not-configured). Both live-verified.
- **Unstable-files log**: internal `\036CHANGED\036` sentinel
  stripped before the file is renamed into `logs/`, so `cat`
  and `less` show clean paths. Header comment added with
  format description and run tag.

Self-test: 40 passed, 0 warnings, 0 errors. All 21 files pass syntax.

---
## 2026‑07 — v1.3.25
**Peer-review recheck 2, 3, 4, 5: symlink policy, exit-status fidelity, richer stability fingerprint, hard-link detection** *(assisted by Claude/Anthropic — Opus 4.8; folder-plan sidecar resolution patched by peer reviewer)*

Fifth round of peer review. Reviewer flagged five items; #1 was a
sidecar resolution regression they patched in-place (kept in this
release) and four new findings. All four confirmed real, all four
fixed.

### Reviewer's #1 — folder-plan sidecar resolution (patched by reviewer)

`find-duplicate-folders.sh` in v1.3.23 was updated to add PIDs to
artefact timestamps (`duplicate-folders-plan-YYYY-MM-DD-HHMMSS-PID.txt`),
but `apply-folder-plan.sh` was still deriving the matching sidecar via
a regex that only captured the pre-PID portion — so every planned
delete was skipped for lack of a keeper map. Reviewer patched
`apply-folder-plan.sh` to derive the full suffix from the plan
basename (`${_plan_base#duplicate-folders-plan-}` then `%.txt`) with
`_stamp` and `_date` fallbacks for older artefacts. Retained in
v1.3.25 as-shipped by the reviewer. Meta-observation: I should have
audited every downstream parser when I introduced the PID in v1.3.23,
not left it for the reviewer to catch.

### #2 (critical) — Symlink policy

Two problems, one policy. Symlinks explicitly listed in `paths.txt`
were previously followed by `[[ -f "$path" ]]` (which follows
symlinks) and hashed as though they were regular files — the CSV
row then had the symlink's own stat with the target's content
hash. Directory scans already skipped symlinks via `find -type f`.
Separately, folder-dedup only fingerprinted regular files, so a
folder containing a unique symlink alongside identical regular
files matched an otherwise-similar folder — and applying the plan
moved the whole folder including the unique symlink.

Fix — the safer of the reviewer's two options:
- Explicit symlinks in `paths.txt` and via stdin are refused with a
  warning naming the target-real-path fix. All three input sites
  (pathfile, stdin single-file, stdin expanded) now check `[[ -L ]]`
  before `[[ -f ]]`. A `pathfile_syminv` counter feeds a specific
  "All N paths are symlinks — refused" error when applicable, so
  operators don't see the misleading "missing or unreadable"
  message.
- `find-duplicate-folders.sh` filters out any group where the KEEP
  or DEL folder has direct non-regular children (symlinks, FIFOs,
  sockets, devices) using `find -mindepth 1 -maxdepth 1 -type l/p/s/b/c
  -print -quit`. Logs the exclusions to
  `logs/duplicate-folders-excluded-<stamp>.log` with the exact
  offending path so operators can inspect.

Live-verified: explicit symlink → rc=3 with "All 1 path(s) are
symlinks — refused" message; two folders identical except a
unique symlink child → excluded from dedup with the specific
symlink path logged.

### #3 (high) — Exit-status fidelity

`Completed. Hashed N/T (failures=F)` used to return rc=0 regardless
of F, and a header-only CSV from a total-failure run was
indistinguishable from a completed empty-input run. Automation
could accept it as a successful snapshot.

Fix:
- Redesigned summary line: `Processed N/T files: hashed=X, failed=F,
  unstable=U`. Each count separately visible.
- New exit codes: `0` = all hashed, `1` = one or more hash/stat
  failures, `4` = no hard failures but one or more files unstable
  (partial snapshot). Reserved earlier: `2` invalid input/config,
  `3` missing tools.
- Loud "PARTIAL SNAPSHOT" warning block emitted BEFORE next-step
  reports whenever failures or unstable rows > 0. Reviewer's
  specific concern was that automation reads
  "Duplicate report ready: ..." and assumes the snapshot is
  complete — the banner now precedes those lines.
- `HASHER_RUN_STATUS` global set by main hashing; cleanup trap
  honours it on EXIT via a final `exit $status`.

Live-verified: 3-file all-success → rc=0; sabotaged sha256sum
(all-fail) → rc=1, PARTIAL SNAPSHOT banner; mutating shim
(all-unstable) → rc=4, PARTIAL SNAPSHOT banner.

### #4 (high) — Richer stability fingerprint

v1.3.24's pre/post-hash check compared only size and whole-second
mtime. Reviewer demonstrated a mutate + restore sequence (touch
back to original mtime, same-size content) that slipped through
undetected, yielding a CSV row whose hash didn't match the file's
final content. Atomic replacements that preserve size and mtime
also change the inode without being caught.

Fix: new `_stat_fingerprint()` helper returns
`size|mtime|ctime|dev|ino` across GNU and BSD stat variants.
Worker captures pre-hash fingerprint before hashing and post-hash
fingerprint after; any change in any field routes to CHANGED
marker (no CSV row, no false hash). ctime bumps on ANY write even
when size and mtime are restored, so the mutate+restore case is
closed. Inode/device catch atomic renames and cross-filesystem
substitution.

Unstable log format updated to record the full pre/post
fingerprints for diagnosis.

Live-verified: shim mutates file content but preserves size + mtime
via `touch -d @<orig_mtime>` → run rc=4, unstable log shows
fingerprints matching in size/mtime/dev/ino but differing in
ctime — the exact drift the reviewer's scenario was designed
to detect.

### #5 (medium-high) — Hard-link detection

`find-duplicates.sh` treated hard links to the same inode as
separate reclaimable duplicates. Reviewer demonstrated: two hard
links to a 1 MiB file → plan says "quarantine one, reclaim 1 MiB"
→ move one path → same inode with same link count remains, zero
bytes reclaimed. If quarantine crosses a filesystem, the mv
becomes a cp and DUPLICATES the data.

Fix: after `OUT_CSV` is built (BEFORE canonical-report awk
consumes it), stream through rows and collapse by
`(hash, device, inode)` using portable `stat -c "%d %i"` /
`stat -f "%d %i"`. Only the first path per physical object is
kept; additional hard-link paths are logged to
`logs/hardlinks-excluded-<stamp>.log` with clear `HARDLINK path
same-inode-as keeper` notation. Runs in BOTH standard and bulk
modes so the canonical group report agrees with the plan.

Live-verified: 4 files, 3 sharing one inode via hard links + 1
genuine independent duplicate → hard-links log has 2 entries,
duplicates CSV contains only the first-seen hard-link path and
the genuine duplicate. Bulk-mode plan generates one KEEP + one
DEL for the genuine duplicate; no hard-linked paths in the plan.

### Regression check

Normal case: 4 files, no symlinks, no hard links, 2 genuine
duplicates → run rc=0, "Processed 4/4 files: hashed=4, failed=0,
unstable=0", 1 dedup group. No spurious PARTIAL SNAPSHOT banner,
no false hard-link warning.

Self-test: 40 passed, 0 warnings, 0 errors. All 21 files pass syntax.

---
## 2026‑07 — v1.3.26
**Critical safety and workflow fixes: immutable reports, apply-time special-entry checks, canonical quarantine paths, current-run folder plans, and partial-manifest isolation**

This release addresses five operational findings confirmed during the
v1.3.25 review.

### 1. Duplicate-report history is now immutable

`find-duplicates.sh` previously opened
`logs/duplicate-hashes-latest.txt` for writing before the new report was
complete. Because that pathname was normally a symlink, the open followed
the link and truncated the preceding run-specific report. A no-duplicates
run could therefore erase the previous report entirely.

The finder now writes only to the new immutable run-specific report. Once
rendering and optional bulk-plan generation have completed, it creates a
temporary symlink (or copy on filesystems without symlink support) and
atomically renames that temporary pathname over the latest pointer. Standard,
bulk and no-results runs all use the same safe publication path.

### 2. Folder apply rechecks non-regular entries

Folder-plan generation already excluded leaf folders containing symlinks,
FIFOs, sockets or device nodes, but a folder could gain one of those entries
after planning. Apply-time verification compared regular-file signatures only
and would then move the whole directory, including the unexamined entry.

`apply-folder-plan.sh` now repeats the special-entry check immediately before
moving both the planned delete folder and its keeper. Any newly introduced
non-regular child causes a fail-safe skip and an audit-log entry.

### 3. Canonical paths and quarantine containment

Raw manifest spellings containing `.` or `..` could previously be joined
directly to the quarantine root. Filesystem path resolution could then place
the destination outside the configured quarantine directory while the tool
reported a successful quarantine.

New shared helpers in `lib/host-detect.sh` canonicalise existing paths without
making GNU `realpath` a mandatory dependency, verify component-aware path
containment, and construct hierarchy-preserving quarantine destinations only
after their physical parent path is proven to remain below the quarantine
root. `hasher.sh` records canonical paths at discovery, and all file, folder
and zero-length quarantine workflows use the shared containment check. Final
component symlinks are refused before canonicalisation so a plan cannot be
redirected to, and then move, the symlink target.

### 4. Folder detection only advertises the current run's plan

After a folder scan, the launcher previously selected the newest plan from all
historical files. If the current scan found no duplicates, an older plan could
be presented as though the new run had created it.

The launcher now snapshots raw folder-plan filenames before invocation and
uses the exact set difference afterwards. It resolves the groups sidecar from
that new plan's complete timestamp-and-PID suffix. A no-results run therefore
offers nothing historical for review or application.

### 5. Partial manifests are no longer promoted

Hash failures or unstable files already produced non-zero exit statuses, but
the incomplete CSV still used the normal `hasher-*.csv` naming pattern,
updated `*-latest` report pointers and printed destructive next-step commands.
The launcher could then select it as the newest actionable snapshot.

Incomplete default manifests are now retained under a `partial-hasher-*.csv`
name (custom output paths receive a `.partial` marker). Their run-specific
diagnostic reports are retained, but latest pointers are not updated and no
dedupe or cleanup commands are recommended. Only a fully successful run is
published into the normal actionable workflow.

### Validation

- Shell syntax passed for `launcher.sh`, all `bin/*.sh` and all `lib/*.sh`.
- Historical duplicate reports remained unchanged across duplicate and
  no-duplicate finder runs.
- A planned folder that gained a symlink was skipped at apply time.
- `..`-bearing source spellings were canonicalised and quarantined strictly
  beneath the configured root in file, folder and zero-length workflows.
- A no-results folder run did not resurrect a historical plan.
- A forced hashing failure returned non-zero, created only a
  `partial-hasher-*.csv`, preserved the previous latest pointers and printed
  no actionable cleanup commands.

---
## 2026‑07 — v1.3.27
**Manifest completeness, run-consistent plan selection, reliable shutdown cleanup, and overlapping-root correctness**

This release addresses five findings confirmed during the live v1.3.26 review.

### 1. Overlapping and repeated scan roots are de-duplicated

A parent directory and one of its descendants could both be configured as scan
roots, causing the same canonical file to be hashed more than once. Besides
wasting disk I/O, repeated CSV rows could make otherwise-identical folder
signatures differ and hide valid duplicate-folder matches.

After delimiter-unsafe paths are removed, `hasher.sh` now de-duplicates the
NUL-delimited discovery list using a portable newline sort (safe at that point
because TAB/LF/CR paths have already been rejected). The run reports how many
repeated discovery paths were removed.

### 2. Folder plans and groups remain tied to one scan

The folder reviewer previously selected the newest plan and newest groups TSV
independently. The apply menu also preferred any reviewed plan even when a
newer raw scan existed.

The launcher now derives a raw groups sidecar from the plan's complete
timestamp-and-PID suffix. The review action uses the newest raw plan and its
exact sidecar. The apply action compares raw and reviewed plan modification
times and surfaces the newer run, warning when that newest plan is unreviewed.

### 3. Malformed manifests fail closed

Both file and folder duplicate discovery could skip malformed rows and still
produce actionable plans from the remaining records. A truncated manifest can
therefore appear complete while silently omitting files.

Malformed rows now stop plan generation by default. The explicit
`--allow-malformed-rows` option remains available for forensic or recovery use;
SHA-256 validation is never relaxed.

### 4. Signal cleanup reaps the tracked pipeline and ignores zombies

TERM/KILL escalation could successfully stop every worker but retain the lock
because the final count included exited processes awaiting reaping, or because
the last count was taken immediately before the final polling sleep.

The signal handler now waits for its tracked pipeline after escalation,
filters zombie processes from group/child enumeration, and performs a final
fresh count after the bounded wait before deciding whether the lock must be
retained.

### 5. Launcher helper failures are no longer presented as success

The duplicate-finder, reviewer and plan-apply paths previously discarded many
helper exit statuses with `|| true`. A failed scan could consequently be
followed by normal success or no-results wording.

The launcher now captures and reports return codes for the principal file and
folder dedupe workflows. It distinguishes a completed no-results scan from a
failed scan and reports partial or failed plan application explicitly.

### Validation

- Shell syntax passed for `launcher.sh`, all `bin/*.sh`, and all `lib/*.sh`.
- Overlapping roots produced one manifest row per canonical file.
- File and folder finders rejected malformed manifests by default and accepted
  them only with the explicit recovery option.
- Folder plan review used the exact timestamp-and-PID sidecar, and a newer raw
  plan took precedence over an older reviewed plan.
- TERM escalation reaped the tracked pipeline and released the lock when no
  live non-zombie workers remained.
- Launcher discovery failures were reported as failures rather than as
  successful no-results runs.

---
## 2026‑07 — v1.3.28
**Keeper re-verification, fail-closed folder signatures, report provenance, and truthful partial-apply status**

This release addresses five findings confirmed during the live v1.3.27 review.

### 1. File plans re-verify the keeper

File-plan apply now ties every hashed `DEL` group to exactly one `KEEP` entry.
Immediately before each planned move, the keeper must still exist as a regular
non-symlink file and its current SHA-256 must match the group hash. Missing,
changed, unreadable, duplicate or ambiguous keepers cause the group to be
safety-skipped. Newly generated plans include the group hash on both `KEEP`
and `DEL` entries; older hashed plans remain supported by inferring the keeper
from the grouped plan order. The interactive “delete all copies” action is
disabled because a verified dedupe group must retain one keeper.

### 2. Folder signatures fail closed

`apply-folder-plan.sh` resolves a SHA-256 implementation before verified apply.
`dir_signature()` now returns failure if discovery, stat or hashing fails for
any direct file. The delete folder is skipped and the command returns non-zero
rather than degrading to filename-and-size comparison with empty hashes.

### 3. Preliminary and verified duplicate reports are separated

The quick summary emitted after hashing is now named
`hash-scan-duplicate-summary-*`. Only `find-duplicates.sh` publishes
`duplicate-hashes-latest.txt`. Finder reports carry an embedded provenance
marker and hard-link-filter status; interactive review and auto-dedup refuse
reports without those safety markers.

### 4. Auto-dedup cannot resurrect an older plan

The launcher supplies an exact run-specific `--plan-out` path, checks the
helper return code, and offers only that invocation's plan. A failed or aborted
auto-dedup run cannot fall through to a historical plan.

### 5. Safety skips have a distinct exit status

File and folder plan apply return status `4` when verification causes one or
more entries to be skipped. The launcher reports this as “completed with
safety skips” rather than claiming the plan was fully applied. Operation
failures continue to return status `1`; invalid or unsafe input returns `2`.

### Validation

- Keeper removal and keeper content drift prevented all corresponding file
  moves and returned status `4`.
- A forced folder hash-command failure moved no folder and returned non-zero.
- Hashing no longer overwrote the verified duplicate-report pointer.
- Review and auto-dedup rejected unmarked preliminary reports.
- A failed auto-dedup invocation did not offer a historical plan.
- File and folder verification skips were surfaced distinctly by the launcher.

---
## 2026‑08 — v1.3.29
**Automatic post-hash duplicate discovery**

- Added automatic duplicate-folder and duplicate-file discovery after a fully
  successful hash run. Partial manifests and header-only manifests are never
  analysed.
- Discovery uses the exact CSV produced by the current run, performs folder
  discovery first, and records finder failures as post-processing warnings
  without changing the successful hash-manifest status.
- Added the `auto_discover` configuration switch and matching command-line
  controls.

---
## 2026‑08 — v1.3.30
**Prepared duplicate-review indexes and independently configurable post-hash analysis**

Automatic discovery removed the manual option-3 wait, but interactive review
still re-read every group and stat-ed one live file per group to calculate
potential savings. On a 24,955-group report this could add roughly 15–20
minutes before the first group was shown.

### Prepared review index

- `find-duplicates.sh` now builds
  `logs/duplicate-review-index-YYYY-MM-DD-HHMMSS-PID.tsv` by default.
- The index is generated in the same AWK rendering pass as the canonical
  report, so group numbers, hashes and member counts belong to exactly the same
  finder run.
- Potential reclaim is calculated from manifest sizes already present in the
  hard-link-filtered intermediate, avoiding tens of thousands of NAS `stat()`
  calls.
- `duplicate-review-index-latest.tsv` is published atomically beside
  `duplicate-hashes-latest.txt`; historical indexes remain immutable.
- `review-duplicates.sh` derives the exact index from the report's complete
  timestamp/PID suffix, verifies both source report and source CSV, applies the
  current exceptions list, and skips the expensive live indexing pass.
- Older or manually copied reports remain supported. When no matching valid
  index exists, review falls back to the previous safe live-indexing workflow.

### Independent post-hash controls

The combined v1.3.29 switch is supplemented by:

```ini
[post_hash]
auto_find_duplicate_folders = true
auto_find_duplicate_files = true
auto_build_review_index = true
```

This lets installations that have completed folder cleanup disable only folder
discovery while still preparing file reports and the review index. The older
`auto_discover` key remains accepted for backward compatibility. The v1.3.29
shipped placement of `auto_discover` and `sort_output` under `[logging]` is also
honoured during upgrades.

### Retention and documentation

- `clean-logs.sh` retains the five newest immutable review indexes while
  preserving the latest pointer.
- Updated command help, README configuration guidance, release metadata and
  this version history.

---
## 2026‑08 — v1.3.31
**Statistics-led launcher workflow**

- Added a compact, run-matched post-hash analysis summary beneath the existing
  ASCII header.
- Automatic workflow users are guided directly to folder review, file review
  and plan application.
- Moved manual duplicate discovery into a dedicated rerun-analysis submenu.
- Added immutable post-hash summary metadata for launcher display.

---
## 2026‑08 — v1.3.32
**Automatic/manual analysis workflow selection**

- Added a final first-run choice between automatic and manual duplicate
  analysis, with automatic as the recommended time-saving default.
- Automatic mode shows the compact review-first menu; manual mode preserves the
  traditional discovery-first menu and numbering.
- Added launcher option `m` to change the workflow later.
- `hasher.sh` skips post-hash discovery when manual mode is selected.

---
## 2026‑08 — v1.3.33
**Analysis-state accuracy and workflow guidance fixes**

- Fixed `analysis_mode` persistence for both `[post_hash]` and `[post-hash]`
  sections, preserved configuration formatting, and verified the saved value.
- First-run setup is marked complete only after the workflow choice is written
  and read back successfully.
- The launcher now validates the post-hash metadata provenance marker and shows
  a directed stale/missing-analysis message instead of silently hiding stats.
- Corrected folder statistics to distinguish duplicate groups from folders
  proposed for quarantine.
- Manual duplicate-analysis reruns refresh the same launcher summary used by
  automatic discovery.
- Added source CSV/report provenance to newly reviewed file plans and source CSV
  provenance to newly reviewed folder plans.
- The automatic menu detects a current reviewed plan and recommends applying it;
  no-plan guidance is now aware of automatic versus manual menu numbering.
- Restored this document's title and chronological structure.


---
## 2026‑08 — v1.4.0
**Milestone release — first-run launch screen and workflow maturity**

Version 1.4.0 marks the point where the workflow, not just the engine, is
considered production-ready. The 1.3.x series closed seven rounds of external
peer review covering process safety, snapshot integrity, path handling, and
plan provenance. This release completes the user-facing half of that work.

### First-run launch screen

Until a hash manifest exists, every review and cleanup action in the main menu
needs a manifest as its input — selecting any of them produces nothing but a
"no manifest found" message. The launcher now detects this state and presents a
focused welcome screen instead:

- One recommended action: **Initiate first Hasher run**.
- **Settings & preferences** submenu covering scan paths, performance, analysis
  mode, and system diagnostics — everything a first-time user might want to
  adjust before committing to a long run.
- **Help & information** explaining what the hash run reads, what it records,
  and — stated explicitly — that it does not modify, move, or delete files.
- While a first run is in progress the screen switches to status, follow-log,
  and stop controls, so the user always has something useful to do.

The full workflow menu takes over automatically once the first manifest is
written. No configuration, no mode to set.

New helper `hasher_processes_running()` — a boolean wrapper around
`list_hasher_pids()` — backs the running/not-running branch. It was referenced
by the first-run screen before being defined; defining it here keeps the
pidfile check and the orphan scan consistent with `ensure_no_running_hasher()`.

### Documentation

- `readme.md` menu section rewritten. It previously showed a pre-v1.3.31
  layout that no longer matched either mode. Both current menus are now
  documented separately, with the first-run screen shown first.
- Recommended-workflow sections corrected. The step-by-step sequences used
  option numbers from an older layout (2 = files, 3 = folders) that were wrong
  in both automatic and manual mode. Each workflow now gives the correct
  sequence for both modes, with a note that numbering differs between them and
  that the summary line above the menu always names the right option.
- Version references updated across `launcher.sh`, `default/hasher.conf`, and
  `readme.md`.

### Carried forward from v1.3.33

All v1.3.33 launcher fixes are preserved in this release and were re-verified
after the merge: metadata provenance validation, the three-state analysis
summary (missing / stale / fresh), the `pending_blank` config-writing fix, and
the `set_analysis_mode` read-back verification.


## Future Roadmap  

- Lifetime GB‑saved metrics  
- Dedup analytics export  
- Parallel hashing engine  
- JSON structured output  
- Optional metadata extraction

---
