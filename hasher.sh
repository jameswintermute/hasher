#!/bin/bash
# hasher.sh - NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute
# Licensed under GNU GPL v3 (https://www.gnu.org/licenses/)
# Purpose: Generate file hashes on NAS systems efficiently

set -euo pipefail

# Default settings
ALGO="sha256"
PATHFILE=""
OUTPUT_DIR="hashes"
BACKGROUND=false
NOHUP_MODE=false

# Detect number of CPU cores
NUM_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo || echo 1)

# Help message
usage() {
    cat <<EOF
Usage: $0 --pathfile <file> [--algo sha256|md5|sha1] [--background|--nohup]

Options:
  --pathfile FILE      File containing directories/files to hash (required)
  --algo ALGO          Hash algorithm (default: sha256)
  --background         Run in background using & (simple)
  --nohup              Run in background with nohup (recommended for Synology DSM)
  -h, --help           Show this help
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pathfile) PATHFILE="$2"; shift 2;;
        --algo) ALGO="$2"; shift 2;;
        --background) BACKGROUND=true; shift;;
        --nohup) NOHUP_MODE=true; shift;;
        -h|--help) usage;;
        *) echo "Unknown option: $1"; usage;;
    esac
done

# Check required argument
if [[ -z "$PATHFILE" || ! -f "$PATHFILE" ]]; then
    echo "Error: --pathfile must point to a valid file."
    usage
fi

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Prepare output file
DATE_TAG=$(date +'%Y-%m-%d')
OUTPUT_FILE="$OUTPUT_DIR/hasher-$DATE_TAG.csv"
ZERO_FILE="$OUTPUT_DIR/zero-length-files-$DATE_TAG.csv"

# Hash function selection
hash_cmd() {
    case "$ALGO" in
        sha256) echo "sha256sum";;
        sha1)   echo "sha1sum";;
        md5)    echo "md5sum";;
        *)      echo "sha256sum";;
    esac
}

HASHER=$(hash_cmd)

# Function to hash a single file and append to CSV
hash_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then return; fi
    if [[ ! -s "$file" ]]; then
        echo "$file" >> "$ZERO_FILE"
        return
    fi
    HASH=$($HASHER "$file" | awk '{print $1}')
    echo "\"$file\",\"$HASH\"" >> "$OUTPUT_FILE"
}

export -f hash_file
export HASHER
export ZERO_FILE
export OUTPUT_FILE

# Determine parallel execution
if command -v parallel >/dev/null 2>&1; then
    USE_PARALLEL=true
else
    USE_PARALLEL=false
fi

# Prepare command to run
run_hashing() {
    mapfile -t FILES < <(xargs -a "$PATHFILE" -d '\n' -r find {} -type f 2>/dev/null)
    if [[ "$USE_PARALLEL" == true ]]; then
        printf "%s\n" "${FILES[@]}" | parallel -j "$NUM_CORES" hash_file {}
    else
        printf "%s\n" "${FILES[@]}" | xargs -n 1 -P "$NUM_CORES" -I {} bash -c 'hash_file "$@"' _ {}
    fi
}

# Run in background if requested
if [[ "$BACKGROUND" == true ]]; then
    run_hashing &
    echo "Hasher started in background (PID $!). Output: $OUTPUT_FILE"
    exit 0
elif [[ "$NOHUP_MODE" == true ]]; then
    nohup bash "$0" --pathfile "$PATHFILE" --algo "$ALGO" >/dev/null 2>&1 &
    echo "Hasher started with nohup (PID $!). Output: $OUTPUT_FILE"
    exit 0
fi

# Foreground run
echo "Starting hasher (foreground)..."
run_hashing
echo "Hashing complete. Output saved to $OUTPUT_FILE"
[[ -f "$ZERO_FILE" ]] && echo "Zero-length files logged to $ZERO_FILE"
