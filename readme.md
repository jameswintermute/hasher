# NAS File Hasher & Duplicate Finder

Robust hashing + duplicate discovery + safe cleanup tooling for NAS environments (Synology DSM friendly).

> **Safety‑first design:** everything is a *candidate at scan time* until re‑verified right before action.  
> Deletions require explicit confirmation; nearly all destructive flows support quarantine-first.

---

## 🚀 Quickstart (recommended)

```bash
git clone https://github.com/yourusername/hasher.git
cd hasher

chmod +x launcher.sh
chmod +x bin/*.sh

nano local/paths.txt   # add directories to scan

./launcher.sh          # menu-driven experience
```

**Notes**
- The launcher itself takes no flags — all logic is driven from menus.
- To run hashing directly:  
  `bin/hasher.sh --pathfile local/paths.txt`
- **Run duplicate-folder detection before duplicate-file detection** for fastest wins.

---

## ℹ️ About

A project by **James Wintermute**  
Contact: **jameswintermute@protonmail.ch**

Originally created in **Dec 2022**, expanded extensively in 2025.

👉 Full changelog: **version-history.md**

---

## 🎯 Purpose

Hasher is designed for long-term NAS hygiene, integrity protection, and safe deduplication. It supports:

- Cryptographic hashing (sha256)
- Silent corruption detection (bitrot, ransomware, filesystem faults)
- Backup rotation verification
- Exact duplicate-folder discovery (fast, high-value savings)
- Duplicate-file grouping and review
- Safe deletion via quarantine plans (dry-run by default)
- Zero-length file detection and cleanup
- Junk/sidecar artefact cleanup
- Hash lookup and forensic utilities

---

## 🧩 Requirements

- BusyBox-compatible (Synology DSM)
- Pure POSIX `sh`
- Uses only common tools: `awk`, `sort`, `stat`, `find`, `rm`, `mv`
- Recommended: install under the same volume you are hashing (e.g., `/volume1/hasher`)

---

# 🧭 Usage (Happy Path)

## 1) Start hashing

```bash
./launcher.sh
# Option 1
```

Background hashing writes:

- `hashes/hasher-YYYY-MM-DD.csv`
- `logs/background.log`
- Zero-length candidates → `zero-length/`

---

## 2) Find duplicate folders (run this first)

```bash
bin/find-duplicate-folders.sh --input hashes/<hashfile>.csv --mode plan
```

Produces:

- `logs/duplicate-folders-plan-*.txt`

Folder-level dedupe gives the **largest and safest wins**:

- Removes redundant directory trees wholesale  
- Cleans up sidecars  
- Shrinks file-level duplicate review work  
- Highly reversible via quarantine

---

## 3) Apply duplicate-folder plan

```bash
bin/apply-folder-plan.sh --plan logs/duplicate-folders-plan-*.txt --force
```

All removed folders go to a dated quarantine directory unless otherwise configured.

---

## 4) Find duplicate files

```bash
bin/find-duplicates.sh --input hashes/<hashfile>.csv
```

Produces:

- `logs/YYYY-MM-DD-duplicate-hashes.txt`

---

## 5) Review duplicate files & build plan

Interactive review:

```bash
bin/review-duplicates.sh --from-report logs/<report>.txt
```

Produces:

- `logs/review-dedupe-plan-*.txt`

Features:

- Keep-one-delete-rest model  
- Size-aware ordering (size, sizesmall, name, mtime)  
- Safe numeric input loop  
- **A = Add hash to exceptions list** (`local/exceptions-hashes.txt`)  
- Exceptions automatically skipped in future runs  
- Progress bars with ETA  
- BusyBox-safe

---

## 6) Apply file-level plan

```bash
bin/delete-duplicates.sh --from-plan <plan> --force
```

Supports:

- `--quarantine <dir>`
- Optional `--apply-excludes`
- Multi-pass verify → dry-run → force

---

## 7) Zero-length cleanup

```bash
bin/delete-zero-length.sh --verify-only
bin/delete-zero-length.sh --force
```

Zero-length files are recorded during hashing and can be reviewed safely.

---

## 8) Junk cleanup

```bash
bin/delete-junk.sh --paths-file local/paths.txt --dry-run
```

Uses:

```
local/junk-extensions.txt
```

Supports preview mode, size summary, and progressive lists for large batches.

---

## 9) Hash lookup

```bash
bin/hash-check.sh <sha256>
```

Finds all files that match the specified digest.

---

## 10) Stats & cron helper

Launcher → Option 13

Shows:

- Number of hash runs  
- Latest CSV  
- Number of dedupe plans  
- Cron templates for nightly hashing and weekly junk cleaning  

---

## 11) Clean internal working files

Launcher → Option 14

Deletes contents of:

```
var/
```

…but leaves logs + hashes untouched. Safe to run anytime.

---

# ⚙️ Configuration

Hasher uses an overlay configuration model:

```
default/hasher.conf
local/hasher.conf              (preferred override)
local/paths.txt
local/excludes.txt
local/exceptions-hashes.txt
local/junk-extensions.txt
```

Typical fields:

```ini
LOW_VALUE_THRESHOLD_BYTES=0
ZERO_APPLY_EXCLUDES=false
EXCLUDES_FILE=local/excludes.txt
QUARANTINE_DIR="/volume1/hasher/quarantine-$(date +%F)"
```

Precedence:

```
CLI flags > local/hasher.conf > default/hasher.conf > excludes.txt > built-ins
```

---

# 📂 Directory Structure

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
│   └── hash-check.sh
├── default/
├── local/
├── hashes/
├── logs/
├── zero-length/
├── var/
└── launcher.sh
```

---

# 🛡️ Safety Model

- All destructive actions require `--force`
- Nearly all flows support **dry-run**
- All deletions re-verify paths immediately before action
- Quarantine-first deletion reduces risk
- CRLF‑safe input processing
- BusyBox‑tested code paths

---

# 🩺 Troubleshooting

**Duplicate review shows [??] for file sizes**  
→ The system running `review-duplicates.sh` cannot stat the NAS paths.  
Ensure you run review **directly on the NAS via SSH**.

**Hash CSV shows missing paths**  
→ Check CRLF endings:
```bash
sed -i 's/
$//' file.csv
```

**Plans not applying**  
→ Folder-level dedupe should be done first.

---

# 📜 License

GPLv3.

---

# 📚 Related Reading

Facebook — Silent Data Corruption  
https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
