#!/bin/bash
# review-duplicates.sh
# Interactive duplicate file reviewer for hasher project

REPORT_DIR="duplicate-hashes"
PLAN_FILE="$REPORT_DIR/delete-plan.sh"
CHECKPOINT_FILE="$REPORT_DIR/.checkpoint"
PREVIEW_MODE=false
TABLE_WIDTH=80

# --------------------------
# Parse flags
# --------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --preview)
            PREVIEW_MODE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

mkdir -p "$REPORT_DIR"

# --------------------------
# Logging with color
# --------------------------
log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

flush_input() {
    while read -t 0.1 -r -n 10000; do :; done
}

calc_plan_size() {
    if [[ -f "$PLAN_FILE" ]]; then
        awk '{for(i=2;i<=NF;i++) print $i}' "$PLAN_FILE" | xargs -r du -m 2>/dev/null | awk '{s+=$1} END {print s+0}'
    else
        echo 0
    fi
}

truncate_path() {
    local path="$1"
    local maxlen=$2
    local len=${#path}
    if (( len <= maxlen )); then
        echo "$path"
    else
        echo "...${path: -$((maxlen-3))}"
    fi
}

# --------------------------
# Report selection
# --------------------------
shopt -s nullglob
reports=("$REPORT_DIR"/*-duplicate-hashes.txt)
shopt -u nullglob

if [[ ${#reports[@]} -eq 0 ]]; then
    log_error "No duplicate reports found in $REPORT_DIR"
    exit 1
fi

log_info "Available duplicate reports:"
for i in "${!reports[@]}"; do
    echo "  [$((i+1))] $(basename "${reports[$i]}")"
done

# Prompt user for selection
while true; do
    read -rp "Enter report number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#reports[@]} )); then
        REPORT_FILE="${reports[$((choice-1))]}"
        break
    else
        echo "[WARN] Invalid selection, try again."
    fi
done

REPORT_NAME=$(basename "$REPORT_FILE")
log_info "Using report: $REPORT_NAME"
flush_input

# --------------------------
# Build duplicates map
# --------------------------
declare -A FILE_MAP
declare -A SIZE_MAP

while IFS=',' read -r hash _ file _ _ size; do
    # Remove quotes
    hash="${hash//\"/}"
    file="${file//\"/}"
    size="${size//\"/}"
    if [[ -n "$file" ]]; then
        FILE_MAP["$hash"]+="$file"$'\n'
        SIZE_MAP["$file"]="$size"
    fi
done < <(grep -E '^[0-9a-f]{64},' "$REPORT_FILE")

# Filter hashes with 2 or more files
HASHES=()
for hash in "${!FILE_MAP[@]}"; do
    count=$(echo -n "${FILE_MAP[$hash]}" | grep -c '^')
    if (( count > 1 )); then
        HASHES+=("$hash")
    fi
done

TOTAL_GROUPS=${#HASHES[@]}
CURRENT_GROUP=0
QUEUED_DELETES=0
GROUPS_PROCESSED=0

# --------------------------
# Resume from checkpoint
# --------------------------
if [[ -f "$CHECKPOINT_FILE" ]]; then
    saved_report=$(head -n1 "$CHECKPOINT_FILE")
    saved_hash=$(tail -n1 "$CHECKPOINT_FILE")
    if [[ "$saved_report" == "$REPORT_NAME" ]]; then
        log_info "Resuming from hash: $saved_hash"
        TMP=()
        resume=false
        for h in "${HASHES[@]}"; do
            if [[ "$resume" = true ]]; then
                TMP+=("$h")
            elif [[ "$h" == "$saved_hash" ]]; then
                resume=true
            fi
        done
        HASHES=("${TMP[@]}")
    fi
fi

# --------------------------
# Prepare deletion plan
# --------------------------
echo "#!/bin/bash" > "$PLAN_FILE"
echo "# Deletion plan generated on $(date)" >> "$PLAN_FILE"
echo "" >> "$PLAN_FILE"

# --------------------------
# Interactive review
# --------------------------
log_info "Starting interactive review..."
for HASH in "${HASHES[@]}"; do
    ((CURRENT_GROUP++))
    echo ""
    echo "────────────────────────────────────────────"
    echo "Group $CURRENT_GROUP of $TOTAL_GROUPS"
    echo "Duplicate hash: \"$HASH\""

    mapfile -t FILES < <(echo -n "${FILE_MAP[$HASH]}" | sed '/^\s*$/d')

    if (( ${#FILES[@]} < 2 )); then
        log_warn "Group skipped (less than 2 valid files found)."
        continue
    fi

    # Display table
    echo ""
    echo "Options:"
    echo "  S = Skip this group"
    echo "  Q = Quit review (you can resume later)"
    printf "  %-4s | %-${TABLE_WIDTH}s | %6s MB\n" "No." "File path" "Size"
    echo "  $(printf -- '─%.0s' {1..$((TABLE_WIDTH+16))})"

    for i in "${!FILES[@]}"; do
        file="${FILES[$i]}"
        size="${SIZE_MAP[$file]}"
        [[ -z "$size" ]] && size="N/A"
        truncated=$(truncate_path "$file" $TABLE_WIDTH)
        printf "  %-4s | %s | %6s\n" "$((i+1))" "$truncated" "$size"
    done

    if [[ "$PREVIEW_MODE" == true ]]; then
        read -rp "Press Enter to continue to next group..."
        ((GROUPS_PROCESSED++))
        continue
    fi

    # User interaction
    while true; do
        read -rp "Your choice (S, Q or 1-${#FILES[@]}): " choice
        choice_upper=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

        if [[ "$choice_upper" == "Q" ]]; then
            echo "$REPORT_NAME" > "$CHECKPOINT_FILE"
            echo "$HASH" >> "$CHECKPOINT_FILE"
            SAVED_MB=$(calc_plan_size)
            log_info "Quitting. Progress saved at group $CURRENT_GROUP."
            log_info "Groups processed so far : $GROUPS_PROCESSED"
            log_info "Deletions queued so far : $QUEUED_DELETES"
            log_info "Expected disk saving    : ${SAVED_MB} MB"
            exit 0
        elif [[ "$choice_upper" == "S" ]]; then
            log_info "Skipped this group."
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FILES[@]} )); then
            target="${FILES[$((choice-1))]}"
            read -rp "Confirm add to deletion plan? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                printf 'rm -f -- %q\n' "$target" >> "$PLAN_FILE"
                ((QUEUED_DELETES++))
                log_info "Added to deletion plan."
            else
                log_info "Skipped deletion for this file."
            fi
            break
        else
            log_warn "Invalid input. Please try again."
        fi
    done
    ((GROUPS_PROCESSED++))
done

rm -f "$CHECKPOINT_FILE"

SAVED_MB=$(calc_plan_size)
echo ""
log_info "Interactive review complete."
log_info "Groups processed total : $GROUPS_PROCESSED"
log_info "Deletions queued total : $QUEUED_DELETES"
log_info "Expected disk saving   : ${SAVED_MB} MB"
log_info "Deletion plan saved to: $PLAN_FILE"
echo "You can review and run it manually with:"
echo "  bash $PLAN_FILE"
