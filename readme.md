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
and folders with identical direct contents, and helps you reclaim space safely.
Integrity monitoring is the longer-game half: the same hashes, captured repeatedly,
become an audit trail.

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
it out is what keeps the core small. Instead, **every successful hash run writes a
timestamped CSV** to `hashes/` (`hasher-YYYY-MM-DD-HHMMSS-PID.csv`): one row per file,
recording its canonical path, size, modification time, algorithm, and hash. Incomplete
runs are retained separately as `partial-hasher-*.csv` for diagnosis and are not selected
by the normal dedupe workflow.

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

Until the first hash manifest exists, the launcher shows a focused welcome screen
rather than the full menu — every review and cleanup action needs a manifest as its
input, so the only useful action at that point is starting the first run. The screen
offers that one action plus settings and help, and switches to status/log/stop
controls while the first run is in progress.

---

## About

A project by **James Wintermute** — jameswintermute@protonmail.ch
Started Dec 2022. Current version: **v1.4.0**

### First-run launch screen

Before any manifest exists, the launcher presents a short welcome screen with a
single recommended action — start the first hash — plus **Settings & preferences**
(scan paths, performance, analysis mode, diagnostics) and **Help & information**
explaining what the hash run does and does not do. Once the first manifest is
written, the full workflow menu takes over automatically.

### Guided main menu

After a complete hash and post-hash analysis, the launcher displays compact counts for the latest run and recommends the next safe review action. Manual duplicate discovery is available under **Rerun duplicate analysis** rather than occupying the primary workflow.

### Automatic or manual analysis workflow

On first-run setup, Hasher asks whether duplicate analysis should run automatically
after each successful complete hash. **Automatic** is the recommended default because
it prepares folder, file, and review-index results while the NAS is already working;
it never reviews, quarantines, or deletes anything automatically.

```ini
[post_hash]
analysis_mode = automatic   # or manual
```

Automatic mode shows the compact statistics-led review menu. Manual mode retains the
traditional discovery-first menu. Change modes later from launcher option `m`, or edit
`local/hasher.conf`.
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

Before the first manifest exists, the launcher shows a focused welcome screen:

```
Welcome. Hasher is ready for its first run.

Ready to begin
   Start the first hash run to build the inventory.

   1) Initiate first Hasher run (recommended)

Options
   2) Settings & preferences
   3) Help & information

   q) Quit
```

While the first run is in progress, options `1`–`3` are replaced by `s` (status),
`l` (follow log) and `k` (stop hashing).

Once a manifest exists, the full workflow menu appears. Its layout depends on the
analysis mode.

### Automatic mode (default)

Duplicate analysis has already run, so the menu leads with review and quarantine.
A compact summary above the menu shows what is waiting and recommends the next
action.

```
Stage 1 — Hash
   1) Start hashing (NAS-safe defaults)
   a) Advanced / custom hashing
   s) Hashing status
   p) Performance settings (parallel hashing)
   k) Stop hashing (terminate running hash jobs)

Stage 2 — Review & quarantine
   2) Review duplicate folders
   3) Review duplicate files
   4) Apply reviewed plan
   5) Auto-dedup files (keep shortest path — no prompts)
   f) Find file by hash (lookup)

Stage 3 — Clean
   6) Review zero-length files
   7) Delete junk (uses local/junk-extensions.txt)
   8) Clean cache files & @eaDir (safe)

Other
   r) Rerun duplicate analysis
   m) Change analysis mode (automatic/manual)
   d) System diagnostics (deps & readiness)
   x) Self-test (integrity preflight)
   l) Follow logs (tail -f background.log)
   t) Stats & scheduling hints
   v) Clean internal working files (var/)
   c) Clean logs (rotate & prune)

   q) Quit
```

### Manual mode

Duplicate discovery stays an explicit step, so the menu keeps the traditional
identify-then-review ordering.

```
Stage 1 — Hash
   1) Start hashing (NAS-safe defaults)
   a) Advanced / custom hashing
   s) Hashing status
   p) Performance settings (parallel hashing)
   k) Stop hashing (terminate running hash jobs)

Stage 2 — Identify
   2) Find duplicate folders
   3) Find duplicate files
   f) Find file by hash (lookup)

Stage 3 — Review & clean
   4) Review duplicate files (interactive)
   r) Review duplicate folders plan (interactive)
   5) Auto-dedup files (keep shortest path — no prompts)
   6) Apply dedup plan (FILE or FOLDER)
   7) Delete zero-length files
   8) Delete junk (uses local/junk-extensions.txt)
   9) Clean cache files & @eaDir (safe)

Other
   m) Change analysis mode (automatic/manual)
   d) System diagnostics (deps & readiness)
   x) Self-test (integrity preflight)
   l) Follow logs (tail -f background.log)
   t) Stats & scheduling hints
   v) Clean internal working files (var/)
   c) Clean logs (rotate & prune)

   q) Quit
```

> **Folders before files.** In manual mode, run duplicate *folders* (option 2)
> before duplicate *files* (option 3). Removing duplicate files first changes
> folder contents, so identical folders may no longer match and you lose the
> bigger, one-decision folder cleanup. Automatic mode runs them in this order
> for you.

Number keys drive the main workflow; letters cover meta and infrequent
operations. Note that option numbering differs between the two modes — the
summary line above the menu always names the correct option for the recommended
next action.

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

### For large volumes — use auto-dedup

When you have hundreds or thousands of duplicate groups and don't need
per-group review, auto-dedup handles file dedup in one step. **Do folders first**
(see the note below on ordering).

**Automatic mode** — analysis has already run, so you go straight to review:

1. Run **option 1** — hash all files; folder and file analysis run automatically
2. Run **option 2** — review the duplicate folders plan
3. Run **option 4** — apply the reviewed folder plan
4. Run **option 5** — auto-dedup the remaining files

**Manual mode** — discovery is an explicit step:

1. Run **option 1** — hash all files
2. Run **option 2** — find duplicate folders, then **option r** to review and
   **option 6 → d** to apply the folder plan
3. Run **option 3** — find duplicate files (now far fewer)
4. Run **option 5** — auto-dedup the remaining files

Auto-dedup keeps the copy with the **shortest file path** in each duplicate group
and quarantines the others. Configurable to longest-path, newest, or oldest. It
consumes only the verified, hard-link-filtered duplicate report — a raw hash-scan
summary is refused.

> **Why folders first?** File dedup collapses duplicate files *inside* folders,
> which changes those folders' contents. Two folders that are currently identical
> may no longer match afterwards — so you lose the bigger, one-decision folder
> cleanup. Automatic mode runs folder analysis before file analysis for you. In
> manual mode the menu lists folders first and warns if you start file dedup
> before running folder detection; the warning is a single keypress and never
> blocks you.

### For careful review — folder-first, then files

Folder dedup removes far more redundancy per decision than file-by-file review.
Run it first:

**Automatic mode:**

1. Run **option 1** — hash all files; analysis runs automatically afterwards
2. Run **option 2** — interactively review the folder plan; accept, skip, or swap
   keepers per group; the reviewer writes a reviewed plan
3. Run **option 4** — apply the reviewed FOLDER plan
4. Run **option 3** — interactively review the file groups
5. Run **option 4** — apply the FILE plan

**Manual mode:**

1. Run **option 1** — hash all files
2. Run **option 2** — find duplicate folders
3. Run **option r** — interactively review the folder plan
4. Run **option 6** → `d` — apply the reviewed FOLDER plan
5. Run **option 3** — find duplicate files (now far fewer)
6. Run **option 4** — interactively review the file groups
7. Run **option 6** → `f` — apply the FILE plan

In manual mode, when you run folder discovery you'll be offered the reviewer
immediately. Decline if you want to inspect the plan in a different terminal
first; option `r` is always available to come back to.

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
│   ├── find-duplicate-folders.sh
│   ├── find-duplicates.sh
│   ├── hash-check.sh
│   ├── hasher.sh
│   ├── launch-review.sh
│   ├── review-duplicates.sh
│   ├── review-folder-plan.sh    ← v1.1.13
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
- **Content re-verification (v1.2.0 files, v1.3.5 folders):** before quarantining,
  `delete-duplicates.sh` re-hashes each candidate file, and `apply-folder-plan.sh`
  recomputes each duplicate folder's direct-file signature from disk, skipping
  anything whose content no longer matches the plan/keeper — protecting files and
  folders modified between planning and applying
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

## Self-test (integrity preflight)

`bin/self-test.sh` is a read-only check that verifies the install is internally
consistent — it never moves, deletes, or rewrites anything. It runs automatically
(and silently) at launcher startup, surfacing a banner only if it finds errors,
and is available on demand from the menu (option `x`) or directly:

```bash
bin/self-test.sh            # full report
bin/self-test.sh --quiet    # only warnings/errors + summary
bin/self-test.sh --strict   # treat warnings as failures (for CI)
```

It checks that sourced helpers resolve and parse, that there are no stale
duplicate copies of a sourced helper, that every launcher menu target exists and
is runnable (executable, or readable for the bash fallback), that the launcher
and `default/hasher.conf` versions agree, that required commands and a SHA-256
tool are present, that Bash meets the 3.2 baseline, and that the config and scan
paths are sane. Exit status is `0` on pass, `1` if any errors are found. It exists
to catch — at launch rather than in production — the class of problem where a
correct change lands in a file the running code doesn't load, a script arrives
without its executable bit, or the conf version drifts out of sync.

---

## Automatic post-hash analysis

After a complete successful hash run, Hasher can prepare duplicate results
while the NAS is still working unattended. The finder stages never review,
quarantine, or delete anything; they only create verified reports and indexes.

```ini
[post_hash]
auto_find_duplicate_folders = true
auto_find_duplicate_files = true
auto_build_review_index = true
```

`find-duplicates.sh` creates a run-matched
`duplicate-review-index-*.tsv` using file sizes already stored in the manifest.
Option 4 verifies that the index belongs to its selected report, applies the
current exceptions list, and starts from the prepared savings order instead of
stat-ing every duplicate group again. If the index is absent or mismatched, the
reviewer safely falls back to its original live-indexing behaviour.

For systems where duplicate-folder cleanup is already complete, set
`auto_find_duplicate_folders = false` to avoid repeating that scan. Post-hash
analysis is skipped for partial manifests.

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
