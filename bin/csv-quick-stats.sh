#!/bin/sh
# csv-quick-stats.sh — sanity-check a Hasher CSV (header-aware, paths with commas OK)
# Prints: total records, unique paths, unique hashes (content), unique (basename+hash) keys.
# Usage: ./csv-quick-stats.sh hashes/hasher-YYYY-MM-DD.csv
set -eu

CSV="${1:-}"
[ -n "$CSV" ] || { echo "Usage: $0 FILE.csv" >&2; exit 2; }
[ -f "$CSV" ] || { echo "File not found: $CSV" >&2; exit 2; }

awk '
  BEGIN{
    FS=","; total=0
  }
  NR==1 { next }  # skip header if present
  {
    s=$0
    # find comma positions, regardless of quotes inside PATH; we will split from right
    n=0; pos=0
    while ( (i=index(substr(s,pos+1),",")) > 0 ) {
      pos += i; n++; c[n]=pos
    }
    if (n<3) next
    # handle 5 or 4 columns
    if (n>=4) {
      c1=c[n-3]; c2=c[n-2]; c3=c[n-1]; c4=c[n]
      path = substr(s,1,c1-1)
      size = substr(s,c1+1,c2-c1-1)
      algo = substr(s,c3+1,c4-c3-1)
      hash = substr(s,c4+1)
    } else { # n==3 : path,size,algo,hash (no mtime)
      c1=c[n-2]; c2=c[n-1]; c3=c[n]
      path = substr(s,1,c1-1)
      size = substr(s,c1+1,c2-c1-1)
      algo = substr(s,c2+1,c3-c2-1)
      hash = substr(s,c3+1)
    }
    # unquote path if quoted
    if (path ~ /^".*"$/) { sub(/^"/,"",path); sub(/"$/,"",path); gsub(/""/,"\"",path) }
    gsub(/^[ \t]+|[ \t]+$/,"",hash)

    # derive basename
    bp=path
    gsub(/\/+$/,"",bp)
    nbp=split(bp,arr,"/")
    base=arr[nbp]

    total++
    P[path]=1
    H[hash]=1
    NH[base "|" hash]=1

    # clear c[] for next record
    for (k=1;k<=n;k++) delete c[k]
  }
  END{
    up=0; for (k in P) up++
    uh=0; for (k in H) uh++
    unh=0; for (k in NH) unh++
    printf "CSV stats:\n"
    printf "  - records (NR-1): %d\n", total
    printf "  - unique paths:   %d\n", up
    printf "  - unique hashes:  %d\n", uh
    printf "  - name+content:   %d\n", unh
  }
' "$CSV"
