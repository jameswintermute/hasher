# NAS File Hasher & Duplicate Finder

Robust hashing + duplicate discovery + safe cleanup tooling for NAS environments (Synology DSM friendly).

> **Safety-first design:** everything is a *candidate at scan time* until re‑verified right before action. Deletions require an explicit `--force` and most flows support quarantine.

---

## Quickstart

```bash
# Clone the repo
git clone https://github.com/yourusername/hasher.git
cd hasher

# Make scripts executable
chmod +x hasher.sh find-duplicates.sh review-duplicates.sh delete-duplicates.sh            delete-zero-length.sh delete-low-value.sh

# Create config (edit as needed)
cp hasher.conf hasher.conf.backup 2>/dev/null || true
# or create from scratch; see the "Configuration" section below

# Run hasher (foreground example)
./hasher.sh --pathfile paths.txt --algo sha256

# Run duplicate discovery (summary only)
./find-duplicates.sh
```

---

## About

A project by James Wintermute ([jameswinter@protonmail.ch](mailto:jameswinter@protonmail.ch)).  
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
* Detecting and cleaning up zero-length and other “low-value” files.

---

## Install & Requirements

* Works with **BusyBox/Synology DSM** and standard Linux userlands.
* Uses common POSIX tooling: `bash`, `awk`, `sort`, `uniq`, `stat`, `mv`, `rm`.
* No `pv` or `less` required.
* Ensure the repo directory (e.g., `hasher/`) lives on the NAS volume where you’re scanning.
* For long runs on DSM, prefer `--nohup` to survive SSH disconnects.

---

## Usage Overview (Happy Path)

### 1) Hash the files

```bash
# Background (recommended on Synology DSM)
./hasher.sh --pathfile paths.txt --algo sha256 --nohup
# Foreground
./hasher.sh --pathfile paths.txt --algo sha256
```

**Outputs:**
* `hashes/hasher-YYYY-MM-DD.csv` – main digest table
* `logs/background.log` – progress + end-of-run summary
* `zero-length/zero-length-YYYY-MM-DD.txt` – **candidates detected at scan time**

> ⚠️ **Important:** “candidates detected at scan time” ≠ “safe to delete now”. Always verify right before acting.

---

### 2) Find duplicate groups

```bash
./find-duplicates.sh
```
**Outputs:**
* `logs/YYYY-MM-DD-duplicate-hashes.txt` – report for review

---

### 3) Review duplicates and build a PLAN (no deletions here)

```bash
# Interactive (default), prefer keeping the newest copy:
./review-duplicates.sh --from-report "logs/2025-08-30-duplicate-hashes.txt" --keep newest --limit 100

# Or non-interactive (auto policy across all groups):
./review-duplicates.sh --from-report "logs/2025-08-30-duplicate-hashes.txt"   --keep newest --non-interactive
```

**What it does now:**
* **Prefilters “low-value” groups** out of the UI per `LOW_VALUE_THRESHOLD_BYTES` in `hasher.conf`
  (default `0`, i.e. only zero‑byte files). Those are written to:
  `low-value/low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt`.
* Builds a deletion plan for real space reclaim:
  `logs/review-dedupe-plan-YYYY-MM-DD-<RUN_ID>.txt` (each line is a path to delete).

---

### 4) Act on the PLAN (duplicates)

```bash
# Dry-run (recommended)
./delete-duplicates.sh --from-plan "$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)"

# Execute (delete)
./delete-duplicates.sh --from-plan "$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)" --force

# Execute to quarantine instead of delete
./delete-duplicates.sh --from-plan "$(ls -1t logs/review-dedupe-plan-*.txt | head -n1)"   --force --quarantine "quarantine-$(date +%F)"
```

---

### 5) Clean up zero-length files (verify → dry-run → execute)

```bash
# Verify current state and write a verified plan (no actions taken)
./delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt" --verify-only

# Dry-run (uses the verified plan)
./delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt"

# Execute (delete)
./delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt" --force

# Execute to quarantine
./delete-zero-length.sh "zero-length/zero-length-YYYY-MM-DD.txt" --force   --quarantine "zero-length/quarantine-$(date +%F)"
```

**Extras:**
* `--apply-excludes` respects excludes from `hasher.conf` (or use `ZERO_APPLY_EXCLUDES=true` to make it default).
* `--list-excludes` shows active rules.  
* CRLF-safe list reading; if 100% of entries appear missing, you’ll get a helpful hint.

---

### 6) Handle “low-value” candidates (tiny files)

`review-duplicates.sh` diverts tiny groups (≤ `LOW_VALUE_THRESHOLD_BYTES`) to a side list:

```bash
# Inspect active excludes
./delete-low-value.sh --from-list "low-value/low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt" --list-excludes

# Verify-only
./delete-low-value.sh --from-list "low-value/low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt" --verify-only

# Execute (delete)
./delete-low-value.sh --from-list "low-value/low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt" --force

# Execute to quarantine
./delete-low-value.sh --from-list "low-value/low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt"   --force --quarantine "low-value/quarantine-$(date +%F)"
```

**Threshold & Exclusions**
* Threshold default is `0` (zero‑byte). Change via `hasher.conf` → `LOW_VALUE_THRESHOLD_BYTES` or CLI `--threshold-bytes`.
* Built-in excludes (case-insensitive): `Thumbs.db`, `.DS_Store`, `Desktop.ini`, and folders `#recycle`, `@eaDir`, `.snapshot`, `.AppleDouble`.
* Add your own via `EXCLUDES_FILE` or `EXCLUDE_*` keys in `hasher.conf`, or CLI flags.

---

## Configuration (`hasher.conf`)

Simple `key=value` file (no code is executed). A ready-to-use `hasher.conf` is included.

```ini
# Low-value threshold (bytes). 0 = only zero-byte files.
LOW_VALUE_THRESHOLD_BYTES=0

# If true, zero-length deletion will apply excludes below by default.
#ZERO_APPLY_EXCLUDES=false

# Exclude patterns
#EXCLUDES_FILE=excludes.txt
#EXCLUDE_GLOBS=*.tmp,*/.cache/*,*/node_modules/*
#EXCLUDE_BASENAMES=Thumbs.db,.DS_Store,Desktop.ini
#EXCLUDE_DIRS=#recycle,@eaDir,.snapshot,.AppleDouble
```

> **Precedence:** CLI flags > `hasher.conf` > auto-discovered exclude files > built-ins.

---

## Recommended Directory Structure

```
├── hashes/
│   └── hasher-YYYY-MM-DD.csv
├── logs/
│   ├── background.log
│   ├── YYYY-MM-DD-duplicate-hashes.txt
│   ├── review-dedupe-plan-YYYY-MM-DD-<RUN_ID>.txt
│   └── dups-index/… (ephemeral indexes may live here)
├── zero-length/
│   ├── zero-length-YYYY-MM-DD.txt
│   ├── verified-zero-length-YYYY-MM-DD-<RUN_ID>.txt
│   └── quarantine-YYYY-MM-DD/  (if used)
├── low-value/
│   ├── low-value-candidates-YYYY-MM-DD-<RUN_ID>.txt
│   ├── verified-low-value-YYYY-MM-DD-<RUN_ID>.txt
│   └── quarantine-YYYY-MM-DD/  (if used)
├── hasher.sh
├── find-duplicates.sh
├── review-duplicates.sh
├── delete-duplicates.sh
├── delete-zero-length.sh
├── delete-low-value.sh
└── hasher.conf
```

---

## Safety model & wording

* **“Detected at scan time”**: counts are snapshots. Verify again before acting.
* Scripts default to **verify** or **dry-run** modes.
* **`--force`** is required for destructive actions.
* **Quarantine** mode moves files instead of deleting, making it easy to roll back.

---

## Troubleshooting

**All entries show as “missing” during verify**
* Likely **CRLF** endings in your list file. Fix with:
  ```bash
  sed -i 's/\r$//' <listfile>
  ```
  All list readers trim `\r` automatically, but cleaning the file is good hygiene.

**Zero-byte groups appear in duplicate review UI**
* This is now **expected to be filtered out** per `LOW_VALUE_THRESHOLD_BYTES`. Ensure your `hasher.conf` is present (default `0` filters only zero‑byte).

**Slow indexing with massive reports**
* Reduce `--limit` during review or use `--non-interactive` with a keep policy (e.g., `--keep newest`).

---

## Best Practice on Synology

* Prefer `--nohup` on long runs to survive SSH disconnects.
* Set the repo on the same volume you’re scanning to minimise cross-volume I/O.
* Keep `logs/` under version control ignore (`.gitignore`) if noisy.

---

## License

GNU GPLv3 (see `LICENSE`).

---

## Related Reading

* Facebook Silent Data Corruption:  
  https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
