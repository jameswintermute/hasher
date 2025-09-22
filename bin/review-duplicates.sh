#!/bin/sh
# review-duplicates.sh — Interactive review of duplicate hash groups
# BusyBox/POSIX sh compatible. No bashisms.
# Sorts groups by potential reclaim (largest first) so you free max space first.
# Potential reclaim per group = file_size(hash) * (N-1)
set -eu

# ────────────────────────────── Layout ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs";   mkdir -p "$LOGS_DIR"
HASHES_DIR="$ROOT_DIR/hashes"; mkdir -p "$HASHES_DIR"
VAR_DIR="$ROOT_DIR/var";     mkdir -p "$VAR_DIR"

# ────────────────────────────── Defaults ────────────────────────────
REPORT_DEFAULT="$LOGS_DIR/duplicate-hashes-latest.txt"
REPORT="$REPORT_DEFAULT"
KEEP_POLICY="shortest-path"   # newest|oldest|shortest-path|longest-path|first-seen
LIMIT_GROUPS=""               # exact number
LIMIT_PERCENT=""              # percent of total groups
ORDER="largest"               # largest|report — default largest by potential reclaim
PLAN_FILE="$LOGS_DIR/review-dedupe-plan-$(date +%F)-$$.txt"

# Colors only if stdout is a TTY
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  CB="$(printf '\033[1m')"; CINFO="$(printf '\033[1;34m')"; COK="$(printf '\033[1;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[1;31m')"; C0="$(printf '\033[0m')"
else
  CB=""; CINFO=""; COK=""; CWARN=""; CERR=""; C0=""
fi

# ────────────────────────────── Helpers ─────────────────────────────
die() { echo "${CERR}[ERROR]${C0} $*" >&2; exit 1; }
info(){ echo "${CINFO}[INFO]${C0} $*"; }
ok()  { echo "${COK}[OK]${C0} $*"; }
warn(){ echo "${CWARN}[WARN]${C0} $*"; }

prompt_read() {
  _p="$1"; _def="${2-}"; _ans=""
  if [ -c /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s" "$_p" > /dev/tty
    IFS= read -r _ans < /dev/tty || _ans=""
  elif [ -t 0 ] && [ -t 1 ]; then
    printf "%s" "$_p"
    IFS= read -r _ans || _ans=""
  else
    warn "No interactive TTY available; aborting to avoid auto-planning."
    exit 0
  fi
  if [ -z "${_ans-}" ] && [ -n "${_def-}" ]; then
    printf "%s" "$_def"
  else
    printf "%s" "$_ans"
  fi
}

stat_mtime() {
  if command -v stat >/dev/null 2>&1; then
    if stat -c %Y "$1" >/dev/null 2>&1; then stat -c %Y "$1" && return 0; fi
    if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1" && return 0; fi
  fi
  if date -r "$1" +%s >/dev/null 2>&1; then date -r "$1" +%s && return 0; fi
  echo 0
}

stat_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then stat -c %s "$1" && return 0; fi
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1" && return 0; fi
  wc -c < "$1" 2>/dev/null || echo 0
}

human_size() {
  b="${1:-0}"
  awk 'BEGIN{
    b='"${b}"';
    if (b<1024) { printf "%d B", b; exit }
    if (b<1048576){ printf "%.1f KiB", b/1024; exit }
    if (b<1073741824){ printf "%.2f MiB", b/1048576; exit }
    printf "%.2f GiB", b/1073741824;
  }'
}

choose_default_keep() {
  policy="$1"; filelist="$2"; idx=1
  case "$policy" in
    first-seen) echo 1; return 0 ;;
    shortest-path)
      minlen=9999999; n=0
      while IFS= read -r p; do n=$((n+1)); l=${#p}; [ "$l" -lt "$minlen" ] && minlen="$l" && idx="$n"; done <"$filelist"
      echo "$idx" ;;
    longest-path)
      maxlen=0; n=0
      while IFS= read -r p; do n=$((n+1)); l=${#p}; [ "$l" -gt "$maxlen" ] && maxlen="$l" && idx="$n"; done <"$filelist"
      echo "$idx" ;;
    newest)
      max=0; n=0
      while IFS= read -r p; do n=$((n+1)); t=$(stat_mtime "$p" 2>/dev/null || echo 0); [ "$t" -gt "$max" ] && max="$t" && idx="$n"; done <"$filelist"
      echo "$idx" ;;
    oldest)
      min=9999999999; n=0
      while IFS= read -r p; do n=$((n+1)); t=$(stat_mtime "$p" 2>/dev/null || echo 0); [ "$t" -lt "$min" ] && min="$t" && idx="$n"; done <"$filelist"
      echo "$idx" ;;
    *) echo 1 ;;
  esac
}

# Build a hash→size map from the latest or same-day CSV
build_sizes_map() {
  csv="$1"; out="$2"
  awk -F'[,\t]' '
    NR==1 {
      ih=0; is=0;
      for (i=1;i<=NF;i++) {
        c=$i; gsub(/^"+|"+$/,"",c); c=tolower(c); gsub(/[[:space:]]/,"",c);
        if (c ~ /(^hash$|^digest$|^sha(1|256|512)$)/) ih=i;
        if (c ~ /(^size(_?bytes)?$|^bytes$|^filesize$|^size$)/) is=i;
      }
      next
    }
    {
      h=""; s="";
      if (ih) h=$ih;
      if (is) s=$is;
      if (h=="") for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-fA-F]{32,128}$/) { h=$i; break }
      if (s=="") { maxn=0; for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && ($i+0)>maxn) { maxn=$i+0 } s=maxn }
      if (h!="") if (!(h in seen)) { printf "%s\t%d\n", h, s+0; seen[h]=1 }
    }' "$csv" > "$out"
}

summarize_report_quick() {
  meta="$1"
  if [ -f "$meta" ]; then
    awk -F'\t' '
      { groups++; del += ($3-1); files += $3; reclaim += $1 }
      END {
        printf("[INFO] Summary: Groups: %d  | Duplicate files (deletable): %d  | Potential reclaim: %.2f GiB\n",
               groups, del, reclaim/1024/1024/1024);
        printf("[INFO] Scope hint: files-in-groups: %d | average files/group: %.2f\n",
               files, (groups?files/groups:0));
      }' "$meta"
  fi
}

show_help() {
  cat <<EOF
Usage: review-duplicates.sh [--from-report FILE] [--keep POLICY] [--limit N | --percent P] [--order MODE]

Options:
  --from-report FILE   Path to duplicate-hashes report (default: $REPORT_DEFAULT)
  --keep POLICY        newest|oldest|shortest-path|longest-path|first-seen (default: $KEEP_POLICY)
  --limit N            Review exactly N groups this pass
  --percent P          Review P% of groups (10/25/50/100)
  --order MODE         largest|report (default: largest by potential reclaim)
  -h, --help           Show this help

Output:
  Writes a delete plan (paths to remove) to:
    $PLAN_FILE
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --from-report) [ $# -ge 2 ] || die "Missing value for --from-report"; REPORT="$2"; shift 2;;
    --keep)        [ $# -ge 2 ] || die "Missing value for --keep";        KEEP_POLICY="$2"; shift 2;;
    --limit)       [ $# -ge 2 ] || die "Missing value for --limit";       LIMIT_GROUPS="$2"; shift 2;;
    --percent)     [ $# -ge 2 ] || die "Missing value for --percent";     LIMIT_PERCENT="$2"; shift 2;;
    --order)       [ $# -ge 2 ] || die "Missing value for --order";       ORDER="$2"; shift 2;;
    -h|--help) show_help; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[ -f "$REPORT" ] || die "Report not found: $REPORT"
info "Preparing interactive review…"
info "Using report: $REPORT"

# Pick a CSV for sizes (today's first, else latest)
CSV_CAND=""
for cand in "$HASHES_DIR/hasher-$(date +%F)-"*.csv "$HASHES_DIR/hasher-$(date +%F).csv"; do
  [ -f "$cand" ] && { CSV_CAND="$cand"; break; }
done
[ -n "$CSV_CAND" ] || CSV_CAND="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"

SIZES_MAP=""
if [ -n "${CSV_CAND:-}" ] && [ -f "$CSV_CAND" ]; then
  SIZES_MAP="$VAR_DIR/.hash_sizes.$$"
  build_sizes_map "$CSV_CAND" "$SIZES_MAP"
fi

# Build group cache and meta
GROUP_DIR="$VAR_DIR/review-groups-$$"
mkdir -p "$GROUP_DIR"
META="$GROUP_DIR/meta.tsv"             # reclaim_bytes \t hash \t count
: > "$META"

# Read report once; write each group's paths to $GROUP_DIR/<hash>.list and meta line
cur_hash=""; cur_list=""; cur_count=0
# helper to finalize a group
finalize_group() {
  [ -n "${cur_hash:-}" ] || return 0
  # compute size per file for this hash
  gsz=0
  if [ -n "${SIZES_MAP:-}" ] && [ -f "$SIZES_MAP" ]; then
    gsz="$(awk -v H="$cur_hash" '$1==H{print $2; found=1; exit} END{if(!found) print 0}' "$SIZES_MAP")"
  fi
  if [ "${gsz:-0}" -le 0 ]; then
    # fallback: stat first path
    firstp="$(sed -n '1p' "$cur_list" 2>/dev/null || true)"
    [ -n "${firstp:-}" ] && gsz="$(stat_size "$firstp")" || gsz=0
  fi
  # potential reclaim = size * (count-1)
  if [ "$cur_count" -ge 2 ] 2>/dev/null; then
    rec=$(( gsz * (cur_count - 1) ))
    printf "%s\t%s\t%s\n" "$rec" "$cur_hash" "$cur_count" >> "$META"
  fi
}

# parse the report
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HASH\ *)
      # end previous
      if [ -n "${cur_hash:-}" ]; then finalize_group; fi
      # start new
      cur_hash="$(printf "%s\n" "$line" | sed -n 's/^HASH \([0-9a-fA-F]\+\).*/\1/p')"
      cur_list="$GROUP_DIR/$cur_hash.list"
      : > "$cur_list"; cur_count=0
      ;;
    *)
      # trim leading space, accept only absolute paths
      t="$line"
      # drop leading spaces/tabs
      while [ -n "$t" ]; do case "$t" in " "* ) t="${t# }";; "	"*) t="${t#	}";; * ) break;; esac; done
      case "$t" in /*)
        printf "%s\n" "$t" >> "$cur_list"
        cur_count=$((cur_count+1))
        ;;
      esac
      ;;
  esac
done < "$REPORT"
# finalize last
if [ -n "${cur_hash:-}" ]; then finalize_group; fi

GROUPS_TOTAL=$(wc -l < "$META" 2>/dev/null | tr -d ' ' || echo 0)
info "Indexing duplicate groups…"
printf "[########################################] 100%%  Parsed %s groups\n" "$GROUPS_TOTAL"

# Summary
summarize_report_quick "$META"

# Determine limit
to_review=""
if [ -n "${LIMIT_GROUPS:-}" ]; then
  to_review="$LIMIT_GROUPS"
elif [ -n "${LIMIT_PERCENT:-}" ]; then
  P="$LIMIT_PERCENT"
  if [ "$P" -lt 1 ] 2>/dev/null || [ "$P" -gt 100 ] 2>/dev/null; then
    die "--percent must be 1..100"
  fi
  to_review=$(awk 'BEGIN{g='"$GROUPS_TOTAL"'; p='"$P"'; printf("%d", (g*p+99)/100)}')
else
  ans="$(prompt_read "How much to review this pass? Enter % (10/25/50/100) or exact group count (e.g. 500). [default: 10%] > " "")"
  case "$ans" in
    "") to_review=$(( (GROUPS_TOTAL*10 + 99)/100 )) ;;
    *% ) pct=$(echo "$ans" | tr -d '%'); to_review=$(awk 'BEGIN{g='"$GROUPS_TOTAL"'; p='"$pct"'; printf("%d", (g*p+99)/100)}');;
    *  ) to_review="$ans" ;;
  esac
fi
case "${to_review:-0}" in ''|*[!0-9]* ) to_review=0 ;; esac
[ "$to_review" -gt "$GROUPS_TOTAL" ] 2>/dev/null && to_review="$GROUPS_TOTAL"
[ "$to_review" -gt 0 ] 2>/dev/null || { warn "Nothing selected to review (groups total: $GROUPS_TOTAL). Exiting."; exit 0; }

info "Keep policy: $KEEP_POLICY"
: > "$PLAN_FILE"
REVIEWED=0
DELETED_CANDIDATES=0

# Decide order list
ORDER_FILE="$GROUP_DIR/order.tsv"
case "$ORDER" in
  largest) sort -nr -k1,1 "$META" > "$ORDER_FILE" ;;
  report)  cp "$META" "$ORDER_FILE" ;;
  *)       warn "Unknown --order '$ORDER', defaulting to 'largest'"; sort -nr -k1,1 "$META" > "$ORDER_FILE" ;;
esac

# Helper to print a group and prompt
print_group_and_prompt() {
  h="$1"; list="$2"; gsz="$3"
  TOTAL=$(wc -l <"$list" | tr -d ' ')
  [ "$TOTAL" -gt 0 ] || TOTAL=0
  reclaim=$(( gsz * (TOTAL>0 ? TOTAL-1 : 0) ))

  echo
  echo "- Group hash: $h  (N=$TOTAL)  (potential reclaim: $(human_size "$reclaim"))"

  def_keep=$(choose_default_keep "$KEEP_POLICY" "$list")

  i=0
  while IFS= read -r p; do
    i=$((i+1)); mark=" "; [ "$i" -eq "$def_keep" ] && mark="*"
    printf "  %d%s) %s\n" "$i" "$mark" "$p"
  done <"$list"

  echo "  Policy: $KEEP_POLICY  [* marks suggested keeper]"

  choice="$(prompt_read "  Action: (Enter=accept) [N=pick keep] [s=skip] [q=quit] > " "")"
  if [ -z "${choice:-}" ]; then
    choice="$def_keep"
  elif [ "$choice" = "s" ]; then
    echo "Skipped."; return 2
  elif [ "$choice" = "q" ]; then
    echo "Quitting."; return 3
  elif echo "$choice" | grep -Eq '^[0-9]+$'; then : ; else
    echo "Invalid input, using default $def_keep."; choice="$def_keep"
  fi

  i=0
  while IFS= read -r p; do
    i=$((i+1)); [ "$i" -eq "$choice" ] && continue
    printf "%s\n" "$p" >> "$PLAN_FILE"
    DELETED_CANDIDATES=$((DELETED_CANDIDATES+1))
  done <"$list"

  echo "→ Planned deletes added for group."
  return 0
}

# Iterate groups in chosen order (top N)
count=0
while IFS=$'\t' read -r rec_bytes h cnt || [ -n "$rec_bytes" ]; do
  count=$((count+1))
  [ "$count" -le "$to_review" ] || break
  list="$GROUP_DIR/$h.list"

  # size per file for display/reclaim
  gsz=0
  if [ -n "${SIZES_MAP:-}" ] && [ -f "$SIZES_MAP" ]; then
    gsz="$(awk -v H="$h" '$1==H{print $2; found=1; exit} END{if(!found) print 0}' "$SIZES_MAP")"
  fi
  if [ "${gsz:-0}" -le 0 ]; then
    firstp="$(sed -n '1p' "$list" 2>/dev/null || true)"
    [ -n "${firstp:-}" ] && gsz="$(stat_size "$firstp")" || gsz=0
  fi

  set +e; print_group_and_prompt "$h" "$list" "$gsz"; rc=$?; set -e
  case "$rc" in
    0) REVIEWED=$((REVIEWED+1)) ;;
    2) : ;;  # skipped
    3) ok "Plan written: $PLAN_FILE"; info "Reviewed groups: $REVIEWED / $to_review | Planned deletions: $DELETED_CANDIDATES"; rm -rf -- "$GROUP_DIR" "${SIZES_MAP:-}"; exit 0 ;;
  esac
done < "$ORDER_FILE"

ok "Plan written: $PLAN_FILE"
info "Reviewed groups: $REVIEWED / $to_review | Planned deletions: $DELETED_CANDIDATES"

# cleanup
rm -rf -- "$GROUP_DIR" "${SIZES_MAP:-}" 2>/dev/null || true
exit 0
