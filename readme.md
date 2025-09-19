# NAS File Hasher & Duplicate Finder

Robust hashing + duplicate discovery + safe cleanup tooling for NAS environments (Synology DSM friendly).

> **Safety-first design:** everything is a *candidate at scan time* until re-verified right before action. Deletions require an explicit `--force` and most flows support quarantine.

---

## 🚀 Quickstart (recommended)

```bash
# Clone the repo
git clone https://github.com/yourusername/hasher.git
cd hasher

# Make scripts executable
chmod +x launcher.sh
chmod +x bin/*.sh

# Add the directories you want to scan (one per line)
nano local/paths.txt     # or use your editor of choice

# Launch (runs hasher in nohup mode using local/paths.txt + sha256)
./launcher.sh
```

**Notes**
- The launcher is menu-driven (no CLI flags on the launcher itself).  
  To run the hasher directly with flags, use `bin/hasher.sh` (see below).
- In the launcher’s **Stage 2**, you’ll see **“Find duplicate folders”** above **“Find duplicate files.”** Run the folder pass first for the biggest, fastest wins.

---

## About

A project by James Wintermute ([jameswintermute@protonmail.ch](mailto:jameswintermute@protonmail.ch)).  
Originally started in December 2022.  
Overhauled in Summer 2025 with assistance from ChatGPT.

---

## Purpose

This project helps protect NAS-stored data by:

* Generating cryptographic hashes of files in user directories.
* Providing a baseline for monitoring changes during disk rotation.
* Detecting mass corruption or file destruction (e.g., ransomware).
* Supporting ingestion into SIEM tools (e.g., Splunk) for monitoring and alerting.
* Identifying and managing duplicate files via hash comparison.
* **Finding entire duplicate folders/trees** for bulk space recovery.
* Detecting and cleaning up zero-length and other “low-value” files.

---

## Install & Requirements

* Works with **BusyBox/Synology DSM** and standard Linux userlands.
* Uses common POSIX tooling: `sh`, `awk`, `sort`, `uniq`, `stat`, `mv`, `rm`.  
  (No `pv` or `less` required.)
* Ensure the repo directory (e.g., `hasher/`) lives on the NAS volume where you’re scanning.
* For long runs on DSM, prefer background mode to survive SSH disconnects (the launcher does this).

---

## Usage Overview (Happy Path)

### 1) Start hashing (easiest: the launcher)

```bash
./launcher.sh                          # nohup; uses local/paths.txt + sha256
```

**Manual alternative (if you don’t want the launcher):**
```bash
bin/hasher.sh --pathfile local/paths.txt --algo sha256 --nohup
# Foreground: omit --nohup
```

**Outputs:**
* `hashes/hasher-YYYY-MM-DD.csv` – main digest table
* `logs/background.log` – progress + end-of-run summary
* `zero-length/zero-length-YYYY-MM-DD.txt` – **candidates detected at scan time**

> ⚠️ **Important:** “candidates detected at scan time” ≠ “safe to delete now”. Always verify right before acting.

---

### 2) **Find duplicate folders (run this first)**

Bulk wins by removing entire redundant directory trees (e.g., stale backups, duplicate ingest dumps).

```bash
# From the launcher: option 2
# Or via CLI (defaults to the latest CSV if not provided):
bin/find-duplicate-folders.sh --input "hashes/hasher-YYYY-MM-DD.csv" --mode plan
```

**Outputs:**
* `logs/duplicate-folders-plan-YYYY-MM-DD-<RUN_ID>.txt` – **plan** of directories to remove/quarantine (one path per line)
* Console estimates, including **Estimated plan size (recursive, on-disk)**

> **How it works (high level):** builds a stable “fingerprint” of each folder based on **relative paths + file sizes + file hashes** inside it. Two folders are considered duplicates only when the fingerprints match **exactly**. (Permissions/timestamps don’t matter; symlinks are ignored.)

---

### 3) Apply the PLAN (duplicate folders)

```bash
# From the launcher: option 6 ("Delete duplicates (apply plan)") will prefer the most recent folder plan if present

# Or via CLI:
bin/apply-folder-plan.sh --plan "$(ls -1t logs/duplicate-folders-plan-*.txt | head -n1)" --force
# Quarantine instead of delete (recommended):
bin/apply-folder-plan.sh --plan "$(ls -1t logs/duplicate-folders-plan-*.txt | head -n1)" --force \
  --quarantine "$(awk -F= '/^QUARANTINE_DIR=/{gsub(/"|'\''/,"",$2); print $2}' local/hasher.conf 2>/dev/null || true)"
```

Quarantine defaults to the `QUARANTINE_DIR` configured in `hasher.conf`. The launcher prints the target and free space before acting.

---

### 4) Find duplicate files (remaining set)

```bash
# From the launcher: option 3
# Or via CLI:
bin/find-duplicates.sh --input "hashes/hasher-YYYY-MM-DD.csv"
```

**Outputs:**
* `logs/YYYY-MM-DD-duplicate-hashes.txt` – report for review (file-level groups)

---

### 5) Review duplicate files and build a PLAN (no deletions here)

```bash
# Interactive (default), prefer keeping the newest copy:
bin/review-duplicates.sh --from-report "logs/2025-08-30-duplicate-hashes.txt" --keep newest --limit 100

# Or non-interactive (auto policy across all groups):
bin/review-duplicates.sh --from-report "logs/2025-08-30-duplicate-hashes.txt" --keep newest --non-interactive
```

**What it does:**
* Optionally diverts tiny groups (≤ `LOW_VALUE_THRESHOLD_BYTES`) out of the UI to 
  `var/low-value/low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt` (feature optional; set threshold in `hasher.conf`).
* Builds a deletion plan for real space reclaim:
  `logs/review-dedupe-plan-YYYY-MM-DD-<RUN_ID>.txt` (each line is a file path to delete).

---

### 6) Act on the PLAN (duplicate files)

```bash
# Dry-run (recommended)
bin/delete-duplicates.sh --from-plan "$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)"

# Execute (delete)
bin/delete-duplicates.sh --from-plan "$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)" --force

# Execute to quarantine instead of delete
bin/delete-duplicates.sh --from-plan "$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)" --force \
  --quarantine "$(awk -F= '/^QUARANTINE_DIR=/{gsub(/"|'\''/,"",$2); print $2}' local/hasher.conf 2>/dev/null || true)"
```

---

### 7) Clean up zero-length files (verify → dry-run → execute)

```bash
# Verify current state and write a verified plan (no actions taken)
bin/delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt" --verify-only

# Dry-run (uses the verified plan)
bin/delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt"

# Execute (delete)
bin/delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt" --force

# Execute to quarantine
bin/delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt" --force \
  --quarantine "$(awk -F= '/^QUARANTINE_DIR=/{gsub(/"|'\''/,"",$2); print $2}' local/hasher.conf 2>/dev/null || true)"
```

**Extras:**
* `--apply-excludes` respects excludes from `hasher.conf`.
* `--list-excludes` shows active rules.  
* Readers are CRLF-safe; if 100% of entries appear missing, you’ll get a helpful hint.

---

### 8) Delete junk (Thumbs.db, .DS_Store, @eaDir, etc.)

```bash
# From the launcher: option 11
# Or via CLI (verify-only by default):
bin/delete-junk.sh --paths-file local/paths.txt --verify-only

# Quarantine junk instead of deleting:
bin/delete-junk.sh --paths-file local/paths.txt --quarantine "quarantine-$(date +%F)"

# Include '#recycle' contents (never the folder itself):
bin/delete-junk.sh --paths-file local/paths.txt --include-recycle --force
```

This tool is **safe for Synology**: it never removes `#recycle` **folders**, only their **contents** if you explicitly opt in.

---

## Why run **duplicate folders** before file review?

Running the folder pass first is both **safer and faster**:

* **Biggest space wins, minimal decisions.** One choice removes a whole duplicate tree (including sidecars like `.xmp`, `.srt`, `.json`) in one go.
* **Massive noise reduction.** Removing duplicate trees collapses thousands of file-level duplicate groups you’d otherwise have to review manually.
* **Consistency with sidecars.** Tree-level removal guarantees you don’t orphan sidecar files or leave empty directory skeletons.
* **Faster review UI.** With redundant trees gone, the file-level review becomes smaller, quicker, and less error-prone.
* **Lower risk.** The folder detector only marks **exact, content-identical** trees; it won’t collapse folders that merely “overlap.”
* **Quarantine-friendly.** Moving an entire tree into quarantine is simpler and more reversible than acting on thousands of individual files.

> Think of it as **bulk de-dup** first (folders), then **surgical tidy-up** (files).

---

## Configuration (`hasher.conf`)

We follow a Splunk-style **default/local overlay**:

```
default/hasher.conf   # shipped defaults
local/hasher.conf     # (optional) site overrides
local/paths.txt       # directories to scan (one per line)
local/excludes.txt    # one glob per line, case-insensitive
```

Minimal keys the cleanup/review helpers read:

```ini
# Low-value threshold (bytes). 0 = only zero-byte files.
LOW_VALUE_THRESHOLD_BYTES=0

# Apply excludes by default during zero-length cleanup
ZERO_APPLY_EXCLUDES=false

# Exclude patterns
EXCLUDES_FILE=local/excludes.txt
#EXCLUDE_GLOBS=*.tmp,*.part,*.bak,*/Cache/*,*/.Trash*/**
#EXCLUDE_BASENAMES=Thumbs.db,.DS_Store,Desktop.ini
#EXCLUDE_DIRS=#recycle,@eaDir,.snapshot,.AppleDouble

# Safe-by-default quarantine target
QUARANTINE_DIR="/volume1/hasher/quarantine-$(date +%F)"
```

> **Precedence:** CLI flags > `local/hasher.conf` > `default/hasher.conf` > `local/excludes.txt` > built-ins.

---

## Recommended Directory Structure

```
├── bin/
│   ├── hasher.sh
│   ├── find-duplicate-folders.sh
│   ├── apply-folder-plan.sh
│   ├── find-duplicates.sh
│   ├── review-duplicates.sh
│   ├── delete-duplicates.sh
│   ├── delete-zero-length.sh
│   ├── delete-junk.sh
│   └── lib_paths.sh
├── default/
│   └── hasher.conf
├── local/
│   ├── hasher.conf          # optional overrides
│   ├── paths.txt
│   └── excludes.txt
├── hashes/
│   └── hasher-YYYY-MM-DD.csv
├── logs/
│   ├── background.log
│   ├── duplicate-folders-plan-YYYY-MM-DD-<RUN_ID>.txt
│   ├── YYYY-MM-DD-duplicate-hashes.txt
│   └── review-dedupe-plan-YYYY-MM-DD-<RUN_ID>.txt
├── zero-length/
│   └── zero-length-YYYY-MM-DD.txt
├── quarantine-YYYY-MM-DD/   # default quarantine root (per hasher.conf)
├── launcher.sh
└── LICENSE
```

---

## Safety model & wording

* **“Detected at scan time”**: counts are snapshots. Verify again before acting.
* Scripts default to **verify** or **dry-run** modes.
* **`--force`** is required for destructive actions.
* **Quarantine** mode moves files/folders instead of deleting, making it easy to roll back.

---

## Troubleshooting

**All entries show as “missing” during verify**  
Likely **CRLF** endings in your list file. Fix with:
```bash
sed -i 's/\r$//' <listfile>
```
Readers trim CRLF automatically, but cleaning the file is good hygiene.

**Zero-byte groups appear in duplicate review UI**  
Ensure `LOW_VALUE_THRESHOLD_BYTES` is set to your preference in `hasher.conf` (default `0` filters only zero-byte).

**Slow indexing with massive reports**  
Run **duplicate folders** first to shrink the search space, then reduce `--limit` during file review or use `--non-interactive` with a keep policy (e.g., `--keep newest`).

---

## License

GNU GPLv3 (see `LICENSE`).

---

## Related Reading

* Facebook Silent Data Corruption:  
  https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
