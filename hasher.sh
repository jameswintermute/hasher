#!/bin/bash
# ───── NAS File Hasher ─────
# Generates file hashes with optional multi-core parallelism.
# Supports background logging and nohup mode for Synology usability.

set -euo pipefail

# ───── Flags & Config ─────
HASHES_DIR="hashes"
LOGS_DIR="duplicate-hashes"
EXCLUSIONS_FILE="exclusions.txt"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"
BACKGROUND_LOG="hasher-logs.txt"
ZERO_LOG="$HASHES_DIR/zero-length-files-$DATE_TAG.csv"
ALGO="sha256"
PATHFILE=""
RUN_IN_BACKGROUND=false
RUN_WITH_NOHUP=false

# ───── Functions ─────
usage() {
    echo "Usage: $0 --pathfile <file> [--algo <sha256|sha1|md5>] [--background] [--nohup]"
    exit 1
}

hash_file() {
    local file="$1"
    case "$ALGO" in
        sha256) sha256sum "$file" | awk '{print $1}' ;;
        sha1)   sha1sum "$file"   | awk '{print $1}' ;;
        md5)    md5sum "$file"    | awk '{print $1}' ;;
    esac
}

log_progress() {
    local done=$1 total=$2
    local pct=$(( done * 100 / total ))
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $done / $total files ($pct%)" >> "$BACKGROUND_LOG"
}

# ───── Parse Args ─────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pathfile) PATHFILE="$2"; shift 2 ;;
        --algo) ALGO="$2"; shift 2 ;;
        --background) RUN_IN_BACKGROUND=true; shift ;;
        --nohup) RUN_WITH_NOHUP=true; shift ;;
        *) usage ;;
    esac
done

[[ -z "$PATHFILE" ]] && usage
[[ ! -f "$PATHFILE" ]] && { echo "Pathfile not found: $PATHFILE"; exit 1; }

mkdir -p "$HASHES_DIR" "$LOGS_DIR"

# ───── Nohup Mode ─────
if $RUN_WITH_NOHUP; then
    LOGFILE="hasher-nohup.log"
    echo "[INFO] Relaunching under nohup, output -> $LOGFILE"
    nohup "$0" --pathfile "$PATHFILE" --algo "$ALGO" ${RUN_IN_BACKGROUND:+--background} >"$LOGFILE" 2>&1 &
    PID=$!
    disown
    echo "[INFO] Hasher running in background (PID $PID). Check logs: $LOGFILE"
    exit 0
fi

# ───── Exclusions ─────
EXCLUDES=()
if [[ -f "$EXCLUSIONS_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && EXCLUDES+=("-not" "-path" "$line")
    done < "$EXCLUSIONS_FILE"
    echo "[INFO] Loaded ${#EXCLUDES[@]} exclusions from $EXCLUSIONS_FILE"
fi

# ───── Collect Files ─────
mapfile -t FILES < <(while IFS= read -r dir; do
    find "$dir" -type f "${EXCLUDES[@]}"
done < "$PATHFILE")

TOTAL=${#FILES[@]}
echo "[INFO] Using output file: $OUTPUT"
echo "[INFO] Zero-length files will be logged to: $ZERO_LOG"
echo "file,hash,size_MB" > "$OUTPUT"
echo "file" > "$ZERO_LOG"

# ───── Processing ─────
COUNT=0
for file in "${FILES[@]}"; do
    ((COUNT++))
    if [[ ! -s "$file" ]]; then
        echo "$file" >> "$ZERO_LOG"
        continue
    fi
    hash=$(hash_file "$file")
    size_mb=$(du -m "$file" | awk '{print $1}')
    echo "\"$file\",$hash,$size_mb" >> "$OUTPUT"
    if ! $RUN_IN_BACKGROUND; then
        echo -ne "\r[$COUNT / $TOTAL] Processing..."
    else
        if (( COUNT % 100 == 0 )); then
            log_progress "$COUNT" "$TOTAL"
        fi
    fi
done

# ───── Final Progress ─────
if $RUN_IN_BACKGROUND; then
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $TOTAL / $TOTAL files hashed (100%)" >> "$BACKGROUND_LOG"
else
    echo -e "\n[INFO] Hashing complete. Output -> $OUTPUT"
fi
