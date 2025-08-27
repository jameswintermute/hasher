# NAS File Hasher & Duplicate Finder

## Quickstart

```bash
# Clone the repo
git clone https://github.com/yourusername/hasher.git
cd hasher

# Make scripts executable
chmod +x hasher.sh find-duplicates.sh zero-length-delete.sh

# Run hasher (foreground example)
./hasher.sh --pathfile paths.txt --algo sha256

# Run duplicate finder
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
* Detecting and cleaning up zero-length files.

---

## Setup

1. Download or clone this repository.
2. On your NAS, create a working directory (e.g., `hasher/`).
3. Copy project files into this directory, ensuring correct permissions.
4. Run the hashing script (`hasher.sh`) to start generating hashes.

---

## Usage

### Stage 1 – Hashing

Run the hasher with your chosen options:

```bash
# Run in background
./hasher.sh --pathfile paths.txt --algo sha256 --background

# Run in foreground
./hasher.sh --pathfile paths.txt --algo sha256
```

This generates a dated CSV file under `hashes/` and logs zero-length files separately as `hashes/zero-length-files-YYYY-MM-DD.csv`.

---

### Stage 2 – Duplicate Detection

Run the duplicate finder:

```bash
./find-duplicates.sh
```

* The script will prompt you to select a recent hash CSV file.
* It outputs a summary report of duplicate hashes to `duplicate-hashes/`.
* The interactive review allows safe deletion of duplicates, skipping zero-length files automatically.

---

### Stage 3 – Zero-Length File Cleanup

Zero-length files can accumulate on large NAS drives. Use the `zero-length-delete.sh` script to safely verify and optionally delete these files:

```bash
# Verify zero-length files first
./zero-length-delete.sh verify

# Delete verified zero-length files in batches (e.g., 15 at a time)
./zero-length-delete.sh delete
```

* The verify mode rechecks the file system to ensure files are still zero-length.
* Delete mode presents files in small batches for user confirmation.
* Skipped files (non-zero-length) are logged, giving confidence in safe cleanup.
* At the end, a summary count of deleted files is displayed.

---

## Directory Structure

Example layout after a few runs:

```
├── background.log
├── hashes/
│   ├── hasher-2025-07-29.csv
│   ├── hasher-2025-08-05.csv
│   └── hasher-YYYY-MM-DD.csv
│   └── zero-length-files-YYYY-MM-DD.csv
├── duplicate-hashes/
│   ├── 2025-07-29-duplicate-hashes.txt
│   └── 2025-08-05-duplicate-hashes.txt
└── zero-length-delete.sh
```

---

## Notes

* Exclusions are configurable in `exclusions.txt` (e.g., `.git`, `node_modules`, system files).
* Hash algorithm is selectable (`sha256` recommended).
* Scripts are POSIX-compliant and tested on Linux (Synology DSM & Ubuntu).
* Multi-core hashing is supported for faster processing on supported systems.
* Background mode logging is included to monitor progress asynchronously.

---

## Related Reading

* Facebook Silent Data Corruption:
  \[[https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/\](](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/]%28)[https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruptio](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruptio)
