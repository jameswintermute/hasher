#!/bin/bash
# Deduplicate files based on a duplicate-hashes report.
# Default action: move redundant copies to a quarantine dir (safe).
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage: $0 --from-report <dup_report.txt> [--keep newest|oldest|shortestpath|largest|smallest]
          [--quarantine DIR] [--delete] [--force]

  --from-report FILE   Report like: "HASH <hex> (N files):" followed by indented file paths.
  --keep STRATEGY      Which file to keep per group. Default: newest
                       Options: newest | oldest | shortestpath | largest | smallest
  --quarantine DIR     Move redundant files here (default: quarantine-YYYY-MM-DD)
  --delete             Delete redundant files instead of moving (dangerous).
  --force              Execute changes (default is dry-run).

Examples:
  $0 --from-report logs/2025-08-29-duplicate-hashes.txt
  $0 --from-report logs/2025-08-29-duplicate-hashes.txt --keep shortestpath --force
  $0 --from-report logs/dup.txt --delete --force
EOF
}

REPORT=""
KEEP="newest"
DELETE=false
FORCE=false
QUARANTINE="quarantine-$(date +'%Y-%m-%d')"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-report) REPORT="$2"; shift ;;
    --keep) KEEP="$2"; shift ;;
    --quarantine) QUARANTINE="$2"; shift ;;
    --delete) DELETE=true ;;
    --force) FORCE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
  shift || true
done

[[ -f "$REPORT" ]] || { echo "[ERROR] Report not found: $REPORT"; exit 1; }
[[ "$DELETE" == true ]] || mkdir -p "$QUARANTINE"

# Parse report into groups
# Lines look like:
#   HASH <hex> (N files):
#     /path/one
#     /path/two
#     ...
declare -a GROUP
declare -i processed_groups=0 moved=0 skipped=0 deleted=0

flush_group() {
  local -a files=("${GROUP[@]}")
  [[ "${#files[@]}" -lt 2 ]] && return 0

  # pick keeper by strategy
  local keeper="${files[0]}"
  case "$KEEP" in
    newest)
      for f in "${files[@]}"; do
        [[ -e "$f" ]] || continue
        if [[ ! -e "$keeper" || "$f" -nt "$keeper" ]]; then keeper="$f"; fi
      done
      ;;
    oldest)
      for f in "${files[@]}"; do
        [[ -e "$f" ]] || continue
        if [[ ! -e "$keeper" || "$f" -ot "$keeper" ]]; then keeper="$f"; fi
      done
      ;;
    largest)
      local max=-1
      for f in "${files[@]}"; do
        [[ -e "$f" ]] || continue
        sz=$(stat -c%s -- "$f" 2>/dev/null || echo 0)
        if (( sz>max )); then max=$sz; keeper="$f"; fi
      done
      ;;
    smallest)
      local min=-1
      for f in "${files[@]}"; do
        [[ -e "$f" ]] || continue
        sz=$(stat -c%s -- "$f" 2>/dev/null || echo 0)
        if (( min<0 || sz<min )); then min=$sz; keeper="$f"; fi
      done
      ;;
    shortestpath)
      for f in "${files[@]}"; do
        [[ -e "$f" ]] || continue
        if [[ -z "$keeper" || "${#f}" -lt "${#keeper}" ]]; then keeper="$f"; fi
      done
      ;;
    *) echo "[WARN] Unknown --keep '$KEEP', defaulting to newest";;
  esac

  echo "[GROUP] Keeping: $keeper"
  for f in "${files[@]}"; do
    if [[ "$f" == "$keeper" ]]; then
      echo "  [KEEP] $f"
      continue
    fi
    if [[ ! -e "$f" ]]; then
      echo "  [MISS] $f"
      skipped=$((skipped+1))
      continue
    fi
    if [[ "$DELETE" == true ]]; then
      if [[ "$FORCE" == true ]]; then
        rm -f -- "$f"
        echo "  [DEL ] $f"
        deleted=$((deleted+1))
      else
        echo "  [DRY ] rm -f -- '$f'"
      fi
    else
      # move to quarantine preserving filename; dedupe name if exists
      base="$(basename "$f")"
      dest="$QUARANTINE/$base"
      idx=1
      while [[ -e "$dest" ]]; do
        dest="$QUARANTINE/${base}.$idx"
        idx=$((idx+1))
      done
      if [[ "$FORCE" == true ]]; then
        mkdir -p "$QUARANTINE"
        mv -- "$f" "$dest"
        echo "  [MOVE] $f -> $dest"
        moved=$((moved+1))
      else
        echo "  [DRY ] mv -- '$f' '$dest'"
      fi
    fi
  done
  processed_groups=$((processed_groups+1))
}

in_group=0
GROUP=()
while IFS= read -r line; do
  if [[ "$line" =~ ^HASH[[:space:]] ]]; then
    # new group starts — flush previous
    if (( in_group==1 )); then flush_group; fi
    in_group=1
    GROUP=()
    echo "$line"
  elif [[ "$line" =~ ^[[:space:]]+/.+ ]]; then
    # indented file path
    path="${line#"${line%%[![:space:]]*}"}" # trim leading spaces
    GROUP+=("$path")
  else
    # blank or other lines inside group boundaries are fine
    :
  fi
done < "$REPORT"
# flush last group
if (( in_group==1 )); then flush_group; fi

echo
echo "[INFO] Groups processed: $processed_groups | moved: $moved | deleted: $deleted | skipped: $skipped | Mode: $([[ "$FORCE" == true ]] && echo EXECUTE || echo DRY-RUN)"
