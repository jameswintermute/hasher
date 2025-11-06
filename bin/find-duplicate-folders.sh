#!/bin/sh
# find-duplicate-folders.sh — identify duplicate folders and write a plan
# POSIX / BusyBox sh compatible. No bashisms.
# Signature logic: for each directory, build a sorted list of "basename|hash|size".
# Directories with identical signatures are duplicates.
#
# Usage: find-duplicate-folders.sh --input <hashes.csv> [--mode plan] [--min-group-size N] [--keep POLICY]
#   -i, --input FILE         CSV/TSV with columns: path,size_bytes,algo,hash  (mtime optional)
#   -m, --mode MODE          Only 'plan' is supported [default: plan]
#   -g, --min-group-size N   Minimum duplicate dirs in a group [default: 2]
#   -k, --keep POLICY        shortest-path|longest-path|first-seen [default: shortest-path]
#   -s, --scope SCOPE        Informational label [default: recursive]
#   --signature SIG          Accepted for compatibility; currently fixed to name+content
#   -h, --help               Show help
set -eu

# layout
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LOGS_DIR="$ROOT_DIR/logs"; mkdir -p "$LOGS_DIR"
VAR_DIR="$ROOT_DIR/var";   mkdir -p "$VAR_DIR"

INPUT=""
MODE="plan"
MIN_GROUP=2
KEEP="shortest-path"
SCOPE="recursive"
SIGNATURE="name+content"   # printed for info only

# colors if tty
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
  CINFO="$(printf '\033[1;34m')"; COK="$(printf '\033[1;32m')"; CWARN="$(printf '\033[1;33m')"; CERR="$(printf '\033[1;31m')"; C0="$(printf '\033[0m')"
else
  CINFO=""; COK=""; CWARN=""; CERR=""; C0=""
fi

info(){ printf "%s[INFO]%s %s\n" "$CINFO" "$C0" "$*"; }
ok(){   printf "%s[OK]%s %s\n"   "$COK"   "$C0" "$*"; }
warn(){ printf "%s[WARN]%s %s\n" "$CWARN" "$C0" "$*"; }
err(){  printf "%s[ERROR]%s %s\n" "$CERR" "$C0" "$*"; }

usage(){
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)           INPUT="${2-}"; shift 2;;
    -m|--mode)            MODE="${2-}"; shift 2;;
    -g|--min-group-size)  MIN_GROUP="${2-}"; shift 2;;
    -k|--keep)            KEEP="${2-}"; shift 2;;
    -s|--scope)           SCOPE="${2-}"; shift 2;;
    --signature)          SIGNATURE="${2-}"; shift 2;; # accepted but not used; for CLI compatibility
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

[ -n "${INPUT:-}" ] || { err "Missing --input FILE"; usage; exit 2; }
[ -f "$INPUT" ] || { err "Input not found: $INPUT"; exit 2; }
case "$MODE" in plan) : ;; *) err "Only --mode plan is supported"; exit 2;; esac

DATE_TAG="$(date +%F)"
PLAN="$LOGS_DIR/duplicate-folders-plan-$DATE_TAG.txt"
TMP_BASE="$VAR_DIR/dupdirs.$$"
TMP_FILES="$TMP_BASE.files.tsv"     # dir \t basename \t hash \t size
TMP_SORTED="$TMP_BASE.sorted.tsv"   # sorted by dir, then basename/hash/size
TMP_SIGS="$TMP_BASE.sigs.tsv"       # signature_string \t dir
TMP_GROUPS="$TMP_BASE.groups.tsv"   # reclaim_bytes \t keep_dir \t delete_dir

trap 'rm -f -- "$TMP_FILES" "$TMP_SORTED" "$TMP_SIGS" "$TMP_GROUPS" 2>/dev/null || true' EXIT INT TERM

info "Input: $INPUT"
info "Mode: $MODE  | Min group size: $MIN_GROUP  | Scope: $SCOPE  | Keep: $KEEP  | Signature: $SIGNATURE"
info "Using size_bytes from CSV/TSV (fast path)."

# 1) explode CSV into (dir, basename, hash, size). Header-aware; supports 4 or 5 columns.
awk '
  function rsplit_commas(s,   n,pos,i){ n=0; pos=0; while ( (i=index(substr(s,pos+1),",")) > 0 ){ pos+=i; n++; c[n]=pos } return n }
  function unquote_path(p){ if (p ~ /^".*"$/){ sub(/^"/,"",p); sub(/"$/,"",p); gsub(/""/,"\"",p) } return p }
  BEGIN{ NRrec=0 }
  NR==1{
    line=$0; t=line; gsub(/[ \t\r\n]/,"",t);
    if (t ~ /^path,/i){ has_header=1; next } else { has_header=0 }
  }
  {
    s=$0; n=rsplit_commas(s);
    if (n<3) next;
    if (n>=4){
      c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n];
      path=substr(s,1,c1-1);
      size=substr(s,c1+1,c2-c1-1);
      hash=substr(s,c4+1);
    } else {
      c1=c[n-2]; c2=c[n-1]; c3=c[n];
      path=substr(s,1,c1-1);
      size=substr(s,c1+1,c2-c1-1);
      hash=substr(s,c3+1);
    }
    path=unquote_path(path);
    gsub(/^[ \t]+|[ \t]+$/,"",hash);
    gsub(/^[ \t]+|[ \t]+$/,"",size);
    # derive dir and basename
    p=path; lastslash=match(p,/[^/]*$/); base=substr(p,lastslash); dir=substr(p,1,lastslash-2);
    gsub(/\t/,"\\t",dir); gsub(/\n/," ",dir);
    gsub(/\t/,"\\t",base); gsub(/\n/," ",base);
    if (size ~ /^[0-9]+$/) ; else size=0;
    printf "%s\t%s\t%s\t%s\n", dir, base, hash, size;
    NRrec++;
  }
' "$INPUT" > "$TMP_FILES"

total_lines="$(wc -l < "$TMP_FILES" | tr -d ' ')"
info "[WORK] indexing files 100% ($total_lines/$total_lines)"
info "[WORK] Sorting index…"
LC_ALL=C sort -t '	' -k1,1 -k2,2 -k3,3 -k4,4 "$TMP_FILES" > "$TMP_SORTED"
ok "Sorting complete."

# 2) Build per-directory signature string
awk -F '	' '
  function flush_prev(){
    if (curdir!=""){
      printf("%s\t%s\n", sig, curdir);
    }
  }
  {
    d=$1; b=$2; h=$3; s=$4;
    if (d!=curdir){
      flush_prev();
      curdir=d; sig="";
    }
    if (sig=="") sig=b "|" h "|" s; else sig=sig "|" b "|" h "|" s;
  }
  END{ flush_prev() }
' "$TMP_SORTED" > "$TMP_SIGS"

# 3) dir -> total size
awk -F '	' '
  {
    d=$1; s=$4+0;
    if (d!=pd && pd!=""){ printf "%s\t%d\n", pd, sum; sum=0 }
    sum+=s; pd=d;
  }
  END{ if (pd!="") printf "%s\t%d\n", pd, sum }
' "$TMP_SORTED" > "$TMP_BASE.dirsize.tsv"

# 3a) join sigs with dir sizes
awk -F '	' '
  FNR==NR { sz[$1]=$2; next }
  { d=$2; printf "%s\t%s\t%d\n", $1, d, (d in sz ? sz[d] : 0) }
' "$TMP_BASE.dirsize.tsv" "$TMP_SIGS" > "$TMP_BASE.sig_dir_size.tsv"

# 4) group by signature
#    FIX 1: remove stray quote at the end of this pipeline
#    FIX 2 (small): print a progress line to stderr every ~2000 records
LC_ALL=C sort -t '	' -k1,1 -k2,2 "$TMP_BASE.sig_dir_size.tsv" | awk -F '	' -v MIN="$MIN_GROUP" -v KEEP="$KEEP" '
  function choose_keep_idx(n,     i, best, bestlen){
    if (KEEP=="shortest-path"){
      best=1; bestlen=length(dir[1]);
      for(i=2;i<=n;i++){ if (length(dir[i])<bestlen){ best=i; bestlen=length(dir[i]) } }
      return best;
    } else if (KEEP=="longest-path"){
      best=1; bestlen=length(dir[1]);
      for(i=2;i<=n;i++){ if (length(dir[i])>bestlen){ best=i; bestlen=length(dir[i]) } }
      return best;
    } else {
      return 1;
    }
  }
  function reset_group(){ gsig=""; n=0 }
  BEGIN{ reset_group() }
  {
    s=$1; d=$2; t=$3+0;

    # tiny progress
    if (NR % 2000 == 0) {
      printf "[PROGRESS] grouped %d entries…\n", NR > "/dev/stderr"
    }

    if (s!=gsig && gsig!=""){
      if (n>=MIN){
        keepi=choose_keep_idx(n);
        for(i=1;i<=n;i++){ if (i!=keepi) printf "%d\t%s\t%s\n", total[i], dir[keepi], dir[i] }
      }
      reset_group();
    }
    if (s!=gsig){ gsig=s }
    n++; dir[n]=d; total[n]=t;
  }
  END{
    if (n>=MIN){
      keepi=choose_keep_idx(n);
      for(i=1;i<=n;i++){ if (i!=keepi) printf "%d\t%s\t%s\n", total[i], dir[keepi], dir[i] }
    }
  }
' > "$TMP_GROUPS"

# 5) write plan
LC_ALL=C sort -nr -k1,1 "$TMP_GROUPS" > "$TMP_BASE.groups.sorted.tsv"

groups_count="$(wc -l < "$TMP_BASE.groups.sorted.tsv" | tr -d ' ')"
[ -n "$groups_count" ] || groups_count=0

: > "$PLAN"
while IFS='	' read -r sz keepdir deldir; do
  printf "%s\n" "$deldir" >> "$PLAN"
done < "$TMP_BASE.groups.sorted.tsv"

ok "Plan written: $PLAN"
exit 0
