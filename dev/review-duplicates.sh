#!/bin/bash
# review-duplicates.sh
# Interactive duplicate file reviewer for hasher project
# Fully functional with colorized output and filesystem file sizes

REPORT_DIR="duplicate-hashes"
PLAN_FILE="$REPORT_DIR/delete-plan.sh"
CHECKPOINT_FILE="$REPORT_DIR/.checkpoint"
PREVIEW_MODE=false
TABLE_WIDTH=140

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

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

log_info() { echo -e "[INFO] $*"; }
log_warn() { echo -e "[WARN] $*" >&2; }
log_error() { echo -e "[ERROR] $*" >&2; }

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
# Build hash -> files map
# --------------------------
declare -A FILE_MAP
declare -A SIZE_MAP
while IFS=',' read -r fhash _ _ filepath _ _ _; do
    # Clean hash and filepath
    fhash=$(echo "$fhash" | tr -d '"' | tr -d '\r')
    filepath=$(echo "$filepath" | tr -d '"' | tr -d '\r')
    [[ -z "$fhash" || -z "$filepath" ]] && continue
    FILE_MAP["$fhash"]+="$filepath"$'\n'

    if [[ -f "$filepath" ]]; then
        SIZE_MAP["$filepath"]=$(du -m "$filepath" 2>/dev/null | cut -f1)
    else
        SIZE_MAP["$filepath"]="N/A"
    fi
done < <(grep -E '^"[0-9a-f]{64}"' "$REPORT_FILE")

# --------------------------
# Prepare duplicate groups
# --------------------------
TMP_GROUPS=$(mktemp)
for h in "${!FILE_MAP[@]}"; do
    n_files=$(echo "${FILE_MAP[$h]}" | wc -l)
    (( n_files > 1 )) && echo "$h" >> "$TMP_GROUPS"
done

TOTAL_GROUPS=$(wc -l < "$TMP_GROUPS")
CURRENT_GROUP=0
QUEUED_DELETES=0
GROUPS_PROCESSED=0

# Resume if checkpoint exists
if [[ -f "$CHECKPOINT_FILE" ]]; then
    saved_report=$(head -n1 "$CHECKPOINT_FILE")
    saved_hash=$(tail -n1 "$CHECKPOINT_FILE")
    if [[ "$saved_report" == "$REPORT_NAME" ]]; then
        log_info "Resuming from hash: $saved_hash"
        TMP_RESUME=$(mktemp)
        awk -v skip="$saved_hash" '$0!=skip' "$TMP_GROUPS" > "$TMP_RESUME"
        mv "$TMP_RESUME" "$TMP_GROUPS"
    fi
fi

# Prepare delete plan
echo "#!/bin/bash" > "$PLAN_FILE"
echo "# Deletion plan generated on $(date)" >> "$PLAN_FILE"
echo "" >> "$PLAN_FILE"

log_info "Starting interactive review..."
while read -r HASH; do
    ((CURRENT_GROUP++))
    echo ""
    echo "${CYAN}────────────────────────────────────────────${RESET}"
    echo "${CYAN}Group $CURRENT_GROUP of $TOTAL_GROUPS${RESET}"
    echo "${CYAN}Duplicate hash: \"$HASH\"${RESET}"

    mapfile -t FILES < <(echo -e "${FILE_MAP[$HASH]}")

    if (( ${#FILES[@]} < 2 )); then
        log_warn "Group skipped (less than 2 valid files found)."
        continue
    fi

    if [[ "$PREVIEW_MODE" == true ]]; then
        echo "[Preview mode] Skipping deletion prompt..."
        read -rp "Press Enter to continue..."
        ((GROUPS_PROCESSED++))
        continue
    fi

    # --------------------------
    # Display table with colors
    # --------------------------
    echo ""
    echo "Options:"
    echo "  S = Skip this group"
    echo "  Q = Quit review (you can resume later)"
    printf "  %-4s | %-${TABLE_WIDTH}s | %6s MB\n" "No." "File path" "Size"
    echo "  $(printf -- '─%.0s' {1..$((TABLE_WIDTH+16))})"
    for i in "${!FILES[@]}"; do
        f="${FILES[$i]}"
        truncated=$(truncate_path "$f" $TABLE_WIDTH)
        size="${SIZE_MAP[$f]}"
        color=$((i%2==0 ? GREEN : YELLOW))
        printf "  ${!color}%-4s | %-s | %6s${RESET}\n" "$((i+1))" "$truncated" "$size"
    done

    # Prompt user for input
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
            target="${FILES[$((choice - 1))]}"
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
