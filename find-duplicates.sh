#!/bin/bash

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Step 1: List files in /hashes/ ─────
HASH_DIR="hashes"

if [ ! -d "$HASH_DIR" ]; then
    log_error "'$HASH_DIR' directory not found!"
    exit 1
fi

HASH_FILES=("$HASH_DIR"/*)
NUM_FILES=${#HASH_FILES[@]}

if [ "$NUM_FILES" -eq 0 ]; then
    log_error "No hasher output files found in '$HASH_DIR'."
    exit 1
fi

echo -e "${BLUE}Available hasher output files in /hashes/:${NC}"
for i in "${!HASH_FILES[@]}"; do
    fname=$(basename "${HASH_FILES[$i]}")
    echo -e "  [$((i+1))] $fname"
done

echo
read -rp "$(echo -e "${YELLOW}Enter number (1-$NUM_FILES) or full filename:${NC} ")" INPUT

# ───── Step 2: Resolve file choice ─────
if [[ "$INPUT" =~ ^[0-9]+$ ]] && (( INPUT >= 1 && INPUT <= NUM_FILES )); then
    INPUT_FILE="${HASH_FILES[$((INPUT-1))]}"
else
    INPUT_FILE="$HASH_DIR/$INPUT"
fi

if [ ! -f "$INPUT_FILE" ]; then
    log_error "File not found: $INPUT_FILE"
    exit 1
fi

# ───── Step 3: Prepare Output ─────
DATE_TAG=$(basename "$INPUT_FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
OUTPUT_FILE="${DATE_TAG}-duplicate-hashes.txt"
TMP_HASHES_FILE=$(mktemp)

# ───── Step 4: Identify Duplicate Hashes ─────
cut -d',' -f1 "$INPUT_FILE" | sort | uniq -d > "$TMP_HASHES_FILE"

TOTAL_HASHES=$(wc -l < "$TMP_HASHES_FILE")
if [ "$TOTAL_HASHES" -eq 0 ]; then
    log_info "No duplicate hashes found."
    rm -f "$TMP_HASHES_FILE"
    exit 0
fi

# ───── Step 5: Count Duplicates per Hash ─────
declare -A HASH_COUNTS
while read -r hash; do
    count=$(grep -c "^$hash" "$INPUT_FILE")
    HASH_COUNTS["$hash"]=$count
done < "$TMP_HASHES_FILE"

# ───── Step 6: Sort by Count Descending ─────
SORTED_HASHES=$(for hash in "${!HASH_COUNTS[@]}"; do
    echo "${HASH_COUNTS[$hash]} $hash"
done | sort -nr | awk '{print $2}')

# ───── Step 7: Write Duplicates with Progress ─────
echo -e "${GREEN}[INFO]${NC} Writing duplicates to '$OUTPUT_FILE'..."
echo "" > "$OUTPUT_FILE"

i=0
for hash in $SORTED_HASHES; do
    ((i++))
    count=${HASH_COUNTS[$hash]}

    echo "" >> "$OUTPUT_FILE"
    echo "# Duplicate hash ID: $i (${count} copies)" >> "$OUTPUT_FILE"
    echo "Duplicate hash: $hash" >> "$OUTPUT_FILE"

    grep "^$hash" "$INPUT_FILE" >> "$OUTPUT_FILE"

    percent=$(( i * 100 / TOTAL_HASHES ))
    echo -ne "${BLUE}[Progress]${NC} $i / $TOTAL_HASHES duplicate sets processed ($percent%)...\r"
done

echo ""
log_info "Duplicates written to: $OUTPUT_FILE"
rm -f "$TMP_HASHES_FILE"
