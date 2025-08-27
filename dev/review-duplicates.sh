#!/bin/bash
# review-duplicates.sh
# Interactive duplicate file reviewer for hasher project

REPORT_DIR="duplicate-hashes"
PLAN_FILE="$REPORT_DIR/delete-plan.sh"
CHECKPOINT_FILE="$REPORT_DIR/.checkpoint"

mkdir -p "$REPORT_DIR"

log_info() {
    echo -e "[INFO] $*"
}

log_warn() {
    echo -e "[WARN] $*" >&2
}

log_error() {
    echo -e "[ERROR] $*" >&2
}

# Flush any buffered input (avoids Enter scrolling issues)
flush_input() {
    while read -t 0.1 -r -n 10000; do :; done
}

# Calculate expected disk saving so far
calc_plan_size() {
    if [[ -f "$PLAN_FILE" ]]; then
        awk '{for(i=2;i<=NF;i++) print $i}' "$PLAN_FILE" | xargs -r du -m 2>/dev/null | awk '{s+=$1} END {print s+0}'
    else
        echo 0
    fi
}

# Prompt user to pick report
choose_report() {
    local reports=("$REPORT_DIR"/*-duplicate-hashes.txt)
    if [[ ! -e "${reports[0]}" ]]; then
        log_error "No duplicate reports found in $REPORT_DIR"
        exit 1
    fi

    log_info "Available duplicate reports:"
    local i=1
    for r in "${reports[@]}"; do
        echo "  [$i] $(basename "$r")"
        ((i++))
    done

    flush_input
    read -rp "Enter report number: " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice >= i )); then
        log_error "Invalid selection"
        exit 1
    fi

    echo "${reports[$((choice-1))]}"
}

REPORT_FILE=$(choose_report)
REPORT_NAME=$(basename "$REPORT_FILE")
log_info "Using report: $REPORT_NAME"

TMP_GROUPS=$(mktemp)
awk -F, '{print $1}' "$REPORT_FILE" | sort | uniq -c | awk '$1>1 {print $2}' > "$TMP_GROUPS"

TOTAL_GROUPS=$(wc -l < "$TMP_GROUPS")
CURRENT_GROUP=0
QUEUED_DELETES=0
GROUPS_PROCESSED=0

# Resume if checkpoint exists
if [[ -f "$CHECKPOINT_FILE" ]]; then
    saved_report=$(head -n1 "$CHECKPOINT_FILE")
    saved_group=$(tail -n1 "$CHECKPOINT_FILE")
    if [[ "$saved_report" == "$REPORT_NAME" ]]; then
        log_info "Resuming from group: $saved_group"
        TMP_RESUME=$(mktemp)
        awk -v start="$saved_group" '$0==start {found=1; next} found' "$TMP_GROUPS" > "$TMP_RESUME"
        mv "$TMP_RESUME" "$TMP_GROUPS"
    fi
fi

echo "#!/bin/bash" > "$PLAN_FILE"
echo "# Deletion plan generated on $(date)" >> "$PLAN_FILE"
echo "" >> "$PLAN_FILE"

log_info "Starting interactive review..."

while read -r HASH; do
    ((CURRENT_GROUP++))

    echo ""
    echo "────────────────────────────────────────────"
    echo "Group $CURRENT_GROUP of $TOTAL_GROUPS"
    echo "Duplicate hash: \"$HASH\""
    grep -F "$HASH" "$REPORT_FILE"
    echo "────────────────────────────────────────────"

    mapfile -t FILES < <(grep -F "$HASH" "$REPORT_FILE" | awk -F, '{print $3}' | sed 's/"//g')
    mapfile -t SIZES < <(grep -F "$HASH" "$REPORT_FILE" | awk -F, '{print $6}' | sed 's/"//g')

    if (( ${#FILES[@]} < 2 )); then
        log_warn "Group skipped (less than 2 files found)."
        continue
    fi

    echo ""
    echo "Options:"
    echo "  S = Skip this group"
    echo "  Q = Quit review (you can resume later)"
    for i in "${!FILES[@]}"; do
        echo "  $((i+1)) = Delete file: ${FILES[$i]} (${SIZES[$i]} MB)"
    done

    flush_input
    while true; do
        echo ""
        read -r -p "Your choice (S, Q or 1-${#FILES[@]}): " choice

        if [[ "$choice" =~ ^[Qq]$ ]]; then
            echo "$REPORT_NAME" > "$CHECKPOINT_FILE"
            echo "$HASH" >> "$CHECKPOINT_FILE"
            SAVED_MB=$(calc_plan_size)
            echo ""
            log_info "Quitting. Progress saved at group $CURRENT_GROUP."
            log_info "Groups processed so far : $GROUPS_PROCESSED"
            log_info "Deletions queued so far : $QUEUED_DELETES"
            log_info "Expected disk saving    : ${SAVED_MB} MB"
            log_info "Run again later to resume."
            rm -f "$TMP_GROUPS"
            exit 0
        elif [[ "$choice" =~ ^[Ss]$ ]]; then
            log_info "Skipped this group."
            echo ""
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FILES[@]} )); then
            target="${FILES[$((choice - 1))]}"

            echo ""
            echo "Selected for deletion:"
            echo "  $target"
            read -r -p "Confirm add to deletion plan? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                printf 'rm -f -- %q\n' "$target" >> "$PLAN_FILE"
                ((QUEUED_DELETES++))
                log_info "Added to deletion plan."
            else
                log_info "Skipped deletion for this group."
            fi
            echo ""
            break
        else
            log_warn "Invalid input. Please try again."
        fi
    done

    ((GROUPS_PROCESSED++))
done < "$TMP_GROUPS"

rm -f "$TMP_GROUPS" "$CHECKPOINT_FILE"

SAVED_MB=$(calc_plan_size)

echo ""
log_info "Interactive review complete."
log_info "Groups processed total : $GROUPS_PROCESSED"
log_info "Deletions queued total : $QUEUED_DELETES"
log_info "Expected disk saving   : ${SAVED_MB} MB"
log_info "Deletion plan saved to: $PLAN_FILE"
echo "You can review and run it manually with:"
echo "  bash $PLAN_FILE"
