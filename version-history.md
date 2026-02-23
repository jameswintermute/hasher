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
## Future Roadmap  
- Lifetime GB‑saved metrics  
- Dedup analytics export  
- Parallel hashing engine  
- JSON structured output  
- Optional metadata extraction
