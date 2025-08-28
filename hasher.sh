#!/bin/sh
# hasher.sh – NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPL v3 (https://www.gnu.org/licenses/)

set -e

PATHFILE=""
ALGO="sha256"
BACKGROUND=false
NOHUP_MODE=false
HASH_DIR="hashes"
LOG_FILE="background.log"
PROGRESS_FILE="/tmp/hasher-progress.tmp"
NUM_CORES=1

usage() {
    echo "Usage: $0 --pathfile <file> --algo <algo> [--background] [--nohup]"
    echo "Options:"
    echo "  --pathfile FILE   File containing directories to hash"
    echo "  --algo ALGO       Hash algorithm (sha256, sha1, md5)"
    echo "  --background      Run in background"
    echo "  --nohup           Run with nohup (recommended on Synology DSM)"
    exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --pathfile) PATHFILE="$2"; shift 2;;
        --algo) ALGO="$2"; shift 2;;
        --background) BACKGROUND=true; shift;;
        --nohup) NOHUP_MODE=true; shift;;
        *) usage;;
    esac
done

if [ -z "$PATHFILE" ] || [ ! -f "$PATHFILE" ]; then
    echo "Error: --pathfile missing or file does not exist"
    exit 1
fi

mkdir -p "$HASH_DIR"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASH_DIR/hasher-$DATE_TAG.csv"
> "$PROGRESS_FILE"
echo "[INFO] Hasher started: $OUTPUT" >> "$LOG_FILE"

# Detect number of CPU cores
if command -v nproc >/dev/null 2>&1; then
    NUM_CORES=$(nproc)
elif [ -f /proc/cpuinfo ]; then
    NUM_CORES=$(grep -c '^processor' /proc/cpuinfo)
fi
NUM_CORES=$((NUM_CORES > 0 ? NUM_CORES : 1))

hash_file() {
    FILE="$1"
    if [ ! -f "$FILE" ]; then
        return
    fi

    SIZE=$(stat -c%s "$FILE")
    if [ "$SIZE" -eq 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S'),$FILE,zero-length" >> "$HASH_DIR/zero-length-files-$DATE_TAG.csv"
        echo "0" >> "$PROGRESS_FILE"
        return
    fi

    case "$ALGO" in
        sha256) HASH=$(sha256sum "$FILE" | awk '{print $1}') ;;
        sha1) HASH=$(sha1sum "$FILE" | awk '{print $1}') ;;
        md5) HASH=$(md5sum "$FILE" | awk '{print $1}') ;;
        *) HASH=$(sha256sum "$FILE" | awk '{print $1}') ;;
    esac
    echo "$(date +'%Y-%m-%d %H:%M:%S'),$FILE,$HASH" >> "$OUTPUT"
    echo "1" >> "$PROGRESS_FILE"
}

export -f hash_file
export HASH_DIR OUTPUT ALGO DATE_TAG PROGRESS_FILE

# Read all files from pathfile
FILES=$(while read -r dir; do find "$dir" -type f; done < "$PATHFILE")

# Multi-core execution
if command -v parallel >/dev/null 2>&1; then
    echo "[INFO] Using GNU parallel ($NUM_CORES cores)" >> "$LOG_FILE"
    echo "$FILES" | parallel -j "$NUM_CORES" hash_file {}
else
    echo "[INFO] Using xargs -P ($NUM_CORES cores)" >> "$LOG_FILE"
    echo "$FILES" | xargs -n 1 -P "$NUM_CORES" sh -c 'hash_file "$0"' 
fi &

PID=$!
if [ "$NOHUP_MODE" = true ]; then
    nohup sh -c "wait $PID" >/dev/null 2>&1 &
    echo "[INFO] Hasher started with nohup (PID $!)" >> "$LOG_FILE"
elif [ "$BACKGROUND" = true ]; then
    echo "[INFO] Hasher running in background (PID $PID)" >> "$LOG_FILE"
else
    # Foreground progress display
    TOTAL=$(echo "$FILES" | wc -l)
    while kill -0 "$PID" 2>/dev/null; do
        DONE=$(wc -l < "$PROGRESS_FILE")
        PCT=$((DONE * 100 / TOTAL))
        echo "[PROGRESS] $DONE / $TOTAL files hashed ($PCT%)" >> "$LOG_FILE"
        sleep 15
    done
fi

wait "$PID"
rm -f "$PROGRESS_FILE"
echo "[INFO] Hasher finished: $OUTPUT" >> "$LOG_FILE"
