#!/bin/bash

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Usage ─────
if [ $# -ne 1 ]; then
    echo -e "${YELLOW}Usage:${NC} $0 <hasher_output_file>"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="duplicates-hashes.txt"

# ───── Check File ─────
if [ ! -f "$INPUT_FILE" ]; then
    log_error "File '$INPUT_FILE' does not exist."
    exit 1
fi

log_info "Finding duplicate hashes..."

# ───── Step 1: Find all duplicate hashes with counts ─────
# Format: <count> <hash>
DUP_HASHES_WITH_COUNTS=$(cut -d',' -f1 "$INPUT_FILE" | sort | uniq -c | awk '$1 > 1' | sort -nr)

if [[ -z "$DUP_HASHES_WITH_COUNTS" ]]; then
    log_info "No duplicate hashes found."
    exit 0
fi

# ───── Step 2: Output duplicate hash groups with file count ─────
echo "" > "$OUTPUT_FILE"
ID=1

while read -r COUNT HASH; do
    echo "# Duplicate hash ID: $ID" >> "$OUTPUT_FILE"
    echo "# Count: $COUNT duplicate files" >> "$OUTPUT_FILE"
    echo "Duplicate hash: $HASH" >> "$OUTPUT_FILE"
    grep "^$HASH," "$INPUT_FILE" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    ID=$((ID + 1))
done <<< "$DUP_HASHES_WITH_COUNTS"

log_info "Duplicate hashes with file paths saved to '$OUTPUT_FILE'"
