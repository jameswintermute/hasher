# NAS File Hasher & Duplicate Finder

## Quickstart

```bash
# Clone the repo
git clone https://github.com/yourusername/hasher.git
cd hasher

# Make scripts executable
chmod +x hasher.sh find-duplicates.sh

# Run hasher (foreground example)
./hasher.sh --pathfile paths.txt --algo sha256

# Run duplicate finder
./find-duplicates.sh

About

    A project by James Wintermute (jameswinter@protonmail.ch).

    Originally started in December 2022.

    Overhauled in Summer 2025 with assistance from ChatGPT.

Purpose

This project is designed to help protect NAS-stored data by:

    Generating cryptographic hashes of all files in user home directories.

    Providing a baseline for monitoring changes during disk rotation.

    Helping detect mass corruption or destruction of files (e.g., from ransomware/malware).

    Supporting ingestion into SIEM tools (e.g., Splunk) for further monitoring and alerting.

    Identifying and managing duplicate files via duplicate hash detection.

Setup

    Download or clone this repository.

    On your NAS, create a working directory (e.g. hasher/).

    Copy the project files into this directory, ensuring correct permissions and ownership.

    Run the hashing script (hasher.sh) to start generating hashes.

Usage
Stage 1 – Hashing

Run the hasher with your chosen options:

# Run in background
./hasher.sh --pathfile paths.txt --algo sha256 --background

# Run in foreground
./hasher.sh --pathfile paths.txt --algo sha256

This generates a dated CSV file under hashes/.
Stage 2 – Duplicate Detection

Run the duplicate finder:

./find-duplicates.sh

    The script will prompt you to select a recent hash CSV file.

    It outputs a summary report of duplicate hashes to duplicate-hashes/.

    (Future update: automated duplicate cleanup options).

Directory Structure

Example layout after a few runs:

├── background.log
├── hashes/
│   ├── hasher-2025-07-29.csv
│   ├── hasher-2025-08-05.csv
│   └── hasher-YYYY-MM-DD.csv
└── duplicate-hashes/
    ├── 2025-07-29-duplicate-hashes.txt
    └── 2025-08-05-duplicate-hashes.txt

Notes

    Exclusions are configurable (e.g., .git, node_modules, system files).

    Hash algorithm is selectable (sha256 recommended).

    Scripts are POSIX-compliant and tested on Linux (Synology DSM & Ubuntu).

Related Reading

    Facebook Silent Data Corruption
https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
