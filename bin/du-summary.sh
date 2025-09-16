#!/usr/bin/env bash
# du-summary.sh — print a concise summary after find-duplicates
# Minimal, self-contained helper. Call with:
#   ./bin/du-summary.sh "<OUTDIR>" "<INPUT_CSV>"
# Example:
#   ./bin/du-summary.sh "logs/du-2025-09-16-202246" "hashes/hasher-2025-09-15.csv"

set -Eeuo pipefail
IFS=$'\n\t'; LC_ALL=C

usage(){
  echo "Usage: $0 <OUTDIR> <INPUT_CSV>"
  echo "  OUTDIR: directory produced by find-duplicates.sh (contains groups.summary.txt, top-groups.txt, etc.)"
  echo "  INPUT_CSV: path to the hasher CSV used as input"
}

[ $# -eq 2 ] || { usage; exit 2; }

OUTDIR="$1"
INPUT_CSV="$2"

SUMMARY="$OUTDIR/groups.summary.txt"
TOP="$OUTDIR/top-groups.txt"
RECLAIM_FILE="$OUTDIR/reclaimable.txt"
DUP_CSV="$OUTDIR/duplicates.csv"
DUP_TXT="$OUTDIR/duplicates.txt"

_du_human() {
  # bytes → human readable
  awk -v b="${1:-0}" 'BEGIN{split("B,KB,MB,GB,TB,PB",u,","); s=0; while(b>=1024 && s<5){b/=1024;s++}
                       printf (s? "%.1f %s":"%d %s"), b, u[s+1]}'
}

groups=""; files_in_groups=""; reclaim_bytes=""; reclaim_h=""

# Prefer groups.summary.txt if present
if [ -r "$SUMMARY" ]; then
  groups="$(grep -Eo '[0-9]+' "$SUMMARY" | sed -n '1p')" || true
  files_in_groups="$(grep -Eo '[0-9]+' "$SUMMARY" | sed -n '2p')" || true
fi

# Reclaim: prefer reclaimable.txt (sum numeric tokens)
if [ -r "$RECLAIM_FILE" ]; then
  reclaim_bytes="$(grep -Eo '[0-9]+' "$RECLAIM_FILE" | awk '{s+=$1} END{print s+0}')"
fi

# Fallbacks if needed
if [ -z "${groups:-}" ] || [ -z "${files_in_groups:-}" ]; then
  if [ -r "$DUP_CSV" ]; then
    uniq_hashes="$(cut -d',' -f1 "$DUP_CSV" 2>/dev/null | sort -u | wc -l | tr -d ' ')" || uniq_hashes=""
    total_rows="$(wc -l < "$DUP_CSV" 2>/dev/null | tr -d ' ')" || total_rows=""
    [ -n "$uniq_hashes" ] && groups="$uniq_hashes"
    [ -n "$total_rows" ] && files_in_groups="$total_rows"
  elif [ -r "$DUP_TXT" ]; then
    groups="$(grep -c '^HASH ' "$DUP_TXT" 2>/dev/null || echo 0)"
    files_in_groups="$(grep -c '^[[:space:]]\{2\}.' "$DUP_TXT" 2>/dev/null || echo 0)"
  fi
fi

# Try to infer reclaim from top-groups if still unknown (best-effort)
if [ -z "${reclaim_bytes:-}" ] && [ -r "$TOP" ]; then
  reclaim_bytes="$(awk '
    function tobytes(v,u,  m){
      m["B"]=1; m["KB"]=1024; m["MB"]=1024^2; m["GB"]=1024^3; m["TB"]=1024^4; m["PB"]=1024^5;
      return int(v*m[u])
    }
    {
      for (i=1;i<=NF;i++){
        if ($i ~ /^~?[0-9.]+$/ && (i+1)<=NF && $(i+1) ~ /^(B|KB|MB|GB|TB|PB)$/){
          gsub("~","",$i); s+=$i; u=$(i+1); su[u]+= $i
        }
      }
    }
    END{
      if (su["GB"]>0) print tobytes(su["GB"],"GB");
      else if (su["MB"]>0) print tobytes(su["MB"],"MB");
      else if (su["TB"]>0) print tobytes(su["TB"],"TB");
      else if (su["KB"]>0) print tobytes(su["KB"],"KB");
      else if (su["PB"]>0) print tobytes(su["PB"],"PB");
      else print 0;
    }
  ' "$TOP")"
fi

[ -z "${groups:-}" ] && groups=0
[ -z "${files_in_groups:-}" ] && files_in_groups=0
[ -z "${reclaim_bytes:-}" ] && reclaim_bytes=0
reclaim_h="$(_du_human "$reclaim_bytes")"

echo
echo "Duplicate analysis complete ✅"
echo
printf "• Groups analysed:        %'d\n" "$groups" 2>/dev/null || echo "• Groups analysed:        $groups"
printf "• Files in duplicate sets: %'d\n" "$files_in_groups" 2>/dev/null || echo "• Files in duplicate sets: $files_in_groups"
echo "• Potential space to reclaim: $reclaim_h"
echo

if [ -r "$TOP" ]; then
  echo "Top hotspots (by total size):"
  head -n 3 "$TOP" | sed 's/^/  /'
  echo "  … see: $TOP"
  echo
fi

echo "Next steps:"
echo "  • Interactive review (recommended): Option 3 — “Review duplicates”"
echo "  • Dry-run delete:  ./bin/delete-duplicates.sh --from-plan "logs/review-dedupe-plan-YYYY-MM-DD-<RUN>.txt""
echo "  • Auto policy:     ./bin/review-duplicates.sh --from-report "<report>" --non-interactive --keep newest"
echo
