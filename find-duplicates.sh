#!/usr/bin/env bash
# find-duplicates.sh — Generate duplicate report from hasher CSV
# Dry-run style: only analyzes and writes reports; does not delete/move.
# Output format matches hasher.sh's post_run_reports for compatibility with deduplicate.sh.
set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ───────── Config ─────────
HASHES_DIR="hashes"
LOGS_DIR="logs"
DATE_TAG="$(date +'%Y-%m-%d')"
RUN_ID="$( (command -v uuidgen >/dev/null 2>&1 && uuidgen) || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$$" )"

REPORT="$LOGS_DIR/$DATE_TAG-duplicate-hashes.txt"
SUMMARY_TSV="$LOGS_DIR/duplicate-summary-$DATE_TAG-$RUN_ID.tsv"
TOP_N=10               # how many top groups to print
GROUP_DEPTH=2          # path grouping depth for summary (/volume1/Share = 2)
FROM_CSV=""            # override input CSV
MIN_SIZE=0             # bytes; filter out dup groups below this size (0=all)

# ───────── Colors ─────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() {
  local lvl="$1"; shift
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RUN %s] [%s] %s\n' "$ts" "$RUN_ID" "$lvl" "$*" >&2
}

usage() {
cat <<EOF
Usage: $0 [--from-csv FILE] [--min-size BYTES] [--group-depth N] [--top N] [-h|--help]

Find duplicate files by hash from a hasher CSV (default: newest hashes/hasher-*.csv),
write a report to: $REPORT, and a summary TSV to: $SUMMARY_TSV.

Options:
  --from-csv FILE     Use a specific hasher CSV (expects header: path,size_bytes,mtime_epoch,algo,hash)
  --min-size BYTES    Only include duplicate groups where per-file size >= BYTES (default: 0)
  --group-depth N     Grouping depth for summary (default: $GROUP_DEPTH)
  --top N             Show top N path groups in console (default: $TOP_N)
  -h, --help          Show this help

Example:
  $0                               # use latest hashes/hasher-*.csv
  $0 --min-size 1048576            # only 1MB+ dup groups
  $0 --group-depth 3 --top 20      # deeper summary
  $0 --from-csv hashes/hasher-2025-08-30.csv
EOF
}

# ───────── Args ─────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-csv)     FROM_CSV="${2:-}"; shift ;;
    --min-size)     MIN_SIZE="${2:-0}"; shift ;;
    --group-depth)  GROUP_DEPTH="${2:-2}"; shift ;;
    --top)          TOP_N="${2:-10}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo -e "${YELLOW}Unknown option: $1${NC}" >&2; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$HASHES_DIR" "$LOGS_DIR"

# Pick latest CSV if not provided
if [[ -z "$FROM_CSV" ]]; then
  if ! FROM_CSV="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1)"; then
    log ERROR "No CSV found in $HASHES_DIR. Run hasher.sh first."
    exit 1
  fi
fi
[[ -r "$FROM_CSV" ]] || { log ERROR "Cannot read CSV: $FROM_CSV"; exit 1; }

log INFO "Using CSV: $FROM_CSV"
log INFO "Report will be written to: $REPORT"
log INFO "Summary TSV will be written to: $SUMMARY_TSV"
log INFO "Filters: min_size=${MIN_SIZE}B, group_depth=$GROUP_DEPTH"

# ───────── Build duplicate report ─────────
# We assume header: path,size_bytes,mtime_epoch,algo,hash (as produced by hasher.sh).
# We parse the first (possibly quoted) CSV field by hand to be robust to commas in paths.
# Output format:
#   HASH <hash> (<N> files):
#     /path/one
#     /path/two
#   [blank line between groups]
awk -v minsize="$MIN_SIZE" -v report="$REPORT" -v summary="$SUMMARY_TSV" -v depth="$GROUP_DEPTH" -v topn="$TOP_N" '
  function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
  function unquote_csv(s){ gsub(/""/,"\"",s); return s }
  # Parse our known schema line into path,size,hash quickly and robustly.
  function parse_line(line,   path, rest, c, endq, size, mtime, algo, hash) {
    if (substr(line,1,1)=="\"") {
      # quoted path
      endq=0
      for (i=2;i<=length(line);i++) {
        ch=substr(line,i,1)
        if (ch=="\"") {
          nxt=substr(line,i+1,1)
          if (nxt=="\"") { i++; continue } else { endq=i; break }
        }
      }
      if (endq==0) return 0
      path=substr(line,2,endq-2)
      path=unquote_csv(path)
      rest=substr(line,endq+2)  # skip closing quote and following comma
    } else {
      c=index(line,",")
      if (c==0) return 0
      path=substr(line,1,c-1)
      rest=substr(line,c+1)
    }
    # size
    c=index(rest,","); if (c==0) return 0
    size_str=substr(rest,1,c-1); size_str=ltrim(rtrim(size_str))
    rest=substr(rest,c+1)
    # mtime
    c=index(rest,","); if (c==0) return 0
    # mtime_str=substr(rest,1,c-1) ; not used
    rest=substr(rest,c+1)
    # algo
    c=index(rest,","); if (c==0) return 0
    # algo=substr(rest,1,c-1) ; not used
    hash=substr(rest,c+1)
    size = size_str + 0
    PATH=path; SIZE=size; HASH=hash
    return 1
  }
  function prefix(p, depth,   i,n,part,count,acc) {
    n = split(p, a, "/")
    acc=""; count=0
    for (i=1; i<=n; i++) {
      part=a[i]
      if (part=="") continue
      count++
      if (count<=depth) acc=acc "/" part; else break
    }
    if (acc=="") acc="/"
    return acc
  }
  BEGIN{
    OFS="\t"
    groups=0; dup_files=0; reclaim=0
  }
  NR==1 { next } # skip header
  {
    line=$0
    if (!parse_line(line)) next
    # accumulate by hash
    if (!(HASH in count)) {
      count[HASH]=0
      size_by_hash[HASH]=SIZE
      files[HASH]=""
    }
    count[HASH]++
    files[HASH]=files[HASH] "\n" PATH
  }
  END{
    # Write report
    out = report
    if ((f = fopen(out, "w")) == 0) {
      print "ERROR: cannot write report: " out > "/dev/stderr"
      exit 1
    }
    for (h in count) {
      c=count[h]
      s=size_by_hash[h]+0
      if (c>1 && s>=minsize) {
        groups++
        dup_files += c
        reclaim += (c-1)*s
        printf("HASH %s (%d files):\n", h, c) > out
        # list files
        split(files[h], arr, "\n")
        for (i=1; i<=length(arr); i++) {
          p=arr[i]
          if (p=="") continue
          printf("  %s\n", p) > out
          # build path summary
          pre = prefix(p, depth)
          groupcount[pre]++
        }
        printf("\n") > out
      }
    }
    close(out)

    # Write summary TSV sorted by count desc
    # Format: <path_prefix>\t<count>
    # We will post-sort outside awk using sort for portability.
    tmp = summary ".tmp"
    if ((f2 = fopen(tmp, "w")) == 0) {
      print "ERROR: cannot write summary tmp: " tmp > "/dev/stderr"
      exit 1
    }
    for (k in groupcount) {
      printf("%s\t%d\n", k, groupcount[k]) > tmp
    }
    close(tmp)
    # Sort numerically desc by 2nd field
    cmd = "sort -k2,2nr " tmp " > " summary
    system(cmd)
    system("rm -f " tmp)

    # Print console summary
    printf("%sDuplicate analysis complete.%s\n", "\033[0;32m", "\033[0m") > "/dev/stderr"
    printf("  • Duplicate groups: %d\n", groups) > "/dev/stderr"
    printf("  • Files in dup groups: %d\n", dup_files) > "/dev/stderr"
    printf("  • Potential reclaim: %d bytes\n", reclaim) > "/dev/stderr"
    printf("  • Report: %s\n", report) > "/dev/stderr"
    printf("  • Summary TSV: %s\n", summary) > "/dev/stderr"

    # Print top N groups
    printf("\nTop %d groups (depth=%d):\n", topn, depth) > "/dev/stderr"
    # read back the sorted summary
    cmd2 = "head -n " topn " " summary
    while ((cmd2 | getline line2) > 0) {
      # split line2 by tab
      split(line2, flds, "\t")
      pref=flds[1]; cnt=flds[2]+0
      if (dup_files>0) pct = int(cnt*100/dup_files); else pct=0
      printf("  %2d) %-50s %6d files (%3d%%)\n", ++rank, pref, cnt, pct) > "/dev/stderr"
    }
    close(cmd2)
  }
' "$FROM_CSV"

# Friendly next step
echo
echo -e "${GREEN}[NEXT STEPS]${NC}"
echo "  1) Review the duplicate report:"
echo "       less \"$REPORT\""
echo "  2) Dry-run dedupe interactively (if your tool supports it):"
echo "       ./review-duplicates.sh"
echo "  3) Move extras to quarantine (safe):"
echo "       ./deduplicate.sh --from-report \"$REPORT\" --keep newest --quarantine \"quarantine-$DATE_TAG\""
echo "  4) Or delete extras (dangerous):"
echo "       ./deduplicate.sh --from-report \"$REPORT\" --keep newest --force"
