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

# ───── Usage ─────
usage() {
    echo "Usage: $0 [-q]"
    echo "  -q    Quiet mode: disable progress bar and ETA output"
    exit 1
}

# ───── Globals ─────
QUIET=0
UPDATE_INTERVAL=5    # seconds between intermediate summary updates

while getopts "q" opt; do
    case $opt in
        q) QUIET=1 ;;
        *) usage ;;
    esac
done

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

format_seconds() {
    local T=$1
    local H=$((T/3600))
    local M=$(((T%3600)/60))
    local S=$((T%60))
    printf "%02d:%02d:%02d" $H $M $S
}

print_summary() {
    local processed=$1
    local total=$2
    local elapsed=$3
    local dup_files=$4

    echo -e "\n${GREEN}[INFO]${NC} Processed $processed / $total duplicate hash groups."
    echo -e "[INFO] Elapsed time: $(format_seconds $elapsed)"
    if (( processed > 0 )); then
        local avg=$((elapsed / processed))
        local remaining=$((avg * (total - processed)))
        echo -e "[INFO] Estimated time remaining: $(format_seconds $remaining)"
    fi
    echo -e "[INFO] Total duplicate files found so far: $dup_files"
    echo ""
}

# ───── Select Hash File ─────
shift $((OPTIND-1))

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

HASHES_ARRAY=($SORTED_HASHES)
TOTAL_HASHES=${#HASHES_ARRAY[@]}
COUNT=0
TOTAL_DUP_FILES=0
START_TIME=$(date +%s)
LAST_UPDATE=$START_TIME

# ───── Write initial comment header to output file — will update later ─────
{
    echo "# Duplicate hashes output file generated from $INPUT_FILE"
    echo "# Processing started: $(date +"%Y-%m-%d %H:%M:%S")"
    echo "# Total duplicate hash groups to process: $TOTAL_HASHES"
    echo "#"
    echo "# Summary (to be updated after processing):"
    echo "# Total duplicate hashes: N/A"
    echo "# Total duplicate files: N/A"
    echo ""
} >> "$OUTPUT_FILE"

log_info "Starting processing ${TOTAL_HASHES} duplicate hash groups..."

for hash in "${HASHES_ARRAY[@]}"; do
    COUNT=$((COUNT + 1))
    dup_count=$(grep -c "^$hash" "$INPUT_FILE")
    TOTAL_DUP_FILES=$((TOTAL_DUP_FILES + dup_count))

    # Draw progress and ETA if not quiet
    if (( QUIET == 0 )); then
        NOW_TIME=$(date +%s)
        ELAPSED=$(( NOW_TIME - START_TIME ))
        AVG_PER_HASH=$(( ELAPSED / COUNT ))
        REMAINING=$(( AVG_PER_HASH * (TOTAL_HASHES - COUNT) ))

        draw_progress_bar "$COUNT" "$TOTAL_HASHES"
        echo -ne " ETA ~$(format_seconds $REMAINING)   "
    fi

    # Append duplicate group info
    {
        echo "Duplicate hash ID: $COUNT"
        echo "Duplicate hash: $hash"
        grep "^$hash" "$INPUT_FILE"
        echo ""
    } >> "$OUTPUT_FILE"

    # Periodic intermediate summary every $UPDATE_INTERVAL seconds
    if (( QUIET == 0 )); then
        NOW_TIME=$(date +%s)
        if (( NOW_TIME - LAST_UPDATE >= UPDATE_INTERVAL )); then
            ELAPSED=$(( NOW_TIME - START_TIME ))
            print_summary "$COUNT" "$TOTAL_HASHES" "$ELAPSED" "$TOTAL_DUP_FILES"
            LAST_UPDATE=$NOW_TIME
            # Redraw progress bar after summary print
            draw_progress_bar "$COUNT" "$TOTAL_HASHES"
            echo -ne " ETA ~$(format_seconds $REMAINING)   "
        fi
    fi

    sleep 0.05  # Optional slower visual update for smoothness
done

echo -e "\n${GREEN}[INFO]${NC} Processing complete."

# ───── Write final summary at the top of output file ─────
summary_comment=$(mktemp)
{
    echo "# Duplicate hashes output file generated from $INPUT_FILE"
    echo "# Processing started: $(date +"%Y-%m-%d %H:%M:%S")"
    echo "#"
    echo "# Summary:"
    echo "# Total duplicate hash groups processed: $TOTAL_HASHES"
    echo "# Total duplicate files found: $TOTAL_DUP_FILES"
    echo "# Processing completed: $(date +"%Y-%m-%d %H:%M:%S")"
    echo ""
} > "$summary_comment"

# Replace the first lines (header) in output file with updated summary (assumes 9 lines header)
sed -i "1,9d" "$OUTPUT_FILE"
sed -i "1r $summary_comment" "$OUTPUT_FILE"
rm -f "$summary_comment"

log_info "Duplicate hashes written to: $OUTPUT_FILE"
if (( QUIET == 1 )); then
    echo "[INFO] Quiet mode enabled: no progress bar or ETA displayed."
fi
