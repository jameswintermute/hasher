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
**macOS readiness: bash-3.2 nounset fix + fail-loudly on missing roots** *(assisted by Claude/Anthropic — Opus 4.7)*

### Critical bug fixes

- **`bin/hasher.sh`** — fixed `EXTRA_EXCLUDES[@]: unbound variable`
  crash on bash 3.2 (Synology DSM, macOS `/bin/bash`) when the script
  was invoked without any `--exclude` flags. Bash 4.4+ silently
  tolerates `${empty_array[@]}` under `set -u`; bash 3.2 treats it as
  a nounset error and aborts mid-run. Both `EXTRA_EXCLUDES[@]` and
  `DEFAULT_EXCLUDES[@]` (which can also be empty when
  `defaultexcludes=0` in config) now use the portable `${arr[@]:-}`
  form. Empty slots introduced by the `:-` expansion are filtered
  out before being passed to awk so the exclude filter remains
  byte-exact.

- **`bin/hasher.sh`** — fail loudly when no listed roots exist on disk.
  Previously a `paths.txt` listing only missing/unmounted paths
  produced a silent "Discovered 0 files" successful run with an empty
  CSV. Now exits non-zero with a clear, actionable error listing each
  missing path and the most common causes (disk not mounted, NAS
  share offline, typo in paths.txt — case matters on macOS volume
  names). New exit code 3 distinguishes "no readable roots" from
  exit 2 ("no input paths provided at all").

- **`launcher.sh`** — preflight gate. Both `run_hasher_nohup` and
  `run_hasher_interactive` now refuse to spawn `hasher.sh` when
  preflight detects all listed roots are missing. Previously the
  launcher always spawned, then either hit the bash-3.2 nounset
  crash or completed silently, with the "Hasher may not be running"
  warning misleadingly reported on legitimate config errors.

- **`launcher.sh`** — post-spawn detection now handles fast
  completions. Previously the check was `tail -n 5 logs/background.log
  | grep -q 'Run-ID:'`; on a fast/empty run hasher.sh can complete in
  well under the launcher's 1-second sleep, scrolling Run-ID off the
  tail. The check now scans the whole log and recognises three states:
  still running ("Run-ID" present, "Run complete" absent), finished
  cleanly ("Run complete" present), or genuinely failed (neither).
  No more false-positive "may not be running" on successful runs.

### Other fixes

- **`lib/host-detect.sh`** — removed `'Icon\r'` from the macOS exclude
  set. The launcher passes excludes as literal substrings to an awk
  `index()` match, which can't represent a carriage-return byte
  cleanly through the read-loop pipeline. Custom-folder Icon files
  are rare enough that hashing them is harmless; better to leave
  them in the catalog than emit a pattern that just adds noise to
  every run.

### Notes

This release was driven by macOS testing on macOS 26.4.1 with
`/bin/bash` 3.2.57. The preflight + fail-loudly changes apply
equally to Synology and Linux: any time `paths.txt` lists roots
that aren't currently mounted, the user will now get an immediate,
actionable error rather than a phantom successful run.

---
## Future Roadmap  
- Lifetime GB‑saved metrics  
- Dedup analytics export  
- Parallel hashing engine  
- JSON structured output  
- Optional metadata extraction

---
