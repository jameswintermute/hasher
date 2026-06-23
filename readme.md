# Hasher — NAS File Hasher & Duplicate Finder

Robust hashing, duplicate discovery, and safe cleanup tooling for NAS environments.
Synology DSM / BusyBox compatible. Pure shell — no dependencies beyond standard tools.

> **Safety-first design:** all deletion flows use quarantine-first, dry-run support,
> and explicit confirmation. Nothing is deleted without a plan file you can review first.

---

## Scope

Hasher is a content-integrity tool. It catalogues files by SHA-256 hash, identifies
duplicates, removes them safely (quarantine-first), and produces a CSV that other
tools can use for downstream analysis — including silent-deletion detection.

Hasher is deliberately narrow: hashing, duplicate detection (file and folder),
safe removal, CSV output. Workflow tooling that consumes Hasher's CSV is out of
scope and belongs in separate projects. This separation keeps Hasher small enough
to audit and stable enough to depend on.

---

## Quickstart

```bash
git clone https://github.com/jameswintermute/hasher.git
cd hasher

chmod +x launcher.sh bin/*.sh

nano local/paths.txt   # add the directories you want to scan

./launcher.sh          # menu-driven launcher
```

---

## About

A project by **James Wintermute** — jameswintermute@protonmail.ch
Started Dec 2022. Current version: **v1.1.13**
For full history see: `version-history.md`

---

## Purpose

Hasher helps protect and maintain NAS-stored data by:

- Generating SHA-256 hashes of all files
- Detecting duplicate folders (entire tree-level matches)
- Detecting duplicate files (hash-level matches)
- Applying dedup plans safely via quarantine
- Non-interactive auto-dedup for large-scale cleanup
- Identifying and removing zero-length files
- Cleaning junk and OS artefacts (Thumbs.db, .DS_Store, etc.)
- Maintaining long-term NAS hygiene

---

## Requirements

- Synology DSM, macOS, or any Linux environment with bash
- Standard tools: `bash`, `awk`, `sort`, `stat`, `find`, `mv`, `rm`
- Recommended install location: same volume you scan (e.g. `/volume1/hasher`)

Cross-platform support is tested on Synology DSM, Linux, and macOS. Host-aware
defaults (excludes, quarantine paths) are auto-applied via `lib/host-detect.sh`.

---

## Launcher Menu

```
Stage 1 — Hash
   1) Start hashing (NAS-safe defaults)
   a) Advanced / custom hashing
   s) Hashing status

Stage 2 — Identify
   2) Find duplicate files
   3) Find duplicate folders
   f) Find file by hash (lookup)

Stage 3 — Review & clean
   4) Review duplicate FILES (interactive)
   r) Review duplicate FOLDERS plan (interactive)
   5) Auto-dedup (keep shortest path — no prompts)
   6) Apply dedup plan (FILE or FOLDER)
   7) Delete zero-length files
   8) Delete junk (uses local/junk-extensions.txt)
   9) Clean cache files & @eaDir (safe)

Other
   d) System diagnostics (deps & readiness)
   l) Follow logs (tail -f background.log)
   t) Stats & scheduling hints
   v) Clean internal working files (var/)
   c) Clean logs (rotate & prune)

   q) Quit
```

Number keys 1–9 drive the main workflow. Letters cover meta and infrequent
operations: `a`/`s` for hashing variants, `f` for hash lookup, `r` for folder
plan review, and `d/l/t/v/c` for diagnostics and housekeeping.

---

## Recommended Workflow

### For large volumes — use auto-dedup (option 5)

When you have hundreds or thousands of duplicate groups and don't need
per-group review, option 5 handles the whole process in one step:

1. Run **option 1** — hash all files
2. Run **option 2** — find duplicate files
3. Run **option 5** — auto-dedup (generates plan + offers to apply)

Auto-dedup keeps the copy with the **shortest file path** in each duplicate group
and quarantines the others. Configurable to longest-path, newest, or oldest.

### For careful review — folder-first, then files

Folder dedup removes far more redundancy per decision than file-by-file review.
Run it first:

1. Run **option 1** — hash all files
2. Run **option 3** — find duplicate folders
3. Run **option r** — interactively review the folder plan; accept, skip, or swap
   keepers per group; the reviewer writes a reviewed plan
4. Run **option 6** → `d` — apply the reviewed FOLDER plan
5. Run **option 2** — find duplicate files (now far fewer)
6. Run **option 4** — interactively review the file groups
7. Run **option 6** → `f` — apply the FILE plan

When you run option 3, you'll be offered the reviewer immediately. Decline if
you want to inspect the plan in a different terminal first; option `r` is always
available to come back to.

---

## Plan Files

All dedup operations produce a plain-text plan file in `logs/` before anything
is moved. Inspect, then apply.

```bash
# See what would be deleted (file dedup):
cat logs/auto-dedup-plan-*.txt | grep '^DEL' | head -50

# See the folder dedup plan:
cat logs/duplicate-folders-plan-*.txt | head -20

# After reviewing folders interactively:
cat logs/duplicate-folders-plan-reviewed-*.txt
```

**File plan format** (one decision per line, with markers):
```
KEEP|/volume1/James/Photos/IMG_001.jpg
DEL|/volume1/James/Backup/Photos/IMG_001.jpg
DEL|/volume1/James/Archive/Photos/IMG_001.jpg
```

**Folder plan format** (one path per line; all listed paths get quarantined;
the implicit keeper is the one *not* listed for each group):
```
/volume1/James/Backup/Photos
/volume1/James/Archive/Photos
```

The folder-dedup finder also writes a `duplicate-folders-groups-*.tsv` sidecar
holding the full keep/del structure with reclaim sizes, used by the reviewer.

All files marked for deletion are moved to **quarantine**, not permanently deleted.

---

## Configuration

```
default/hasher.conf         — defaults (do not edit)
local/hasher.conf           — your overrides
local/paths.txt             — scan roots, one per line
local/excludes.txt          — find exclusion patterns
local/exceptions-hashes.txt — hashes excluded from dedup
local/excluded-from-dedup.txt — path prefixes excluded from dedup
local/junk-extensions.txt   — rules for junk file cleanup
```

Precedence: `CLI flags > local/hasher.conf > default/hasher.conf`

---

## Directory Structure

```
hasher/
├── bin/
│   ├── apply-folder-plan.sh
│   ├── auto-dedup.sh
│   ├── check-deps.sh
│   ├── clean-logs.sh
│   ├── csv-quick-stats.sh
│   ├── delete-duplicates.sh
│   ├── delete-junk.sh
│   ├── delete-zero-length.sh
│   ├── du-summary.sh
│   ├── find-duplicate-folders.sh
│   ├── find-duplicates.sh
│   ├── hash-check.sh
│   ├── hasher.sh
│   ├── launch-review.sh
│   ├── review-duplicates.sh
│   ├── review-folder-plan.sh    ← v1.1.13
│   ├── review-junk.sh
│   └── run-find-duplicates.sh
│
├── lib/
│   └── host-detect.sh           ← v1.1.9
│
├── default/
│   └── hasher.conf
│
├── local/                       — your config (gitignored)
│   ├── exceptions-hashes.txt
│   ├── excluded-from-dedup.txt
│   ├── excludes.txt
│   ├── hasher.conf
│   ├── junk-extensions.txt
│   └── paths.txt
│
├── logs/                        — plan files and reports (gitignored)
├── hashes/                      — hash CSVs (gitignored)
├── var/                         — working files (gitignored)
├── quarantine/                  — files moved by delete-duplicates.sh
│
├── launcher.sh
├── LICENSE
├── readme.md
└── version-history.md
```

---

## Safety Model

- Plans are written and reviewable before anything is moved
- The folder-dedup reviewer (option `r`) lets you accept, skip, or swap keepers
  per duplicate group before applying anything
- Applying a raw (unreviewed) folder plan prompts for explicit confirmation
- `delete-duplicates.sh` moves files to quarantine — not permanent deletion
- `apply-folder-plan.sh` uses collision-proof quarantine naming (v1.1.6+)
- Exceptions list prevents re-flagging known-safe duplicates
- All scripts re-verify paths immediately before acting
- Bash 3.2 / BSD awk / macOS userland compatibility audited (v1.1.9–v1.1.12)

---

## Troubleshooting

**Sizes show as `??` in duplicate review**
Run `review-duplicates.sh` directly on the NAS via SSH — it cannot stat remote paths.

**CSV appears corrupted**
Fix line endings: `sed -i 's/\r$//' hashes/*.csv`

**"All paths missing or unreadable" error**
The paths in `local/paths.txt` don't exist on this host. Common causes: external
drive not mounted, typo in volume name, NAS share offline. Use `ls /Volumes`
(macOS), `ls /mnt` or `ls /media` (Linux), or `ls /volume1` (Synology) to check.

**Folder review says "no groups TSV found"**
Run option 3 (Find duplicate folders) first. The reviewer reads
`logs/duplicate-folders-groups-*.tsv`, which is produced by the finder.

---

## License

GNU GPLv3 — see LICENSE.

---

## Further Reading

- [Facebook — Silent Data Corruption](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/) — the motivating use case for hash-based integrity monitoring
