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

# ───── Step 1: Find Duplicate Hashes ─────
DUP_HASHES=$(cut -d',' -f1 "$INPUT_FILE" | sort | uniq -d)

if [[ -z "$DUP_HASHES" ]]; then
    log_info "No duplicate hashes found."
    exit 0
fi

# ───── Step 2: Extract Matching Lines ─────
echo "$DUP_HASHES" | while read -r hash; do
    echo "Duplicate hash: $hash" >> "$OUTPUT_FILE"
    grep "^$hash" "$INPUT_FILE" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
done

log_info "Duplicate hashes with file paths saved to '$OUTPUT_FILE'"
