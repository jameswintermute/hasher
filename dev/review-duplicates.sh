#!/bin/bash
# review-duplicates.sh
# Interactively review duplicate hashes and build a safe deletion plan

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Setup ─────
DUP_DIR="duplicate-hashes"
PLAN_FILE="$DUP_DIR/delete-plan.sh"

mkdir -p "$DUP_DIR"

# ───── Select duplicate report ─────
echo ""
log_info "Available duplicate reports:"
REPORTS=($(ls -t "$DUP_DIR"/*-duplicate-hashes.txt 2>/dev/null))
if [ ${#REPORTS[@]} -eq 0 ]; then
    log_error "No duplicate reports found in '$DUP_DIR'."
    exit 1
fi

for i in "${!REPORTS[@]}"; do
    index=$((i + 1))
    echo "  [$index] $(basename "${REPORTS[$i]}")"
done
echo ""

read -p "Enter report number: " selection
if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#REPORTS[@]} )); then
    REPORT_FILE="${REPORTS[$((selection - 1))]}"
else
    log_error "Invalid selection. Exiting."
    exit 1
fi

log_info "Using report: $(basename "$REPORT_FILE")"
echo ""

# ───── Prepare deletion plan ─────
echo "#!/bin/bash" > "$PLAN_FILE"
echo "# Deletion plan generated on $(date)" >> "$PLAN_FILE"
echo "" >> "$PLAN_FILE"
chmod +x "$PLAN_FILE"

# ───── Process duplicate groups ─────
log_info "Starting interactive review..."
GROUPS=$(grep -n "^Duplicate hash ID:" "$REPORT_FILE" | cut -d':' -f1)

while read -r line_num; do
    echo ""
    echo "────────────────────────────────────────────"
    # Extract one duplicate group block
    start=$line_num
    end=$(awk "NR>$line_num && /^Duplicate hash ID:/ {print NR; exit}" "$REPORT_FILE")
    if [ -z "$end" ]; then
        end=$(wc -l < "$REPORT_FILE")
    else
        end=$((end - 1))
    fi

    BLOCK=$(sed -n "${start},${end}p" "$REPORT_FILE")

    # Display the block to user
    echo "$BLOCK"
    echo ""

    # Extract file paths from block
    FILES=($(echo "$BLOCK" | grep -E '^"' | cut -d',' -f3 | tr -d '"'))

    if [ ${#FILES[@]} -lt 2 ]; then
        log_warn "Group skipped (less than 2 files found)."
        continue
    fi

    # Prompt user
    echo "Options:"
    echo "  S = Skip this group"
    for i in "${!FILES[@]}"; do
        idx=$((i + 1))
        echo "  $idx = Delete file: ${FILES[$i]}"
    done
    echo ""

    read -p "Your choice: " choice

    if [[ "$choice" == "S" || "$choice" == "s" ]]; then
        log_info "Skipped this group."
        continue
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FILES[@]} )); then
        target="${FILES[$((choice - 1))]}"
        echo ""
        read -p "Confirm deletion of '$target'? (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo "rm -f \"$target\"" >> "$PLAN_FILE"
            log_info "Added to deletion plan: $target"
        else
            log_info "Skipped deletion for this group."
        fi
    else
        log_warn "Invalid input. Group skipped."
    fi
done <<< "$GROUPS"

echo ""
log_info "Interactive review complete."
log_info "Deletion plan saved to: $PLAN_FILE"
echo "You can review and run it manually with:"
echo "  $PLAN_FILE"
