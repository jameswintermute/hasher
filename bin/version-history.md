# Version History

Contact: **jameswintermute@protonmail.ch**

## 2022-12-14 — v0.0.1
- Initial prototype (SANS DFIR training)
- Basic recursive hashing
- CSV output only
- No dedupe or cleanup
- **Used SHA-1 hashing** in early versions (2022–2024)

## 2023–2024 — v0.x.x Series
- Foundation building
- Multi-directory traversal
- Introduced paths.txt
- Improved CSV metadata
- Basic duplicate grouping
- **Legacy note:** SHA-1 was still used. Old CSVs require conversion to SHA256 format.

## 2025-03 to 2025-07 — v1.0.0
- First structured release
- Repo reorganised
- New coloured launcher
- Background hashing
- Dedupe plan + quarantine model

## 2025-08 — v1.0.5 – v1.0.8
- Interactive duplicate reviewer
- Ordering modes, progress bars
- Folder-level dedupe
- Zero-length cleaner
- Legacy CSV converter

## 2025-09 — v1.0.9
- Hash exceptions list
- Safe numeric input loop
- Run-ID stamping
- Improved progress

## 2025-10 — v1.1.0–v1.1.2
- Faster hashing
- System check
- Log follower
- Improved @eaDir cleaner
- Initial junk support

## 2025-11 — v1.1.3
- Junk + exception overhaul
- New junk cleaner (size column + top10)
- Menu/launcher improvements
- SHA256 lookup tool
- Concurrency guard
- Cleaned config
- Stats + cron templates

## Future
- Enhanced stats (GB saved)
- Dedup analytics
- Parallel hashing
- JSON output mode
- Metadata extraction
