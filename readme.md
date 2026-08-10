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
Started Dec 2022. Current version: **v1.4.16**

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

## Import Check

For bringing files from an SD card, old backup disk, DVD rip, or cloud
export onto the NAS without duplicating anything already there.

The rule is simple and absolute: **the NAS copy always wins.** If a file in
the import folder matches a file already on the NAS — confirmed by
SHA-256, re-verified again immediately before anything is moved — the
import copy is quarantined and the NAS file is never touched.

This is enforced two ways, deliberately independent of each other:

1. **Isolation.** The import folder must not overlap any trusted NAS scan
   root (`local/paths.txt`) — not equal to one, not inside one, not
   containing one, checked after resolving symlinks and `..` so the check
   cannot be routed around. `setup` refuses to configure an overlapping
   folder, and every operational subcommand re-checks it on every run,
   because `paths.txt` and `hasher.conf` are both plain text files a user
   can hand-edit afterwards. Without this, a NAS path could end up
   *inside* what the tool considers "import content" and be treated as
   disposable — which is a materially different, and worse, failure than
   anything the classifier itself controls.
2. **Classification.** Given an isolated import folder, a NAS path can
   never appear on the delete side of the generated plan — enforced
   structurally in the classifier (NAS-side and import-side paths are
   built as separate lists that are never merged into one pool to choose
   a keeper from), not just by convention.

```bash
bin/import-check.sh setup     # first time: choose/create the import folder
bin/import-check.sh scan      # hash the import folder (fast — not a full NAS rescan)
bin/import-check.sh summary   # see what matches, what doesn't
bin/import-check.sh discard   # quarantine the NAS duplicates, with confirmation
bin/import-check.sh dedup-internal # quarantine the import's OWN duplicates, keep shortest path
bin/import-check.sh sort      # move whatever's left into import/unique-files/
```

Also reachable from the launcher's main menu (`i`).

**Trust boundary.** The import folder is never added to `local/paths.txt`.
It is untrusted staging material, hashed separately by `scan`; keeping it
out of the trusted inventory means full NAS hashes don't spend time on
temporary import content and ordinary duplicate discovery never processes
it as if it were NAS data. Attempting to configure an import folder that
equals, contains, or sits inside a trusted NAS root is refused outright —
checked after resolving symlinks and `..`, and re-checked on every
operational subcommand, not only at setup time, since `paths.txt` and
`hasher.conf` are both plain text files a user can hand-edit afterwards.

**`dedup-internal` never touches the NAS's own duplicate-discovery
output.** It reuses `find-duplicates.sh` internally (the same tool the
main menu's duplicate discovery uses), but with `--report-out` and
`--no-publish-latest` so its report lands in its own
`logs/import-internal-duplicates-*` namespace rather than overwriting
`logs/duplicate-hashes-latest.txt` — the pointer `review-duplicates.sh`,
`auto-dedup.sh`, and `launch-review.sh` all default to reading for the
normal NAS workflow.

**What "scan" compares against.** Only the import folder is (re)hashed each
time — comparison uses the NAS manifest that existed at scan time, not
whatever the newest one happens to be later. `scan` records which manifest
it used in a sidecar (`hashes/import-scan-<run>.meta`), and that sidecar is
authoritative: `summary`, `discard`, `dedup-internal`, and `sort` all
derive both the import CSV and the pinned NAS manifest from the meta
file's own fields, rather than independently resolving two separately
published `-latest` pointers, so the two can never describe different
scans. The meta's recorded import folder is also cross-checked against
whichever one is currently configured, catching the case where you've
switched import folders since the last scan. A sidecar that exists but is
truncated or otherwise invalid — a crash mid-write, or direct editing — is
refused outright rather than silently falling back to an unpinned
comparison; only a genuinely absent sidecar (a pre-v1.4.7 scan) falls back
that way. If a newer NAS manifest exists, you're told — a warning, not a
substitution — and can re-run `scan` to compare against it. If a NAS file
has changed or been removed since the pinned manifest was taken
regardless, `discard`'s reuse of `delete-duplicates.sh` re-verifies each
match immediately before acting and skips anything that no longer checks
out (exit code 4, not an error).

**What's automated and what isn't.** *Cross-boundary* matches — an import
file that duplicates something already on the NAS — are resolved by
`discard`. Files that duplicate *each other* inside the import folder are
a separate, explicit action: `dedup-internal`, run after `discard` (so it
only ever considers groups with no NAS match — `discard` has already
cleared out the rest), keeping the shortest path in each group. It was
deliberately kept out of `discard` itself: "which of my own two copies do
I keep" has no safe default the way "does the NAS already have this"
does, so it gets its own plan-review-then-confirm step rather than being
folded silently into the automatic one. Whatever is left after both —
genuinely unique, no NAS match, no internal duplicate — is what `sort`
moves into `import/unique-files/` for you to look through by hand. `scan`
excludes `unique-files/` itself from later runs, so files you've already
sorted aren't repeatedly reconsidered.

**Working from current data.** `discard` and `dedup-internal` both refuse
to run against a scan that predates a prior discard or dedup-internal
action against the same folder — a stale scan's rows may no longer
reflect what's actually on disk. `summary` is read-only, so it warns
instead of refusing, and still shows the numbers with the caveat that
they may be out of date. `sort` is deliberately exempt: it makes no
keep-or-delete judgement and already tolerates files that have moved or
vanished since the scan, so requiring a fresh scan before every `sort`
would cost real friction for no added safety.

**Progress on large imports.** `summary`, `discard`, and `sort` all classify
the import against the NAS manifest before doing anything else, and on a
large import (order 100k files) that comparison alone can take several
seconds. When run interactively, an in-place progress bar shows it working;
piped or redirected output stays clean with no bar at all. `scan` itself —
the hashing pass over the import folder — now shows the same periodic
`[PROGRESS]` line on screen that has always gone to
`logs/background.log`, since `scan` runs synchronously in whatever
terminal it was invoked from and has no separate follow-log step the way
the launcher's backgrounded "Start hashing" does; on a large corpus,
minutes of complete silence there were previously indistinguishable from
a hang. `scan` also honours whatever parallel-hashing level is configured
via the launcher's Performance settings menu (`var/jobs.conf`) — it
previously always ran fully serial regardless of that setting, which
measurably matters on a large small-file corpus (an SD card, a
Photos-library-style export), where per-file fork overhead, not the
hashing itself, dominates wall-clock in serial mode.

**Concurrency.** `scan`, `discard`, and `sort` take a lock
(`var/import-check.lock`) so two of them can't run against the same import
folder at once — `summary` is read-only and `setup` has its own
confirmation prompts, so neither needs it.

**A filename containing `|`** would corrupt the `KEEP|path|hash` plan
format the same way it inherited from every other duplicate-handling tool
in this project. Import Check processes material from uncontrolled
external media, so this is more likely to come up here than elsewhere;
any match involving such a filename is excluded from the plan rather than
risking a corrupted line, with a warning naming the file so you can rename
it and re-run.

---

## Plan Files

All dedup operations produce a plain-text plan file in `logs/` before anything
is moved. Inspect, then apply.

**Applying a large plan.** `delete-duplicates.sh` validates every plan in
three passes before moving anything — classifying each entry as
hash-verified or not, building the hash-to-keeper map, then confirming
every hash group has exactly one keeper — and shows progress (`[SCAN]`,
`[BUILD]`, `[VERIFY]`) through all three, followed by `[MOVE]` for the
actual quarantine step. On a plan with tens of thousands of entries these
verification passes can take real time — minutes, not seconds; this is
deliberately conservative validation of a destructive operation, not
something to route around. `[INFO]`/`[WARN]`/`[ERROR]` output from this
script is coloured to match the rest of the tool.

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
├── bin/                              — the tools
│   ├── apply-folder-plan.sh             apply a reviewed FOLDER plan
│   ├── auto-dedup.sh                    no-prompt file dedup
│   ├── check-deps.sh                    dependency check (--fix offers shims)
│   ├── clean-logs.sh                    rotate and prune logs/
│   ├── csv-quick-stats.sh               manifest summary
│   ├── delete-duplicates.sh             apply a FILE plan (quarantine-first)
│   ├── delete-junk.sh                   remove local/junk-extensions.txt matches
│   ├── delete-zero-length.sh            remove or quarantine 0-byte files
│   ├── find-duplicate-folders.sh        folder-level discovery
│   ├── find-duplicates.sh               file-level discovery
│   ├── hash-check.sh                    verify a file against the manifest
│   ├── import-check.sh                  NAS-precedence check for staged imports
│   ├── hasher.sh                        the hashing engine
│   ├── launch-review.sh                 review entry point
│   ├── review-duplicates.sh             interactive FILE review
│   ├── review-folder-plan.sh            interactive FOLDER review
│   ├── run-find-duplicates.sh           discovery wrapper
│   └── self-test.sh                     installation preflight
│
├── lib/                              — shared modules
│   ├── awk-detect.sh                    BusyBox NUL-handling probe
│   ├── host-detect.sh                   platform detection, path helpers
│   └── log.sh                           shared logging
│
├── tests/                            — fault-injection suite
│   ├── run-tests.sh                     runner
│   ├── lib/
│   │   └── harness.sh                   sandboxes, shims, fixtures, assertions
│   └── cases/
│       ├── 01-core-hashing.sh
│       ├── 10-input-validation.sh
│       ├── 20-snapshot-integrity.sh
│       ├── 30-manifest-validation.sh
│       ├── 40-dedup-safety.sh
│       ├── 50-exit-status.sh
│       ├── 60-process-safety.sh
│       ├── 70-launcher-status.sh
│       ├── 80-first-run-gating.sh
│       ├── 85-manifest-selection.sh
│       ├── 90-import-check.sh
│       ├── 91-import-check-isolation.sh
│       ├── 92-import-check-dedup-internal.sh
│       ├── 93-import-check-v1410-fixes.sh
│       ├── 94-import-check-meta-corruption.sh
│       ├── 95-import-check-scan-visibility.sh
│       ├── 96-launcher-import-check-survival.sh
│       └── 97-delete-duplicates-build-phase.sh
│
├── default/
│   └── hasher.conf                      shipped defaults — do not edit
│
├── local/                            — your config (not tracked)
│   ├── paths.txt                        what to scan, one path per line
│   ├── excludes.txt                     glob patterns to skip
│   ├── junk-extensions.txt              extensions for option 7
│   ├── exceptions-hashes.txt            hashes never to quarantine
│   ├── hasher.conf                      your overrides (optional)
│   └── .setup-complete                  guided-setup sentinel
│
├── hashes/                           — manifests (not tracked)
│   ├── hasher-<stamp>.csv               complete manifests
│   └── partial-hasher-<stamp>.csv       incomplete runs, kept for diagnosis
│
├── logs/                             — reports and plans (not tracked)
│
├── var/                              — internal working state (not tracked)
│   ├── low-value/
│   ├── quarantine/
│   └── zero-length/
│
├── quarantine-<date>/                — quarantined files (created on demand)
│
├── launcher.sh                       — the menu; start here
├── readme.md
├── version-history.md
├── LICENSE
└── .gitignore
```

**Quarantine location.** Since v1.3.2 the default is install-relative:
`<install-dir>/quarantine-<date>`, created the first time something is
quarantined. It therefore follows the tool if you move the install. Set
`QUARANTINE_DIR` in `local/hasher.conf` to pin it somewhere fixed.

**What is not tracked.** `hashes/`, `logs/`, `var/` contents, `quarantine-*/`
and `local/` are all runtime or machine-specific and are excluded by
`.gitignore`. The three `.gitkeep` files under `var/` are tracked so the
directory skeleton survives a fresh clone.

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

## Fault-injection test suite

The self-test answers "is this installation intact". The suite under `tests/`
answers a different question: "does this tool still *behave* correctly when the
input is hostile".

```bash
tests/run-tests.sh                # everything (18 cases, ~85s)
tests/run-tests.sh 20 40          # only cases whose leading number matches
tests/run-tests.sh --list         # list cases without running them
tests/run-tests.sh --verbose      # per-case diagnostic notes
tests/run-tests.sh --keep         # retain sandboxes for inspection
```

Also offered from launcher option `x`, after the integrity self-test.

Every case reproduces a defect found in real review. The situations covered are
the ones that have historically broken things — none of which a run over a flat
directory of ordinary files would exercise:

| Case | Covers |
|---|---|
| `01-core-hashing` | Clean run: counts, row count, sorted manifest |
| `10-input-validation` | Overlapping scan roots, explicitly listed symlinks |
| `20-snapshot-integrity` | Files rewritten mid-hash, including same-size content with mtime restored |
| `30-manifest-validation` | Truncated rows, wrong algorithm, `--allow-malformed-rows` |
| `40-dedup-safety` | Hard links, folders holding symlinks, report provenance |
| `50-exit-status` | Exit codes 0/1/4, empty input, destructive-tool failures |
| `60-process-safety` | Lock ownership, orphaned workers, non-functional `pgrep` |
| `70-launcher-status` | Live progress takes precedence over a stale summary |
| `80-first-run-gating` | Unconfigured installs cannot start an empty run |
| `85-manifest-selection` | Newest usable manifest, storage availability, preflight parity |
| `90-import-check` | NAS-precedence duplicate classification, boundary safety, remainder handling |
| `91-import-check-isolation` | Overlap refusal, paths.txt isolation, manifest pinning, lock, pipe-char safety |
| `92-import-check-dedup-internal` | Import's own duplicates, keep-shortest-path, staleness refusal, NAS isolation |
| `93-import-check-v1410-fixes` | NAS-pointer isolation, migration reachability, atomic scan pinning, consistent staleness, accurate counts |
| `94-import-check-meta-corruption` | Corrupt/truncated scan metadata is refused, not silently bypassed |
| `95-import-check-scan-visibility` | Configured parallelism honoured; progress tickers stay silent when piped |
| `96-launcher-import-check-survival` | Launcher survives non-zero returns from Import Check subcommands |
| `97-delete-duplicates-build-phase` | BUILD-phase progress added; keeper-map error detection unaffected |

**Safety.** Each case runs in its own sandbox under a temporary directory —
nothing outside it is written, and the install tree is never modified. Fault
injection is done entirely with `PATH` shims, never by touching system tools.
Stray processes are matched by sandbox path, so real hasher runs elsewhere on
the machine are never at risk.

**Adding a case.** Drop a file in `tests/cases/` defining `case_description`
and a `run_case` function. `tests/lib/harness.sh` provides sandbox management,
fixture builders (hard links, symlinks, twin folders, malformed manifests),
fault-injection shims, and assertions. Assertions should describe behaviour
rather than implementation, so that a rewrite preserving the guarantee still
passes.

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
