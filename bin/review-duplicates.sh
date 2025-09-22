#!/bin/sh
# review-duplicates.sh — Interactive review of duplicate hash groups
# BusyBox/POSIX sh compatible. No bashisms.
# Accurately computes reclaim using the hashes CSV by detecting header columns.
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
ORDER="report"                # compatibility only; not altering order yet
PLAN_FILE="$LOGS_DIR/review-dedupe-plan-$(date +%F)-$$.txt"

# Colors only if stdout is a TTY
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  CINFO="$(printf '\033[1;34m')"; COK="$(printf '\033[1;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[1;31m')"; C0="$(printf '\033[0m')"
else
  CINFO=""; COK=""; CWARN=""; CERR=""; C0=""
fi

# ────────────────────────────── Helpers ─────────────────────────────
die() { echo "${CERR}[ERROR]${C0} $*" >&2; exit 1; }
info(){ echo "${CINFO}[INFO]${C0} $*"; }
ok()  { echo "${COK}[OK]${C0} $*"; }
warn(){ echo "${CWARN}[WARN]${C0} $*"; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }

stat_mtime() {
  # epoch seconds for keep=newest/oldest
  if command -v stat >/dev/null 2>&1; then
    if stat -c %Y "$1" >/dev/null 2>&1; then stat -c %Y "$1" && return 0; fi
    if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1" && return 0; fi
  fi
  if date -r "$1" +%s >/dev/null 2>&1; then date -r "$1" +%s && return 0; fi
  echo 0
}

human_gib() { awk 'BEGIN{b='"${1:-0}"'; printf "%.2f", (b/1024/1024/1024)}'; }

choose_default_keep() {
  # args: policy filelist_tmp -> prints 1-based index
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

# Header-aware size map builder: CSV -> "hash<TAB>size_bytes"
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
      if (h=="" || s=="") {
        # Heuristics: pick a hash-looking field + a numeric field
        # (prefer the largest numeric as size_bytes)
        if (h=="") {
          for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-fA-F]{32,128}$/) { h=$i; break }
        }
        if (s=="") {
          maxn=0
          for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && ($i+0)>maxn) { maxn=$i+0 }
          s=maxn
        }
      }
      if (h!="") {
        if (!(h in seen)) { printf "%s\t%d\n", h, s+0; seen[h]=1 }
      }
    }' "$csv" > "$out"
}

# ── Accurate summary using CSV sizes by hash (fallback stats once per group) ──
summarize_report() {
  rpt="$1"

  # Prefer today's CSV; else latest in hashes/
  csv="$HASHES_DIR/hasher-$(date +%F).csv"
  if [ ! -f "$csv" ]; then
    csv="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
  fi

  if [ -n "${csv:-}" ] && [ -f "$csv" ]; then
    awk -F'[,\t]' -v rpt="$rpt" '
      FNR==1 {
        # Detect header columns once
        ih=0; is=0;
        for (i=1;i<=NF;i++) {
          c=$i; gsub(/^"+|"+$/,"",c); c=tolower(c); gsub(/[[:space:]]/,"",c);
          if (c ~ /(^hash$|^digest$|^sha(1|256|512)$)/) ih=i;
          if (c ~ /(^size(_?bytes)?$|^bytes$|^filesize$|^size$)/) is=i;
        }
        next
      }
      FNR>1 && FILENAME!=rpt {
        # Pass 1: CSV rows -> sz[hash]=size_bytes
        h=""; s="";
        if (ih) h=$ih;
        if (is) s=$is;
        if (h=="" || s=="") {
          # Heuristics fallback
          if (h=="") { for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-fA-F]{32,128}$/) { h=$i; break } }
          if (s=="") {
            maxn=0; for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && ($i+0)>maxn) { maxn=$i+0 }
            s=maxn
          }
        }
        if (h!="") sz[h]=s+0
        next
      }
      # Pass 2: report
      FILENAME==rpt && /^HASH / {
        if (seen) { recl+=s*(n-1); del+=n-1; files+=n; groups++ }
        seen=1; n=0; s=0
        if (match($0,/^HASH ([0-9a-fA-F]+)/,m)) { h=m[1]; if (h in sz) s=sz[h]; }
        next
      }
      FILENAME==rpt && /^[[:space:]]*\/[^\r\n]*/ { n++; next }
      END {
        if (seen) { recl+=s*(n-1); del+=n-1; files+=n; groups++ }
        printf("[INFO] Summary: Groups: %d  | Duplicate files (deletable): %d  | Potential reclaim: %.2f GiB\n",
               groups, del, recl/1024/1024/1024);
        printf("[INFO] Scope hint: files-in-groups: %d | average files/group: %.2f\n",
               files, (groups?files/groups:0));
      }' "$csv" "$rpt"
  else
    # No CSV: stat first file per group once
    awk '
      function stat_size(p,  cmd,s){
        cmd="stat -c %s \"" p "\" 2>/dev/null"; cmd|getline s; close(cmd);
        if(s==""){cmd="stat -f %z \"" p "\" 2>/dev/null"; cmd|getline s; close(cmd);}
        if(s==""){cmd="wc -c <\"" p "\" 2>/dev/null"; cmd|getline s; close(cmd);}
        return s+0
      }
      /^HASH / {
        if (seen) { recl+=sz*(n-1); del+=n-1; files+=n; groups++ }
        seen=1; n=0; sz=0; first=1; next
      }
      /^[[:space:]]*\/[^\r\n]*/ {
        n++
        if (first){ p=$0; sub(/^[[:space:]]+/,"",p); sz=stat_size(p); first=0 }
        next
      }
      END {
        if (seen) { recl+=sz*(n-1); del+=n-1; files+=n; groups++ }
        printf("[INFO] Summary: Groups: %d  | Duplicate files (deletable): %d  | Potential reclaim: %.2f GiB\n",
               groups, del, recl/1024/1024/1024);
        printf("[INFO] Scope hint: files-in-groups: %d | average files/group: %.2f\n",
               files, (groups?files/groups:0));
      }' "$rpt"
  fi
}

# ────────────────────────────── CLI ─────────────────────────────────
show_help() {
  cat <<EOF
Usage: review-duplicates.sh [--from-report FILE] [--keep POLICY] [--limit N | --percent P] [--order MODE]

Options:
  --from-report FILE   Path to duplicate-hashes report (default: $REPORT_DEFAULT)
  --keep POLICY        newest|oldest|shortest-path|longest-path|first-seen (default: $KEEP_POLICY)
  --limit N            Review exactly N groups this pass
  --percent P          Review P% of groups (10/25/50/100)
  --order MODE         Accepted for compatibility (currently uses report order)
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
    --order)       [ $# -ge 2 ] || die "Missing value for --order";       ORDER="$2"; shift 2;; # compatibility
    -h|--help) show_help; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[ -f "$REPORT" ] || die "Report not found: $REPORT"
info "Preparing interactive review…"
info "Using report: $REPORT"
info "Indexing duplicate groups…"
printf "[########################################] 100%%  Parsing groups…\n"

# accurate summary
summarize_report "$REPORT"

GROUPS_TOTAL=$(grep -c '^HASH ' "$REPORT" || true)
[ -n "$GROUPS_TOTAL" ] || GROUPS_TOTAL=0

# Determine limit
to_review=""
if [ -n "${LIMIT_GROUPS:-}" ]; then
  to_review="$LIMIT_GROUPS"
elif [ -n "${LIMIT_PERCENT:-}" ]; then
  P="$LIMIT_PERCENT"
  if [ "$P" -lt 1 ] 2>/dev/null || [ "$P" -gt 100 ] 2>/dev/null; then die "--percent must be 1..100"; fi
  to_review=$(awk 'BEGIN{g='"$GROUPS_TOTAL"'; p='"$P"'; printf("%d", (g*p+99)/100)}')
elif is_tty; then
  printf "How much to review this pass? Enter %% (10/25/50/100) or exact group count (e.g. 500). [default: 10%%] > "
  read -r ans || ans=""
  case "$ans" in
    "") to_review=$(( (GROUPS_TOTAL*10 + 99)/100 )) ;;
    *%) pct=$(echo "$ans" | tr -d '%'); to_review=$(awk 'BEGIN{g='"$GROUPS_TOTAL"'; p='"$pct"'; printf("%d", (g*p+99)/100)}');;
    *)  to_review="$ans" ;;
  esac
else
  to_review=$(( (GROUPS_TOTAL*10 + 99)/100 ))
fi

case "${to_review:-0}" in ''|*[!0-9]* ) to_review=0 ;; esac
[ "$to_review" -gt "$GROUPS_TOTAL" ] 2>/dev/null && to_review="$GROUPS_TOTAL"
[ "$to_review" -gt 0 ] 2>/dev/null || { warn "Nothing selected to review (groups total: $GROUPS_TOTAL). Exiting."; exit 0; }

info "Keep policy: $KEEP_POLICY"
: > "$PLAN_FILE"
REVIEWED=0
DELETED_CANDIDATES=0

# Build a header-aware hash->size map for per-group display
CSV_CAND="$HASHES_DIR/hasher-$(date +%F).csv"
if [ ! -f "$CSV_CAND" ]; then
  CSV_CAND="$(ls -1t "$HASHES_DIR"/hasher-*.csv 2>/dev/null | head -n1 || true)"
fi
SIZES_MAP=""
if [ -n "${CSV_CAND:-}" ] && [ -f "$CSV_CAND" ]; then
  SIZES_MAP="$VAR_DIR/.hash_sizes.$$"
  build_sizes_map "$CSV_CAND" "$SIZES_MAP"
fi

# Iterate groups
TMP_LIST="$VAR_DIR/.group_paths.$$"; : > "$TMP_LIST"
CUR_HASH=""; CUR_IDX=0

print_group_and_prompt() {
  idx="$1"; h="$2"; list="$3"
  gsz=0
  if [ -n "${SIZES_MAP:-}" ] && [ -f "$SIZES_MAP" ]; then
    gsz=$(awk -v H="$h" 'BEGIN{sz=0} $1==H{sz=$2} END{print sz+0}' "$SIZES_MAP")
  fi
  def_keep=$(choose_default_keep "$KEEP_POLICY" "$list")
  echo
  echo "Group $idx/$GROUPS_TOTAL — HASH $h  (files: $(wc -l <"$list" | tr -d ' '))  size: $(human_gib "$gsz") GiB  [policy: $KEEP_POLICY → keep #$def_keep]"
  i=0; shown=0
  while IFS= read -r p; do
    i=$((i+1)); mark=" "; [ "$i" -eq "$def_keep" ] && mark="*"
    printf "  %2d%s %s\n" "$i" "$mark" "$p"
    shown=$((shown+1)); [ "$shown" -ge 12 ] && break
  done <"$list"
  TOTAL=$(wc -l <"$list" | tr -d ' ')
  [ "$TOTAL" -gt 12 ] && echo "  … and $((TOTAL-12)) more"
  if is_tty; then
    printf "Choose number to KEEP, Enter=accept default, s=skip, q=quit > "
    read -r choice || choice=""
  else
    choice=""
  fi
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
  echo "→ Planned deletes added for group."; return 0
}

process_group() {
  [ -n "${CUR_HASH:-}" ] || return 0
  COUNT=$(wc -l <"$TMP_LIST" | tr -d ' ')
  [ "$COUNT" -ge 2 ] || { : > "$TMP_LIST"; CUR_HASH=""; return 0; }
  CUR_IDX=$((CUR_IDX+1))
  if [ "$CUR_IDX" -le "$to_review" ]; then
    set +e; print_group_and_prompt "$CUR_IDX" "$CUR_HASH" "$TMP_LIST"; rc=$?; set -e
    case "$rc" in
      0) REVIEWED=$((REVIEWED+1)) ;;
      2) : ;;
      3) rm -f "$TMP_LIST" "${SIZES_MAP:-}"; ok "Plan written: $PLAN_FILE"; info "Reviewed groups: $REVIEWED / $to_review | Planned deletions: $DELETED_CANDIDATES"; exit 0 ;;
    esac
  fi
  : > "$TMP_LIST"; CUR_HASH=""
}

# Stream the report and handle groups
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HASH\ *)
      process_group
      CUR_HASH=$(printf "%s\n" "$line" | sed -n 's/^HASH \([0-9a-fA-F]\+\).*/\1/p')
      : > "$TMP_LIST"
      ;;
    /*)  printf "%s\n" "$line" >> "$TMP_LIST" ;;                     # paths starting at column 1
    [[:space:]]/*)
      p="$line"; p="${p#"${p%%[![:space:]]*}"}"; printf "%s\n" "$p" >> "$TMP_LIST" ;;  # indented paths
    *) : ;;
  esac
done <"$REPORT"

process_group
rm -f "$TMP_LIST" "${SIZES_MAP:-}"
ok "Plan written: $PLAN_FILE"
info "Reviewed groups: $REVIEWED / $to_review | Planned deletions: $DELETED_CANDIDATES"
exit 0
