# NAS File Hasher & Duplicate Finder

## Quickstart

```bash
# Clone the repo
git clone https://github.com/yourusername/hasher.git
cd hasher

# Make scripts executable
chmod +x hasher.sh find-duplicates.sh review-duplicates.sh zero-length-delete.sh

# Run hasher (foreground example)
./hasher.sh --pathfile paths.txt --algo sha256

# Run duplicate finder
./find-duplicates.sh
```

---

## About

A project by James Wintermute ([jameswintermute@protonmail.ch](mailto:jameswinter@protonmail.ch)).  
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
* Detecting and cleaning up zero-length files.

---

## Setup

1. Download or clone this repository.
2. On your NAS, create a working directory (e.g., `hasher/`).
3. Copy project files into this directory, ensuring correct permissions.
4. Create or edit `hasher.conf` to customise logging, exclusions, and performance.
5. Run the hashing script (`hasher.sh`) to start generating hashes.

---

## Usage

### Stage 1 – Hashing

Run the hasher with your chosen options:

```bash
# Run in background using nohup (recommended for Synology DSM)
./hasher.sh --pathfile paths.txt --algo sha256 --config hasher.conf --nohup

# Run in foreground
./hasher.sh --pathfile paths.txt --algo sha256 --config hasher.conf
```

This generates a dated CSV file under `hashes/` and logs output under `logs/`.

---

### Stage 2 – Duplicate Detection

There are **two modes**:

#### a) Quick Duplicate Summary

```bash
./find-duplicates.sh
```

* Scans a selected hash CSV file.
* Outputs a simple summary of duplicate groups into `duplicate-hashes/`.

#### b) Interactive Review & Safe Deletion

```bash
./review-duplicates.sh --config hasher.conf
```

* Select a hash CSV file to review.
* Interactive mode shows each duplicate group and lets you choose which file (if any) to delete.
* Generates:
  * A detailed report in `duplicate-hashes/DATE-duplicate-hashes.txt`.
  * A safe `duplicate-hashes/delete-plan.sh` script (requires confirmation before deleting anything).

Zero-length files are always skipped automatically.

---

### Stage 3 – Zero-Length File Cleanup

Zero-length files can accumulate on large NAS drives. Use the `zero-length-delete.sh` script to safely verify and optionally delete these files:

```bash
# Verify zero-length files first
./zero-length-delete.sh verify

# Delete verified zero-length files in batches (e.g., 15 at a time)
./zero-length-delete.sh delete
```

* Verify mode rechecks the file system to ensure files are still zero-length.
* Delete mode presents files in small batches for user confirmation.
* Skipped files (non-zero-length) are logged, giving confidence in safe cleanup.
* At the end, a summary count of deleted files is displayed.

---

## Configuration

The main config file is `hasher.conf`. Example:

```ini
[logging]
background-interval = 15   ; heartbeat in seconds
level = info               ; debug|info|warn|error
xtrace = false              ; true to log shell trace
discovery-interval = 15     ; optional per-phase override
hashing-interval   = 15

[exclusions]
inherit-defaults = true
*.tmp
*.part
*.bak
*/Cache/*
*/.Trash*/**

[performance]
nice = 10    ; lower CPU priority
ionice = 7   ; lower disk I/O priority (if supported)
```

---

## Directory Structure

Example layout after a few runs:

```
├── logs/
│   ├── background.log
│   ├── hasher-<RUN_ID>.log
│   ├── review-duplicates-<RUN_ID>.log
│   └── review-duplicates.log -> symlink to latest run
├── hashes/
│   ├── hasher-2025-07-29.csv
│   ├── hasher-2025-08-05.csv
│   └── zero-length-files-YYYY-MM-DD.csv
├── duplicate-hashes/
│   ├── 2025-07-29-duplicate-hashes.txt
│   ├── 2025-08-05-duplicate-hashes.txt
│   └── delete-plan.sh
├── hasher.sh
├── find-duplicates.sh
├── review-duplicates.sh
├── zero-length-delete.sh
└── hasher.conf
```

---

## Notes

* Exclusions and logging are controlled by `hasher.conf`.
* Hash algorithm is selectable (`sha256` recommended).
* Scripts are POSIX-compliant and tested on Linux (Synology DSM & Ubuntu).
* Multi-core hashing is supported for faster processing.
* Background mode logging provides continuous asynchronous progress reporting.

---

## Best Practice on Synology

* Always run with `--nohup` unless you plan to stay connected via SSH.
* This prevents NAS disconnections or session drops from terminating the hashing process.
* Logs are always written under `logs/` for post-run inspection.

---

## Related Reading

* Facebook Silent Data Corruption:  
  [https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/)
