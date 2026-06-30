# Hasher — NAS File Hasher, Integrity Monitor & Duplicate Finder

A pure-shell tool that catalogues every file on a NAS by its SHA-256 hash, so you
can find duplicates, reclaim space safely, and — over time — prove what has changed,
vanished, or silently corrupted. Synology DSM / BusyBox compatible, with no
dependencies beyond standard Unix tools.

> **Safety-first by design.** Duplicate removal is quarantine-first: identical files
> and folders are *moved* to a recoverable quarantine, never deleted outright, driven
> by a plan file you review first, and each candidate is re-hashed immediately before
> the move so a file that changed after the plan was made is skipped. Note that the
> separate housekeeping tools — zero-length-file removal, junk-extension cleanup, and
> cache/`@eaDir` cleaning — delete by default (zero-length removal supports
> `--quarantine` if you prefer). Dedup, the core workflow, never deletes; the
> housekeeping helpers do.

---

## Why Hasher exists

Large file collections decay quietly. Photos and documents accumulated over decades
develop duplicates across backups and imports; bits rot on disk without warning; and
files can disappear — through accidental deletion, a failing drive, sync gone wrong,
or a malicious actor — without anyone noticing until the file is needed and gone.

A SHA-256 hash is a fingerprint of a file's exact contents. If you fingerprint every
file on a regular schedule, you hold a precise record of what existed and what each
file contained at each point in time. That record is the foundation for answering
questions that matter for long-term data integrity:

- **Silent corruption** — has a file's content changed while its name and timestamp
  stayed the same? (The classic signature of bit-rot, and of tampering.)
- **Silent or malicious deletion** — which files were present last month and are
  gone now, with no deliberate action to explain it?
- **Change tracking** — what has been added, modified, or moved since the last run?

Deduplication is the immediately useful half of the tool: it finds identical files
and whole identical folders and helps you reclaim space safely. Integrity monitoring
is the longer-game half: the same hashes, captured repeatedly, become an audit trail.

---

## What Hasher is

Hasher is a **content-integrity tool**. Its single job is to hash files reliably and
act on those hashes safely:

- Catalogue every file by SHA-256 (optionally in parallel across CPU cores)
- Detect duplicate **files** (identical content) and duplicate **folders**
  (directories whose direct file contents are identical — see note below)
- Remove duplicates safely: quarantine-first, plan-before-act, re-verified before the move
- Find and remove zero-length files and OS junk artefacts
- Emit a timestamped CSV of the complete catalogue on every run

Hasher is deliberately narrow. It hashes, finds duplicates, removes them safely, and
writes the CSV. It does one thing well so it stays small enough to audit and stable
enough to trust with a root-level deletion role on a NAS.

---

## How the integrity monitoring works

Hasher itself does not diff one run against another — that is out of scope, and keeping
it out is what keeps the core small. Instead, **every hash run writes a timestamped CSV**
to `hashes/` (`hasher-YYYY-MM-DD-HHMM.csv`): one row per file, recording its path, size,
modification time, algorithm, and hash.

Those CSVs are the substrate for integrity monitoring. Because each is a complete,
dated snapshot of the catalogue, comparing two of them reveals exactly what changed:

- A path present in the older CSV but absent in the newer one was **deleted**.
- A path in both, with the **same size and mtime but a different hash**, is the
  fingerprint of **silent corruption or tampering**.
- A path whose hash changed alongside an updated mtime was a normal **edit**.
- A path only in the newer CSV was **added**.

Separate, purpose-built tooling consumes these CSVs and reports those differences
across iterations. Keeping the comparison in its own project means the part of the
system that runs as root and moves files stays minimal and auditable, while the
analysis that only *reads* CSVs can evolve independently. Hasher's contract is simply
to produce honest, complete, timestamped snapshots; what you learn by comparing them
is built on top.

---

## Quickstart

```bash
git clone https://github.com/jameswintermute/hasher.git
cd hasher

chmod +x launcher.sh bin/*.sh

./launcher.sh          # first launch runs a short guided setup
```

On first launch Hasher offers a brief, skippable guided setup: it checks
dependencies, helps you choose a parallel-hashing level for your hardware, prompts
for a directory to scan, and shows you where quarantine will live. Everything it
configures is also reachable from the menu afterwards.

---

## About

A project by **James Wintermute** — jameswintermute@protonmail.ch
Started Dec 2022. Current version: **v1.3.3**
For full history see: `version-history.md`

---

## Requirements

- Synology DSM, macOS, or any Linux environment with bash
- Standard tools: `bash`, `awk`, `sort`, `stat`, `find`, `mv`, `rm`, `xargs`
- Recommended install location: anywhere on the volume you scan (e.g. `/volume1/Tools/hasher`). Quarantine is created beside the tool.

Cross-platform support is tested on Synology DSM, Linux, and macOS. Host-aware
defaults (excludes, quarantine paths) are auto-applied via `lib/host-detect.sh`.

---

## Launcher Menu

```
Stage 1 — Hash
   1) Start hashing (NAS-safe defaults)
   a) Advanced / custom hashing
   s) Hashing status
   p) Performance settings (parallel hashing)

Stage 2 — Identify
   2) Find duplicate files
   3) Find duplicate folders
   f) Find file by hash (lookup)

Stage 3 — Review & clean
   4) Review duplicate FILES (interactive)
   r) Review duplicate FOLDERS plan (interactive)
   5) Auto-dedup (keep shortest path — no prompts)
   6) Apply dedup plan (FILE or FOLDER)
   7) Delete zero-length files
   8) Delete junk (uses local/junk-extensions.txt)
   9) Clean cache files & @eaDir (safe)

Other
   d) System diagnostics (deps & readiness)
   l) Follow logs (tail -f background.log)
   t) Stats & scheduling hints
   v) Clean internal working files (var/)
   c) Clean logs (rotate & prune)

   q) Quit
```

Number keys 1–9 drive the main workflow. Letters cover meta and infrequent
operations: `a`/`s`/`p` for hashing variants, status, and performance; `f` for
hash lookup; `r` for folder plan review; and `d/l/t/v/c` for diagnostics and
housekeeping.

---

## Performance — parallel hashing

By default Hasher hashes files serially (one worker), matching its original
behaviour. On multi-core systems with SSD or SHR storage, parallel hashing
can cut large-run times substantially — the per-file process overhead, not the
hashing maths, dominates wall-clock on big small-file corpora (photo libraries).

Set the worker count via the **`p` menu option** (Performance settings). It
detects your CPU cores, recommends a safe value (`min(cores, 4)`), and persists
your choice in `var/jobs.conf`. You can also set it directly:

```bash
# One-off:
bin/hasher.sh --pathfile local/paths.txt --jobs 4

# Or in local/hasher.conf:
[performance]
jobs = 4
```

> **Single spinning HDD?** Keep workers low (1–2). Too many parallel readers
> cause seek thrashing and can make a single-disk NAS *slower*, not faster.
> SSD and multi-disk SHR/RAID arrays benefit most from higher worker counts.

Serial and parallel runs produce identical hash output; parallelism only changes
the order rows are written to the CSV.

---

## Recommended Workflow

### For large volumes — use auto-dedup (option 5)

When you have hundreds or thousands of duplicate groups and don't need
per-group review, option 5 handles the whole process in one step:

1. Run **option 1** — hash all files
2. Run **option 2** — find duplicate files
3. Run **option 5** — auto-dedup (generates plan + offers to apply)

Auto-dedup keeps the copy with the **shortest file path** in each duplicate group
and quarantines the others. Configurable to longest-path, newest, or oldest.

### For careful review — folder-first, then files

Folder dedup removes far more redundancy per decision than file-by-file review.
Run it first:

1. Run **option 1** — hash all files
2. Run **option 3** — find duplicate folders
3. Run **option r** — interactively review the folder plan; accept, skip, or swap
   keepers per group; the reviewer writes a reviewed plan
4. Run **option 6** → `d` — apply the reviewed FOLDER plan
5. Run **option 2** — find duplicate files (now far fewer)
6. Run **option 4** — interactively review the file groups
7. Run **option 6** → `f` — apply the FILE plan

When you run option 3, you'll be offered the reviewer immediately. Decline if
you want to inspect the plan in a different terminal first; option `r` is always
available to come back to.

> **How folder matching works (and what it does not do).** Folder dedup matches
> directories whose *direct* file contents are identical — the files sitting
> immediately inside each directory, compared by name + hash + size. It matches at
> the **leaf level**: given `/A/2013/photos` and `/B/2013/photos` containing the
> same files, it reports those two `photos` directories as duplicates. It does
> **not** build a single signature for a whole tree, so it will not, in one
> decision, identify `/A/2013` as a duplicate of `/B/2013` when those contain only
> sub-folders rather than direct files. For typical layouts (e.g. photos grouped as
> `year/event/files`) leaf-level matching is what you want; just be aware the older
> `--scope recursive` label overstated this and is now an alias for the honest
> `--scope leaf-folders`.

---

## Plan Files

All dedup operations produce a plain-text plan file in `logs/` before anything
is moved. Inspect, then apply.

```bash
# See what would be deleted (file dedup):
cat logs/auto-dedup-plan-*.txt | grep '^DEL' | head -50

# See the folder dedup plan:
cat logs/duplicate-folders-plan-*.txt | head -20

# After reviewing folders interactively:
cat logs/duplicate-folders-plan-reviewed-*.txt
```

**File plan format** (one decision per line, with markers). Since v1.2.0, `DEL`
lines carry the expected content hash as a third field so the file can be
re-verified before quarantine:
```
KEEP|/volume1/James/Photos/IMG_001.jpg
DEL|/volume1/James/Backup/Photos/IMG_001.jpg|3a7bd3e2360a3d29eea436fcfb7e44c7...
DEL|/volume1/James/Archive/Photos/IMG_001.jpg|3a7bd3e2360a3d29eea436fcfb7e44c7...
```

Older two-field plans (`DEL|path`, no hash) are still accepted — re-verification
is simply skipped, with a warning, falling back to an existence check.

**Folder plan format** (one path per line; all listed paths get quarantined;
the implicit keeper is the one *not* listed for each group):
```
/volume1/James/Backup/Photos
/volume1/James/Archive/Photos
```

The folder-dedup finder also writes a `duplicate-folders-groups-*.tsv` sidecar
holding the full keep/del structure with reclaim sizes, used by the reviewer.

All files marked for deletion are moved to **quarantine**, not permanently deleted.

---

## Configuration

```
default/hasher.conf         — defaults (do not edit)
local/hasher.conf           — your overrides
local/paths.txt             — scan roots, one per line
local/excludes.txt          — find exclusion patterns
local/exceptions-hashes.txt — hashes excluded from dedup
local/excluded-from-dedup.txt — path prefixes excluded from dedup
local/junk-extensions.txt   — rules for junk file cleanup
```

Precedence: `CLI flags > local/hasher.conf > default/hasher.conf`

Parallel-hashing precedence: `--jobs flag > hasher.conf [performance] jobs >
var/jobs.conf (set by the 'p' menu) > HASH_JOBS env > default (1)`.

---

## Directory Structure

```
hasher/
├── bin/
│   ├── apply-folder-plan.sh
│   ├── auto-dedup.sh
│   ├── check-deps.sh
│   ├── clean-logs.sh
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
│   ├── review-duplicates.sh
│   ├── review-folder-plan.sh    ← v1.1.13
│   ├── review-junk.sh
│   └── run-find-duplicates.sh
│
├── lib/
│   └── host-detect.sh           ← v1.1.9
│
├── default/
│   └── hasher.conf
│
├── local/                       — your config (gitignored)
│   ├── exceptions-hashes.txt
│   ├── excluded-from-dedup.txt
│   ├── excludes.txt
│   ├── hasher.conf
│   ├── junk-extensions.txt
│   └── paths.txt
│
├── logs/                        — plan files and reports (gitignored)
├── hashes/                      — hash CSVs (gitignored)
├── var/                         — working files, jobs.conf (gitignored)
├── quarantine/                  — files moved by delete-duplicates.sh
│
├── launcher.sh
├── LICENSE
├── readme.md
└── version-history.md
```

---

## Safety Model

**Deduplication (the core workflow) is quarantine-first and never deletes:**

- Plans are written and reviewable before anything is moved
- **Content re-verification (v1.2.0):** before quarantining, `delete-duplicates.sh`
  re-hashes each candidate and skips any whose content no longer matches the hash
  in the plan — protecting files modified between planning and applying
- The folder-dedup reviewer (option `r`) lets you accept, skip, or swap keepers
  per duplicate group before applying anything
- Applying a raw (unreviewed) folder plan prompts for explicit confirmation
- `delete-duplicates.sh` and `apply-folder-plan.sh` move files to quarantine —
  not permanent deletion; `apply-folder-plan.sh` uses collision-proof quarantine
  naming (v1.1.6+)
- Exceptions list prevents re-flagging known-safe duplicates

**Housekeeping helpers delete by default** — these are separate from dedup and
remove files permanently unless noted:

- `delete-zero-length.sh` deletes empty files; pass `--quarantine` to move them instead
- `delete-junk.sh` permanently removes files matching `local/junk-extensions.txt`
- cache/`@eaDir` cleaning permanently removes those caches
- All support `--force`/dry-run patterns; review the plan or run without `--force` first

**General:**

- All scripts re-verify paths immediately before acting
- Bash 3.2 / BSD awk / macOS userland compatibility audited (v1.1.9–v1.1.12)

---

## Troubleshooting

**Sizes show as `??` in duplicate review**
Run `review-duplicates.sh` directly on the NAS via SSH — it cannot stat remote paths.

**CSV appears corrupted**
Fix line endings: `sed -i 's/\r$//' hashes/*.csv`

**"All paths missing or unreadable" error**
The paths in `local/paths.txt` don't exist on this host. Common causes: external
drive not mounted, typo in volume name, NAS share offline. Use `ls /Volumes`
(macOS), `ls /mnt` or `ls /media` (Linux), or `ls /volume1` (Synology) to check.

**Folder review says "no groups TSV found"**
Run option 3 (Find duplicate folders) first. The reviewer reads
`logs/duplicate-folders-groups-*.tsv`, which is produced by the finder.

**"Content changed since plan was made — SKIPPING"**
Expected and safe: a file changed between hashing and applying, so it's no longer
a verified duplicate. Re-run hashing and dedup to re-evaluate it.

**Parallel hashing makes my NAS slower**
You're likely on a single spinning HDD. Set workers back to 1–2 via the `p` menu.
Parallelism helps SSD/SHR arrays, not single-spindle disks.

---

## License

GNU GPLv3 — see LICENSE.

---

## Further Reading

- [Facebook — Silent Data Corruption](https://engineering.fb.com/2021/02/23/data-infrastructure/silent-data-corruption/) — the motivating use case for hash-based integrity monitoring
