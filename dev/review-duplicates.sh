#!/bin/bash
# review-duplicates.sh - interactive duplicate file reviewer

HASHES_DIR="hashes"
DELETE_DIR="duplicate-hashes"
mkdir -p "$DELETE_DIR"

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── List available duplicate reports ─────
REPORTS=("$HASHES_DIR"/*-duplicate-hashes.txt)
if [[ ${#REPORTS[@]} -eq 0 ]]; then
    log_error "No duplicate reports found in $HASHES_DIR"
    exit 1
fi

echo -e "[INFO] Available duplicate reports:"
for i in "${!REPORTS[@]}"; do
    echo "  [$((i+1))] $(basename "${REPORTS[$i]}")"
done

read -rp "Enter report number: " report_num
if ! [[ "$report_num" =~ ^[0-9]+$ ]] || (( report_num < 1 || report_num > ${#REPORTS[@]} )); then
    log_error "Invalid report number"
    exit 1
fi

REPORT="${REPORTS[$((report_num-1))]}"
log_info "Using report: $(basename "$REPORT")"

# ───── Parse duplicates ─────
mapfile -t DUP_GROUPS < <(awk -F',' '
    /^Duplicate hash:/ {hash=$2; gsub(/"/,"",hash); group++}
    /^"/ {print group","$0}
' "$REPORT")

TOTAL_GROUPS=$(awk '/^Duplicate hash:/ {count++} END{print count}' "$REPORT")
log_info "Starting interactive review..."

DELETE_PLAN="$DELETE_DIR/delete-plan.sh"
echo "#!/bin/bash" > "$DELETE_PLAN"

CURRENT_GROUP=0
while IFS= read -r line; do
    ((CURRENT_GROUP++))
    GROUP_ID=$(cut -d',' -f1 <<< "$line")
    FILE_PATH=$(cut -d',' -f3 <<< "$line")

    # Skip zero-length files automatically
    SIZE_BYTES=$(stat -c %s "$FILE_PATH" 2>/dev/null || echo 0)
    (( SIZE_BYTES == 0 )) && continue

    if [[ "$GROUP_ID" != "$LAST_GROUP_ID" ]]; then
        LAST_GROUP_ID="$GROUP_ID"
        echo -e "\n────────────────────────────────────────────"
        echo "Group $GROUP_ID of $TOTAL_GROUPS"
        echo "Options:"
        echo "  S = Skip this group"
        echo "  Q = Quit review (you can resume later)"
        echo "Select the file number to DELETE:"
        FILES=()
        FILE_NUM=0
    fi

    FILES+=("$FILE_PATH")
    ((FILE_NUM++))
    printf "  %2d   | %s\n" "$FILE_NUM" "$FILE_PATH"

    # Determine when we have finished reading the group
    NEXT_LINE=${DUP_GROUPS[$CURRENT_GROUP]}
    NEXT_GROUP=$(cut -d',' -f1 <<< "$NEXT_LINE")
    if [[ "$NEXT_GROUP" != "$GROUP_ID" ]] || [[ -z "$NEXT_LINE" ]]; then
        # Ask user which file to delete
        while true; do
            read -rp "Your choice (S, Q or 1-$FILE_NUM): " choice
            case "$choice" in
                S|s) break ;;
                Q|q) log_info "Exiting interactive review"; exit 0 ;;
                [1-9]*)
                    if (( choice >=1 && choice <= FILE_NUM )); then
                        DELETE_FILE="${FILES[$((choice-1))]}"
                        echo "rm -f \"$DELETE_FILE\"" >> "$DELETE_PLAN"
                        log_info "Queued deletion: $DELETE_FILE"
                        break
                    else
                        log_warn "Invalid selection"
                    fi
                    ;;
                *) log_warn "Invalid input" ;;
            esac
        done
    fi

done < <(printf "%s\n" "${DUP_GROUPS[@]}")

log_info "Interactive review complete."
TOTAL_QUEUED=$(grep -c '^rm -f' "$DELETE_PLAN")
echo -e "[INFO] Groups processed total : $TOTAL_GROUPS"
echo -e "[INFO] Deletions queued total : $TOTAL_QUEUED"
echo -e "[INFO] Deletion plan saved to: $DELETE_PLAN"
echo "You can review and run it manually with:"
echo "  bash $DELETE_PLAN"
