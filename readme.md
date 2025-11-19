# NAS File Hasher & Duplicate Finder

Robust hashing + duplicate discovery + safe cleanup tooling for NAS environments (Synology DSM friendly).

> **Safety-first design:** everything is a *candidate at scan time* until re-verified immediately before action.  
> All deletion flows support **dry-run**, **confirmation**, and usually **quarantine-first**.

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
- The launcher is menu-driven; no flags on the launcher itself.  
- To run hashing directly: `bin/hasher.sh --pathfile local/paths.txt`.  
- **Run duplicate-folder detection before duplicate-file detection** for fastest wins.

## ℹ️ About

A project by **James Wintermute**  
Contact: **jameswintermute@protonmail.ch**

Originally started in **Dec 2022** as a forensics exercise, now a fully-featured NAS dedupe and integrity toolkit.

👉 **Full changelog:** See **version-history.md**.

## 🎯 Purpose

Hasher helps protect NAS-stored data by:

- Generating cryptographic hashes (sha256 default)
- Detecting silent corruption (bitrot, ransomware, filesystem faults)
- Supporting backup rotation validation and integrity checks
- Finding duplicate folders and files
- Providing interactive dedupe review and safe, reversible deletion
- Identifying zero-length and low-value files
- Cleaning junk/OS artefacts
- Maintaining long-term NAS hygiene

## 🧩 Requirements

- BusyBox / Synology DSM compatible
- Pure POSIX sh
- Uses only standard tools
- Recommended: install under same volume you are hashing

# 🧭 Usage (Happy Path Overview)

(…content omitted for brevity in this snippet…)

# ⚙️ Configuration

(…content as earlier…)

# 📂 Directory Structure

(…content as earlier…)

# 🛡️ Safety Model

(…content as earlier…)

# 🩺 Troubleshooting

(…content as earlier…)

# 📜 License

GPLv3.

# 📚 Related Reading

Facebook — Silent Data Corruption  
https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/
