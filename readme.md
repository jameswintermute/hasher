# NAS File Hasher & Duplicate Finder

Robust hashing + duplicate discovery + safe cleanup tooling for NAS environments (Synology DSM friendly).

> **Safety‑first design:** everything is a *candidate at scan time* until re‑verified right before action.  
> Deletions require an explicit `--force`; most flows support quarantine.

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
nano local/paths.txt

# Launch (menu-driven)
./launcher.sh
```

**Notes**
- The launcher is menu‑driven; no flags on the launcher itself.
- To run hashing directly, use: `bin/hasher.sh --pathfile local/paths.txt`.
- **Stage 2** of the launcher: run **duplicate folders** before **duplicate files** for fastest wins.

---

## ℹ️ About

A project by **James Wintermute**.  
Originally started **Dec 2022**, significantly upgraded in **2025**.

---

## 🎯 Purpose

Hasher helps protect NAS‑stored data by:

- Generating cryptographic hashes (sha256 default)
- Detecting silent corruption or damage (e.g., ransomware, bitrot)
- Supporting backup rotation validation
- Feeding SIEM or monitoring systems
- Finding **duplicate folders** (exact tree‑level duplicates)
- Finding **duplicate files**
- Identifying zero‑length and “low‑value” files
- Performing safe cleanup (dry‑run first, force required)

---

## 🧩 Requirements

- BusyBox / Synology DSM compatible (pure POSIX `sh`)
- Uses common tools: `awk`, `sort`, `stat`, `find`, `rm`, `mv`
- Place the repo on the same volume you are hashing

---

# 🧭 Usage (Happy Path)

## 1) Start hashing

```bash
./launcher.sh
```

In the launcher: **Option 1** starts hashing in safe background mode.

Outputs:

- `hashes/hasher-YYYY-MM-DD.csv`  
- `logs/background.log`  
- Zero‑length candidates under `zero-length/`

---

## 2) Find duplicate folders (**run this first**)

```bash
# Launcher option 2
bin/find-duplicate-folders.sh --input hashes/hasher-YYYY-MM-DD.csv --mode plan
```

Produces:

- `logs/duplicate-folders-plan-*.txt` — recommended for big, immediate space recovery

**Why folders first?**
- Huge wins
- Removes redundant whole trees
- Cleans up sidecars
- Shrinks file-level duplicate review dramatically
- Lower risk and simpler rollback

---

## 3) Apply duplicate‑folder plan

```bash
# Launcher option 6
bin/apply-folder-plan.sh --plan <planfile> --force
```

or:

```bash
bin/apply-folder-plan.sh --plan <planfile> --force --quarantine <dir>
```

---

## 4) Find duplicate files

```bash
# Launcher option 3
bin/find-duplicates.sh --input hashes/hasher-YYYY-MM-DD.csv
```

Outputs:

- `logs/YYYY-MM-DD-duplicate-hashes.txt`

---

## 5) Review duplicate files & build deletion plan

```bash
# Launcher option 4 (interactive)
bin/review-duplicates.sh --from-report logs/<report>.txt
```

Produces:

- `logs/review-dedupe-plan-*.txt`  
- Optionally diverts low-value groups into `var/low-value/`

New in v1.0.9:
- **A = add hash to exceptions list** (`local/exceptions-hashes.txt`)
- Safer numeric handling
- Backwards‑compatible CLI argument detection

---

## 6) Apply file‑level plan

```bash
# Launcher option 6 (auto‑detects latest file plan)
bin/delete-duplicates.sh --from-plan <plan> --force
```

Supports:
- `--quarantine <dir>`
- `--apply-excludes`
- Multi-pass verify → dry-run → force

---

## 7) Zero‑length file cleanup

```bash
bin/delete-zero-length.sh <listfile> --verify-only
bin/delete-zero-length.sh <listfile>
bin/delete-zero-length.sh <listfile> --force
```

Respects:
- exclude rules
- CRLF‑safe
- quarantine supported

---

## 8) Delete junk

```bash
# Launcher option 11
bin/delete-junk.sh --paths-file local/paths.txt --verify-only
```

Can optionally include or quarantine recycle contents.

---

## 9) Hash lookup (NEW)

```bash
# Launcher option 12
bin/hash-check.sh <sha256>
```

For locating exactly‑matching files by digest.

---

## 10) Stats & cron helper (NEW)

```bash
# Launcher option 13
```

Shows:

- How many hash runs
- Latest hash CSV
- Count of duplicate plans
- Latest plan file
- Cron templates for nightly hashing and weekly junk cleaning

---

## 11) Clean internal working files (NEW)

```bash
# Launcher option 14
```

Safely wipes everything inside:

```
var/
```

…but **keeps hashes + logs** intact.  
Useful after several cycles to reduce noise.  
Safe to run during active hashing (does not affect hashing output).

---

# ⚙️ Configuration

We use a **default/local** overlay model:

```
default/hasher.conf
local/hasher.conf
local/paths.txt
local/excludes.txt
local/exceptions-hashes.txt   # new in 1.0.9
```

Key fields:

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

# 📂 Structure

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
│   ├── paths.txt
│   ├── excludes.txt
│   └── exceptions-hashes.txt
├── hashes/
├── logs/
├── var/
├── zero-length/
├── quarantine-YYYY-MM-DD/
└── launcher.sh
```

---

# 🛡️ Safety Model

- Everything is **verified again** before deletion
- Most scripts run **dry‑run** by default
- All destructive steps require `--force`
- Quarantine-first recommended
- Robust CRLF handling
- Backwards‑compatible argument parsing

---

# 🩺 Troubleshooting

**Verify shows all files missing**  
→ Input list is CRLF. Fix with:
```bash
sed -i 's/
$//' <file>
```

**Slow file review UI**  
→ Run duplicate‑folders first.

**Plans not applying**  
→ Ensure plan points to existing paths; re‑run review after folder cleanup.

---

# 📜 License

GPLv3.

---

# 📚 Related Reading

Facebook – Silent Data Corruption  
https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
