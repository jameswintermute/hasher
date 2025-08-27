#!/bin/bash
# review-duplicates.sh
# Interactively review duplicate hashes and build a safe deletion plan (resumable)

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Setup ─────
DUP_DIR="duplicate-hashes"
PLAN_FILE="$DUP_DIR/delete-plan.sh"
CHECKPOINT_FILE="$DUP_DIR/review-checkpoint.txt"

mkdir -p "$DUP_DIR"

# ───── Select duplicate report ─────
echo ""
log_info "Available duplicate reports:"
mapfile -t REPORTS < <(ls -t "$DUP_DIR"/*-duplicate-hashes.txt 2>/dev/null)

if [ ${#REPORTS[@]} -eq 0 ]; then
    log_error "No duplicate reports found in '$DUP_DIR'."
    exit 1
fi

for i in "${!REPORTS[@]}"; do
    idx=$((i + 1))
    echo "  [$idx] $(basename "${REPORTS[$i]}")"
done
echo ""

read -p "Enter report number: " selection
if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#REPORTS[@]} )); then
    REPORT_FILE="${REPORTS[$((selection - 1))]}"
else
    log_error "Invalid selection. Exiting."
    exit 1
fi

REPORT_NAME=$(basename "$REPORT_FILE")
log_info "Using report: $REPORT_NAME"
echo ""

# ───── Handle checkpoint ─────
START_GROUP=1
if [ -f "$CHECKPOINT_FILE" ]; then
    LAST_REPORT=$(head -n1 "$CHECKPOINT_FILE")
    LAST_GROUP=$(tail -n1 "$CHECKPOINT_FILE")

    if [[ "$LAST_REPORT" == "$REPORT_NAME" ]]; then
        echo "Resume review from group $LAST_GROUP? (y/N)"
        read -r resume
        if [[ "$resume" =~ ^[Yy]$ ]]; then
            START_GROUP=$LAST_GROUP
            log_info "Resuming from group $START_GROUP..."
        else
            log_info "Starting fresh review..."
        fi
    else
        log_info "Checkpoint is from a different report, starting fresh..."
    fi
fi

# ───── Prepare deletion plan ─────
if [ $START_GROUP -eq 1 ]; then
    {
        echo "#!/bin/bash"
        echo "# Deletion plan generated on $(date)"
        echo ""
    } > "$PLAN_FILE"
    chmod +x "$PLAN_FILE"
fi

# Counters
GROUPS_PROCESSED=0
QUEUED_DELETES=0
CURRENT_GROUP=0

log_info "Starting interactive review..."

# ───── Split groups into a temp file ─────
TMP_GROUPS=$(mktemp)
awk 'BEGIN{RS=""; ORS="\n\n"} /^Duplicate hash ID:/' "$REPORT_FILE" > "$TMP_GROUPS"

TOTAL_GROUPS=$(grep -c "Duplicate hash ID:" "$REPORT_FILE")

# ───── Helper: calculate total size in MB of planned deletions ─────
calc_plan_size() {
    local total_bytes=0
    while IFS= read -r line; do
        # Extract the file path from: rm -f -- "path"
        filepath=$(echo "$line" | sed -E 's/^rm -f -- (.*)$/\1/' | sed 's/^"\(.*\)"$/\1/')
        if [ -f "$filepath" ]; then
            size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
            total_bytes=$((total_bytes + size))
        fi
    done < <(grep '^rm -f' "$PLAN_FILE")
    echo $(( total_bytes / 1024 / 1024 ))  # MB
}

# Loop through groups safely
while IFS= read -r -d '' BLOCK; do
    ((CURRENT_GROUP++))
    if (( CURRENT_GROUP < START_GROUP )); then
        continue
    fi
    ((GROUPS_PROCESSED++))

    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo "Group $CURRENT_GROUP of $TOTAL_GROUPS"
    echo "$BLOCK"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"

    # Extract file paths from CSV rows
    mapfile -t FILES < <(printf '%s\n' "$BLOCK" \
        | grep '^"' \
        | awk -F',' '{f=$3; gsub(/^"|"$/, "", f); print f}')

    if [ ${#FILES[@]} -lt 2 ]; then
        log_warn "Group skipped (found ${#FILES[@]} file path(s))."
        continue
    fi

    echo ""
    echo "Options:"
    echo "  S = Skip this group"
    echo "  Q = Quit review (you can resume later)"
    for i in "${!FILES[@]}"; do
        idx=$((i + 1))
        echo "  $idx = Delete file: ${FILES[$i]}"
    done
    echo ""

    # Wait for user input
    read -p "Your choice (S, Q or 1-${#FILES[@]}): " choice

    if [[ "$choice" =~ ^[Qq]$ ]]; then
        echo "$REPORT_NAME" > "$CHECKPOINT_FILE"
        echo "$CURRENT_GROUP" >> "$CHECKPOINT_FILE"
        SAVED_MB=$(calc_plan_size)
        echo ""
        log_info "Quitting. Progress saved at group $CURRENT_GROUP."
        log_info "Groups processed so far : $GROUPS_PROCESSED"
        log_info "Deletions queued so far : $QUEUED_DELETES"
        log_info "Expected disk saving    : ${SAVED_MB} MB"
        log_info "Run again later to resume."
        rm -f "$TMP_GROUPS"
        exit 0
    fi

    if [[ "$choice" =~ ^[Ss]$ ]]; then
        log_info "Skipped this group."
        echo ""
        continue
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FILES[@]} )); then
        target="${FILES[$((choice - 1))]}"

        echo ""
        echo "Selected for deletion:"
        echo "  $target"
        read -p "Confirm add to deletion plan? (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            printf 'rm -f -- %q\n' "$target" >> "$PLAN_FILE"
            ((QUEUED_DELETES++))
            log_info "Added to deletion plan."
        else
            log_info "Skipped deletion for this group."
        fi
        echo ""
    else
        log_warn "Invalid input. Group skipped."
        echo ""
    fi

    # Save checkpoint after each group
    echo "$REPORT_NAME" > "$CHECKPOINT_FILE"
    echo "$((CURRENT_GROUP + 1))" >> "$CHECKPOINT_FILE"

done < <(awk 'BEGIN{RS=""; ORS="\0"} /^Duplicate hash ID:/' "$REPORT_FILE")

rm -f "$TMP_GROUPS"
rm -f "$CHECKPOINT_FILE"  # clean up, review finished

FINAL_MB=$(calc_plan_size)

echo ""
log_info "Interactive review complete."
log_info "Groups processed : $GROUPS_PROCESSED"
log_info "Deletions queued : $QUEUED_DELETES"
log_info "Expected saving  : ${FINAL_MB} MB"
log_info "Deletion plan saved to: $PLAN_FILE"
echo "Review it, then execute to delete:"
echo "  $PLAN_FILE"
