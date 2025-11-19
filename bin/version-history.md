# Version History

Contact: **jameswintermute@protonmail.ch**

This file documents the historical evolution of Hasher. It is designed to grow release-by-release.

---

## 2022-12-14 — v0.0.1  
**Initial prototype**
- Created as a single standalone shell script during SANS DFIR training.
- Basic recursive hashing, CSV output.
- No dedupe review, no cleanup tools.

---

## 2023–2024 — v0.x.x Series  
**Foundation building**
- Added multi-directory traversal  
- Introduced `paths.txt`  
- Improved CSV metadata  
- Basic duplicate grouping  

---

## 2025-03 to 2025-07 — v1.0.0  
**First structured release**
- Repository restructured (`bin/`, `logs/`, `hashes/`, `local/`, `var/`)  
- New coloured launcher  
- Background hashing with `nohup`  
- Duplicate grouping, plan, and safe deletion  
- Quarantine model introduced

---

## 2025-08 — v1.0.5 – v1.0.8  
**Expansion**
- Interactive duplicate reviewer  
- Ordering modes, progress bars, ETA  
- Folder dedupe pipeline  
- Zero-length cleaner  
- Legacy CSV converter  

---

## 2025-09 — v1.0.9  
**Hash exceptions + safer review**
- Introduced `local/exceptions-hashes.txt`  
- “A = add to exceptions” in reviewer  
- Safer numeric input loop  
- Run-ID stamping  
- Improved streaming progress  

---

## 2025-10 — v1.1.0–v1.1.2  
**Stability & performance**
- Faster hashing on BusyBox  
- System check (deps)  
- Log follower  
- Improved @eaDir cleaner  
- Initial junk support  

---

## 2025-11 — v1.1.3  
**Junk + exceptions overhaul**
- Introduced three-tier exception model  
- New junk cleaner with size column + top‑10 view  
- Menu update & launcher bug fixes  
- SHA256 hash lookup tool  
- Concurrency guard to prevent double runs  
- Cleaned `hasher.conf`  
- Added stats, hints & scheduling templates  

---

## Future Roadmap (planned)
- Enhanced stats (lifetime GB saved)  
- Cron automation helper  
- Dedup analytics  
- Parallel hashing  
- JSON output mode  
- Metadata extraction options  
