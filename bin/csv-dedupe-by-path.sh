#!/bin/sh
# csv-dedupe-by-path.sh — make a header-aware, path-unique Hasher CSV.
# Keeps the newest (highest mtime_epoch) row per path when mtime available; otherwise keeps the last occurrence.
# Handles both 4-col (no mtime) and 5-col CSVs; preserves/creates header.
# Usage: csv-dedupe-by-path.sh INPUT.csv > OUTPUT.csv
set -eu
CSV="${1:-}"
[ -n "$CSV" ] || { echo "Usage: $0 INPUT.csv > OUTPUT.csv" >&2; exit 2; }
[ -f "$CSV" ] || { echo "File not found: $CSV" >&2; exit 2; }

awk '
  function right_split_commas(s,   n,pos,i){ # fills c[1..n] with comma positions
    n=0; pos=0;
    while ( (i=index(substr(s,pos+1),",")) > 0 ) { pos += i; n++; c[n]=pos }
    return n
  }
  function unquote_path(p){
    if (p ~ /^".*"$/){ sub(/^"/,"",p); sub(/"$/,"",p); gsub(/""/,"\"",p) }
    return p
  }
  BEGIN{ has_header=0 }
  NR==1{
    # try to detect a header
    t=$0; gsub(/[[:space:]]/,"",t);
    if (t ~ /^path,?size(_?bytes)?|^path,size/i || t ~ /^path,/i) {
      has_header=1; header=$0; next
    }
  }
  {
    s=$0
    n=right_split_commas(s)
    if (n<3){ next }
    if (n>=4){
      c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
      path = substr(s,1,c1-1)
      size = substr(s,c1+1,c2-c1-1)
      mtime= substr(s,c2+1,c3-c2-1)
      algo = substr(s,c3+1,c4-c3-1)
      hash = substr(s,c4+1)
    } else {
      c1=c[n-2]; c2=c[n-1]; c3=c[n]
      path = substr(s,1,c1-1)
      size = substr(s,c1+1,c2-c1-1)
      mtime=""
      algo = substr(s,c2+1,c3-c2-1)
      hash = substr(s,c3+1)
    }
    path = unquote_path(path)
    gsub(/^[ \t]+|[ \t]+$/,"",mtime)

    # prefer highest mtime; if missing, keep the last occurrence
    if (!(path in keep_line)) { keep_line[path]=s; keep_mtime[path]=(mtime==""?0:mtime)+0; next }
    if (mtime != "" && (mtime+0) >= keep_mtime[path]) { keep_line[path]=s; keep_mtime[path]=mtime+0; next }
    # else keep existing
  }
  END{
    # emit header
    if (has_header) {
      print header
    } else {
      print "path,size_bytes,mtime_epoch,algo,hash"
    }
    for (p in keep_line) print keep_line[p]
  }
' "$CSV"
