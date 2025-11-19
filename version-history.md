# Version History

Contact: **jameswintermute@protonmail.ch**

---

## 2022‑12‑14 — v0.0.1  
Initial prototype  
- Created as a SANS DFIR exercise  
- Single-script SHA‑1 hashing  
- Basic CSV output  
- No dedupe logic  

---

## 2023–2024 — v0.x.x Series  
Foundation era  
- Multi-root hashing introduced  
- `paths.txt` added  
- Improved CSV structure  
- Early duplicate grouping  
- **Legacy note:** hashing was SHA‑1; later converted to SHA256-compatible format  

---

## 2025‑03 → 2025‑07 — v1.0.0  
First structured release  
- Full repo reorganisation (`bin/`, `logs/`, `local/`)  
- New launcher  
- Background hashing (nohup-safe)  
- File/folder dedupe model  
- Quarantine workflow  

---

## 2025‑08 — v1.0.5 – v1.0.8  
Feature expansion  
- Interactive duplicate reviewer  
- Order modes, ETA, progress bars  
- Zero-length scanner  
- Folder dedupe pipeline  
- Legacy CSV converter  

---

## 2025‑09 — v1.0.9  
Safety + exceptions  
- Hash exceptions list (`local/exceptions-hashes.txt`)  
- “A = add to exceptions” in review  
- Safer numeric input loop  
- Run-ID stamping  

---

## 2025‑10 — v1.1.0 – v1.1.2  
Performance & stability  
- Faster hashing on BusyBox  
- System check module  
- Log follower  
- Improved @eaDir cleaner  
- Initial junk cleaner  

---

## 2025‑11 — v1.1.3  
Junk + exception overhaul  
- `excluded-from-dedup.txt` model  
- Junk cleaner with size columns  
- Menu consolidation  
- SHA256 lookup tool  
- Concurrency guard for hash runs  
- Config cleanup  
- Stats & cron templates  

---

## 2025‑11 — v1.1.4  
**Milestone release — production-proven**  
- Full pipeline validated on real NAS  
- Successfully deduped **19,000+ files** safely  
- Review‑duplicates hardened with size fallback + “??” handling  
- Better warnings for unreachable paths  
- Large-scale junk cleanups validated  
- README and documentation rewritten for GitHub  
- Project now considered *stable & production ready*

---

## Future Roadmap  
- Lifetime GB‑saved metrics  
- Dedup analytics export  
- Parallel hashing engine  
- JSON structured output  
- Optional metadata extraction  
