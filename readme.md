# Hasher — NAS File Hasher & Duplicate Finder

Robust hashing, duplicate discovery, and safe cleanup tooling for NAS environments.  
Synology DSM / BusyBox compatible. Pure shell — no dependencies beyond standard tools.

> **Safety-first design:** all deletion flows use quarantine-first, dry-run support,
> and explicit confirmation. Nothing is deleted without a plan file you can review first.

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
Started Dec 2022. Current version: **v1.1.8**  
For full history see: `version-history.md`

---

## Purpose

Hasher helps protect and maintain NAS-stored data by:

- Generating SHA-256 hashes of all files
- Detecting duplicate folders (entire tree-level matches)
- Detecting duplicate files (hash-level matches)
- Applying dedupe plans safely via quarantine
- Non-interactive auto-dedup for large-scale cleanup
- Identifying and removing zero-length files
- Cleaning junk and OS artefacts (Thumbs.db, .DS_Store, etc.)
- Maintaining long-term NAS hygiene

---

## Requirements

- Synology DSM or any BusyBox Linux environment
- Standard tools: `bash`, `awk`, `sort`, `stat`, `find`, `mv`, `rm`
- Recommended install location: same volume you scan (e.g. `/volume1/hasher`)

---

## Launcher Menu

```
### Stage 1 - Hash ###
  0) Check hashing status
  1) Start Hashing (NAS-safe, background)
  8) Advanced / Custom hashing

### Stage 2 - Identify ###
  2) Find duplicate folders
  3) Find duplicate files
 12) Find file by HASH (lookup)

### Stage 3 - Clean up ###
  4) Review duplicates (interactive, per-group)
 16) Auto-dedup (keep shortest path — no prompts)
  5) Delete zero-length files
  6) Delete duplicates (apply plan)
 10) Clean cache files & @eaDir
 11) Delete junk (local/junk-extensions.txt)

### Other ###
  7) System check
  9) Follow logs
 13) Stats & scheduling hints
 14) Clean internal working files (var/)
 15) Clean logs
```

---

## Recommended Workflow

### For large volumes — use auto-dedup (option 16)

When you have hundreds or thousands of duplicate groups and don't need
per-group review, option 16 handles the entire process in one step:

1. Run **option 1** — hash all files
2. Run **option 3** — find duplicate files
3. Run **option 16** — auto-dedup (generates plan + offers to apply immediately)

Option 16 keeps the copy with the **shortest file path** in each duplicate group
and quarantines all others. You can also choose longest-path, newest, or oldest.

### For careful review — use interactive mode (option 4)

When you want to inspect each group before deciding:

1. Run **option 1** — hash all files
2. Run **option 2** — find duplicate *folders* first (highest value, lowest risk)
3. Run **option 6** → `d` — apply folder plan
4. Run **option 3** — find duplicate files
5. Run **option 4** — interactive review, group by group
6. Run **option 6** → `f` — apply file plan

> Run folder-dedupe before file-dedupe — matching an entire directory tree in
> one pass removes far more redundancy than file-by-file review.

---

## Plan Files

All dedup operations produce a plain-text plan file in `logs/` before anything
is moved. You can review it before applying:

```bash
# See what would be deleted:
cat logs/auto-dedup-plan-*.txt | grep '^DEL' | head -50

# Count deletions:
cat logs/auto-dedup-plan-*.txt | grep -c '^DEL'

# Apply via launcher option 6, or directly:
bin/delete-duplicates.sh logs/auto-dedup-plan-TIMESTAMP.txt
```

Plan file format:
```
KEEP|/volume1/James/Photos/IMG_001.jpg
DEL|/volume1/James/Backup/Photos/IMG_001.jpg
DEL|/volume1/James/Archive/Photos/IMG_001.jpg
```

Files marked `DEL` are moved to quarantine, not permanently deleted.

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
│   ├── auto-dedup.sh           — non-interactive dedup (v1.1.7+)
│   ├── apply-folder-plan.sh
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
│   ├── review-junk.sh
│   └── run-find-duplicates.sh
│
├── default/
│   └── hasher.conf
│
├── local/                      — your config (gitignored)
│   ├── exceptions-hashes.txt
│   ├── excluded-from-dedup.txt
│   ├── excludes.txt
│   ├── hasher.conf
│   ├── junk-extensions.txt
│   └── paths.txt
│
├── logs/                       — plan files and reports (gitignored)
├── hashes/                     — hash CSVs (gitignored)
├── var/                        — working files (gitignored)
├── quarantine/                 — files moved by delete-duplicates.sh
│
├── launcher.sh
├── LICENSE
├── README.md
└── version-history.md
```

---

## Safety Model

- Plans are written and reviewable before anything is moved
- `delete-duplicates.sh` moves files to quarantine — not permanent deletion
- `apply-folder-plan.sh` uses collision-proof quarantine naming (v1.1.6+)
- Exceptions list prevents re-flagging known-safe duplicates
- All scripts re-verify paths immediately before acting

---

## Troubleshooting

**Sizes show as `??` in duplicate review**  
Run `review-duplicates.sh` directly on the NAS via SSH — it cannot stat remote paths.

**CSV appears corrupted**  
Fix line endings: `sed -i 's/\r$//' hashes/*.csv`

**Auto-dedup processed 0 groups**  
Check that `logs/duplicate-hashes-latest.txt` exists. Run option 3 first.

**Option 6 can't find the auto-dedup plan**  
Upgrade to v1.1.8 — earlier versions only looked for `review-dedupe-plan-*.txt`.

---

## License

GNU GPLv3 — see LICENSE.

---

## Related

- [hasher-py](https://github.com/jameswintermute/hasher-py) — laptop-side web UI for reviewing duplicate groups interactively, built on the same CSV and plan file formats
- [Facebook — Silent Data Corruption](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/)
