#!/bin/bash

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ───── Functions ─────
draw_progress_bar() {
    local current=$1
    local total=$2
    local width=40

    local percent=$(( current * 100 / total ))
    local filled=$(( width * current / total ))
    local empty=$(( width - filled ))

    local bar=""
    for ((i=0; i<filled; i++)); do bar+='#'; done
    for ((i=0; i<empty; i++)); do bar+='-'; done

    echo -ne "${YELLOW}[${bar}]${NC} $current / $total duplicate hashes processed (${percent}%)\r"
}

# ───── Select Hash File ─────
HASH_DIR="hashes"
if [ ! -d "$HASH_DIR" ]; then
    log_error "Directory '$HASH_DIR' does not exist."
    exit 1
fi

log_info "Scanning most recent hash files in '$HASH_DIR'..."
FILES=($(ls -t "$HASH_DIR"/hasher-*.txt 2>/dev/null | head -n 10))
if [ ${#FILES[@]} -eq 0 ]; then
    log_error "No hasher-*.txt files found in '$HASH_DIR'"
    exit 1
fi

echo ""
echo "Select a hash file to process:"
for i in "${!FILES[@]}"; do
    index=$((i + 1))
    filename=$(basename "${FILES[$i]}")
    echo "  [$index] $filename"
done
echo ""

read -p "Enter file number or filename: " selection

if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#FILES[@]} )); then
    INPUT_FILE="${FILES[$((selection - 1))]}"
elif [[ -f "$HASH_DIR/$selection" ]]; then
    INPUT_FILE="$HASH_DIR/$selection"
else
    log_error "Invalid selection. Exiting."
    exit 1
fi

log_info "Selected file: $(basename "$INPUT_FILE")"

# ───── Extract Duplicate Hashes ─────
log_info "Scanning for duplicate hashes... This may take a moment."
DUP_HASHES=$(cut -d',' -f1 "$INPUT_FILE" | sort | uniq -d)

if [[ -z "$DUP_HASHES" ]]; then
    log_info "No duplicate hashes found."
    exit 0
fi

# ───── Setup Output File ─────
DATE_TAG=$(basename "$INPUT_FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
OUTPUT_FILE="$HASH_DIR/${DATE_TAG}-duplicate-hashes.txt"
: > "$OUTPUT_FILE"

# ───── Process and Sort by File Count ─────
log_info "Calculating duplicate file groups..."

TMP_SORTED=$(mktemp)
while IFS= read -r hash; do
    count=$(grep -c "^$hash" "$INPUT_FILE")
    echo "$count,$hash" >> "$TMP_SORTED"
done <<< "$DUP_HASHES"

SORTED_HASHES=$(sort -t',' -k1,1nr "$TMP_SORTED" | cut -d',' -f2)
rm -f "$TMP_SORTED"

# ───── Display Progress with Progress Bar ─────
HASHES_ARRAY=($SORTED_HASHES)
TOTAL_HASHES=${#HASHES_ARRAY[@]}
COUNT=0

echo -e "\n${GREEN}[INFO]${NC} Processing ${TOTAL_HASHES} duplicate hash groups..."

for hash in "${HASHES_ARRAY[@]}"; do
    COUNT=$((COUNT + 1))
    draw_progress_bar "$COUNT" "$TOTAL_HASHES"

    echo "Duplicate hash ID: $COUNT" >> "$OUTPUT_FILE"
    echo "Duplicate hash: $hash" >> "$OUTPUT_FILE"
    grep "^$hash" "$INPUT_FILE" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    sleep 0.05  # Slow down for smoother visual
done

echo -e "\n${GREEN}[INFO]${NC} Done! Duplicate hashes written to: $OUTPUT_FILE"
