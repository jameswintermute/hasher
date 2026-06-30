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
## Future Roadmap  
- Lifetime GB‑saved metrics  
- Dedup analytics export  
- Parallel hashing engine  
- JSON structured output  
- Optional metadata extraction

---
