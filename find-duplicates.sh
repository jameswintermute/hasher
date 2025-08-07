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

log_info "Calculating duplicate file groups... (this may take a moment)"

# Run heavy command in background
TMP_DUP_HASHES=$(mktemp)
(
    cut -d',' -f1 "$INPUT_FILE" | sort | uniq -d > "$TMP_DUP_HASHES"
) &
PID=$!

# Show progress dots every second with elapsed time
i=0
while kill -0 "$PID" 2>/dev/null; do
    sleep 1
    i=$((i+1))
    printf "."
    if [ $((i % 10)) -eq 0 ]; then
        printf " [%ds elapsed]\n" "$i"
    fi
done
echo ""
wait "$PID"

DUP_HASHES=$(cat "$TMP_DUP_HASHES")
rm -f "$TMP_DUP_HASHES"

if [[ -z "$DUP_HASHES" ]]; then
    log_info "No duplicate hashes found."
    exit 0
fi

log_info "Found $(echo "$DUP_HASHES" | wc -l) duplicate hash groups."

# ───── Step 2: Extract Matching Lines ─────
echo "" > "$OUTPUT_FILE"
group_id=1
for hash in $DUP_HASHES; do
    count=$(grep -c "^$hash" "$INPUT_FILE")
    echo "Duplicate hash ID: $group_id (files: $count)" >> "$OUTPUT_FILE"
    echo "Duplicate hash: $hash" >> "$OUTPUT_FILE"
    grep "^$hash" "$INPUT_FILE" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    ((group_id++))
done

log_info "Duplicate hashes with file paths saved to '$OUTPUT_FILE'"
