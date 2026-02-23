# NAS File Hasher & Duplicate Finder

Robust hashing + duplicate discovery + safe cleanup tooling for NAS environments (Synology DSM friendly).

> **Safety-first design:** everything is a *candidate at scan time* until re-verified immediately before action.  
> All deletion flows support **dry-run**, **confirmation**, and usually **quarantine-first**.

---

## 🚀 Quickstart (recommended)

```bash
git clone https://github.com/yourusername/hasher.git
cd hasher

chmod +x launcher.sh
chmod +x bin/*.sh

nano local/paths.txt   # add directories to scan

./launcher.sh          # menu-driven launcher
```

**Notes**
- The launcher is menu-driven; no flags on the launcher itself.  
- Direct hashing: `bin/hasher.sh --pathfile local/paths.txt`.  
- **Run duplicate-folder detection before duplicate-file detection** — folders subsume many files at once, giving faster wins with lower risk than file-level review.

---

## ℹ️ About

A project by **James Wintermute**  
Contact: **jameswintermute@protonmail.ch**

Originally started in **Dec 2022**, now a fully featured NAS dedupe & hygiene suite.

👉 For full history see: **version-history.md**

---

## 🎯 Purpose

Hasher helps protect NAS-stored data by:

- Generating cryptographic hashes (sha256 default)  
- Detecting silent corruption (bitrot, ransomware, filesystem drift)  
- Verifying backup rotation integrity  
- Finding duplicate folders (exact tree-level matches)  
- Finding duplicate files (deep review)  
- Safely applying dedupe plans with quarantine  
- Identifying zero-length files  
- Cleaning junk / system artefacts  
- Maintaining long-term NAS hygiene  

---

## 🧩 Requirements

- BusyBox / Synology DSM compatible  
- Pure POSIX `sh`  
- Uses standard tools: `awk`, `sort`, `stat`, `find`, `rm`, `mv`  
- Recommended: install under the same volume you scan (e.g., `/volume1/hasher`)  

---

# 🧭 Usage (Happy Path)

## 1) Start hashing

```bash
./launcher.sh  # Option 1
```

Outputs:
- `hashes/hasher-YYYY-MM-DD.csv`  
- `logs/background.log`  
- Zero-length candidates → `zero-length/`

---

## 2) Find duplicate folders (first pass)

```bash
bin/find-duplicate-folders.sh --input hashes/<hashfile>.csv --mode plan
```

Produces:
- `logs/duplicate-folders-plan-*.txt`

This is the **highest-value and lowest-risk** dedupe stage. Matching an entire folder tree in one pass removes far more redundancy than file-by-file review.

---

## 3) Apply duplicate-folder plan

```bash
bin/apply-folder-plan.sh --plan logs/duplicate-folders-plan-*.txt --force
```

Folders are moved to quarantine unless configured otherwise.

---

## 4) Find duplicate files

```bash
bin/find-duplicates.sh --input hashes/<hashfile>.csv
```

Generates:
- `logs/YYYY-MM-DD-duplicate-hashes.txt`

---

## 5) Review duplicate files (interactive)

```bash
bin/review-duplicates.sh --from-report logs/<report>.txt
```

Features:
- Keep-one-delete-rest  
- Sorting orders (size, sizesmall, name, mtime)  
- Exception skip list (`local/exceptions-hashes.txt`)  
- Progress bars & ETA  
- Safe numeric input  
- BusyBox compatible  

Outputs:
- `logs/review-dedupe-plan-*.txt`

---

## 6) Apply file-level dedupe plan

```bash
bin/apply-file-plan.sh --from-plan <plan> --force
```

> **Note:** `bin/delete-duplicates.sh` is an alias/wrapper for the same operation — both scripts apply a file-level dedupe plan produced in step 5. Use whichever you prefer.

Supports:
- `--quarantine <dir>`  
- Multi-pass verify  
- Dry-run before destructive action  

---

## 7) Zero-length cleanup

```bash
bin/delete-zero-length.sh --verify-only
bin/delete-zero-length.sh --force
```

---

## 8) Junk cleanup

```bash
bin/delete-junk.sh --paths-file local/paths.txt --dry-run
```

Uses:
```
local/junk-extensions.txt
```
Shows preview with sizes, totals, and top offenders.

---

## 9) SHA256 hash lookup

```bash
bin/hash-check.sh <sha256>
```

Locate all matching files across scanned volumes.

---

## 10) Stats & cron helper (Launcher option 13)

Shows:
- Hash run count  
- Latest CSV  
- Dedupe plan count  
- Cron template examples  

---

## 11) Clean internal working files

Launcher → Option 14:

Deletes everything under:
```
var/
```

…but leaves hashes + logs intact.

---

# ⚙️ Configuration

Hasher uses an override hierarchy:

```
default/hasher.conf
local/hasher.conf
local/paths.txt
local/excludes.txt
local/exceptions-hashes.txt
local/junk-extensions.txt
```

Typical fields:

```ini
EXCLUDES_FILE=local/excludes.txt
LOW_VALUE_THRESHOLD_BYTES=0
ZERO_APPLY_EXCLUDES=false
QUARANTINE_DIR="/volume1/hasher/quarantine-$(date +%F)"
```

Precedence:

```
CLI flags > local/hasher.conf > default/hasher.conf > excludes.txt > built-ins
```

---

# 📂 Directory Structure (Live Layout)

```
├── bin/
│   ├── apply-file-plan.sh
│   ├── apply-folder-plan.sh
│   ├── check-deps.sh
│   ├── clean-logs.sh
│   ├── csv-dedupe-by-path.sh
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
│   ├── lib_paths.sh
│   ├── review-batch.sh
│   ├── review-duplicates.sh
│   ├── review-junk.sh
│   ├── review-latest.sh
│   ├── run-find-duplicates.sh
│   └── schedule-hasher.sh
│
├── default/
│   └── hasher.conf
│
├── local/
│   ├── exceptions-hashes.txt
│   ├── excluded-from-dedup.txt
│   ├── excludes.txt
│   ├── hasher.conf
│   ├── junk-extensions.txt
│   └── paths.txt
│
├── logs/
│   └── .gitignore
│
├── var/
│   └── .gitignore
│
├── hashes/          # generated at runtime
├── zero-length/     # generated at runtime
│
├── launcher.sh
├── LICENSE
├── .gitignore
├── README.md
└── version-history.md
```

---

# 🛡️ Safety Model

- All destructive actions require explicit `--force`  
- All plans re-verify paths before removal  
- Quarantine-first deletion where possible  
- Extensive dry-run support  
- CRLF-safe path handling  
- BusyBox-tested execution paths  

---

# 🩺 Troubleshooting

**Sizes show as "??" in duplicate review**  
→ The system running `review-duplicates.sh` cannot stat NAS paths.  
Run reviews directly on the NAS (SSH).

**CSV appears corrupted**  
→ Fix CRLF endings:
```bash
sed -i 's/\r$//' file.csv
```

**Duplicate plan seems incomplete**  
→ Always run folder-dedupe before file-dedupe.

---

# 📜 License

GPLv3.

---

# 📚 Related Reading

Facebook — Silent Data Corruption  
https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
