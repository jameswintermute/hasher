#!/bin/bash
# Hasher — NAS File Hasher & Duplicate Finder
# Copyright (C) 2025 James Wintermute <jameswinter@protonmail.ch>
# Licensed under GNU GPLv3 (https://www.gnu.org/licenses/)
# This program comes with ABSOLUTELY NO WARRANTY.

# ───── Flags & Config ─────
HASHES_DIR="hashes"
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"
ZERO_LENGTH="$HASHES_DIR/zero-length-files-$DATE_TAG.csv"
BACKGROUND=false
NOHUP_MODE=false
ALGO="sha256"
PATHFILE=""

# ───── Functions ─────
usage() {
    echo "Usage: $0 --pathfile <file> [--algo <sha256|sha1|md5>] [--background] [--nohup]"
    exit 1
}

log_zero_length() {
    echo "$1" >> "$ZERO_LENGTH"
}

hash_file() {
    local file="$1"
    if [ ! -s "$file" ]; then
        log_zero_length "$file"
        return
    fi

    case "$ALGO" in
        sha256) shasum -a 256 "$file" | awk '{print $1}';;
        sha1) shasum -a 1 "$file" | awk '{print $1}';;
        md5) md5sum "$file" | awk '{print $1}';;
        *) echo "Unsupported algorithm: $ALGO"; exit 1;;
    esac
}

process_paths() {
    mkdir -p "$HASHES_DIR"
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        [ ! -f "$path" ] && continue
        hash=$(hash_file "$path")
        echo "$path,$hash" >> "$OUTPUT"
    done < "$PATHFILE"
}

# ───── Argument Parsing ─────
while [ $# -gt 0 ]; do
    case "$1" in
        --pathfile) PATHFILE="$2"; shift 2;;
        --algo) ALGO="$2"; shift 2;;
        --background) BACKGROUND=true; shift;;
        --nohup) NOHUP_MODE=true; shift;;
        -h|--help) usage;;
        *) echo "Unknown option: $1"; usage;;
    esac
done

[ -z "$PATHFILE" ] && usage

# ───── Execution ─────
if [ "$NOHUP_MODE" = true ]; then
    mkdir -p "$HASHES_DIR"
    nohup "$0" --pathfile "$PATHFILE" --algo "$ALGO" > "$HASHES_DIR/background.log" 2>&1 &
    echo "Hasher running in nohup background mode. Output log: $HASHES_DIR/background.log"
    exit 0
fi

if [ "$BACKGROUND" = true ]; then
    mkdir -p "$HASHES_DIR"
    "$0" --pathfile "$PATHFILE" --algo "$ALGO" --nohup > "$HASHES_DIR/background.log" 2>&1 &
    echo "Hasher running in background mode. Output log: $HASHES_DIR/background.log"
    exit 0
fi

echo "Hasher starting..."
process_paths
echo "Hasher finished. Hash CSV: $OUTPUT"
[ -f "$ZERO_LENGTH" ] && echo "Zero-length files logged: $ZERO_LENGTH"
