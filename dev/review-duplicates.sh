#!/bin/bash

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Setup Directories ─────
DUP_DIR="duplicate-hashes"
mkdir -p "$DUP_DIR"

# ───── Select Duplicate Report ─────
echo "[INFO] Available duplicate reports:"
REPORTS=($(ls -1 "$DUP_DIR"/*-duplicate-hashes.txt 2>/dev/null | sort))
if [ ${#REPORTS[@]} -eq 0 ]; then
    log_error "No duplicate reports found in $DUP_DIR"
    exit 1
fi

for i in "${!REPORTS[@]}"; do
    index=$((i+1))
    echo "  [$index] $(basename "${REPORTS[$i]}")"
done

read -p "Enter report number: " sel
if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#REPORTS[@]} )); then
    DUP_FILE="${REPORTS[$((sel-1))]}"
else
    log_error "Invalid selection."
    exit 1
fi

log_info "Using report: $(basename "$DUP_FILE")"

# ───── Parse Duplicate Groups ─────
GROUP_IDS=($(grep -oP '^Duplicate hash ID: \K\d+' "$DUP_FILE"))

TOTAL_GROUPS=${#GROUP_IDS[@]}
if [ "$TOTAL_GROUPS" -eq 0 ]; then
    log_info "No duplicate groups found in the report."
    exit 0
fi

# ───── Interactive Review ─────
log_info "Starting interactive review..."
DELETE_PLAN="$DUP_DIR/delete-plan.sh"
: > "$DELETE_PLAN"

group_counter=0

while read -r line; do
    if [[ "$line" =~ ^Duplicate\ hash\ ID:\ ([0-9]+) ]]; then
        ((group_counter++))
        GROUP_ID=${BASH_REMATCH[1]}
        echo -e "\n────────────────────────────────────────────"
        echo "Group $group_counter of $TOTAL_GROUPS"

        # Read next line for the actual hash
        read -r hash_line
        HASH=$(echo "$hash_line" | cut -d'"' -f2)
        echo "Duplicate hash: \"$HASH\""

        # Extract files in this group, skip zero-length
        mapfile -t FILES < <(awk -F',' -v h="$HASH" '$1==h && $6!="0.00" {print $3 " | " $6 " MB"}' "$DUP_FILE")
        if [ "${#FILES[@]}" -lt 2 ]; then
            log_warn "Group skipped (less than 2 valid files found)."
            continue
        fi

        echo -e "\nOptions:\n  S = Skip this group\n  Q = Quit review (you can resume later)"
        echo -e "\nSelect the file number to DELETE (other files in the group will be retained):"
        printf "  No.  | File path%s\n" " | Size MB"
        echo "  ───────────────────────────────────────────────────────────────"
        for i in "${!FILES[@]}"; do
            printf "  %-4s | %s\n" "$((i+1))" "${FILES[$i]}"
        done

        while true; do
            read -p "Your choice (S, Q or 1-${#FILES[@]}): " choice
            case "$choice" in
                [Ss])
                    log_info "Skipped group $GROUP_ID"
                    break
                    ;;
                [Qq])
                    log_info "Quitting review..."
                    echo "[INFO] Groups processed total : $group_counter" >> "$DELETE_PLAN"
                    exit 0
                    ;;
                [1-9]*)
                    if (( choice >= 1 && choice <= ${#FILES[@]} )); then
                        TO_DELETE=$(echo "${FILES[$((choice-1))]}" | cut -d'|' -f1 | xargs)
                        echo "rm -f \"$TO_DELETE\"" >> "$DELETE_PLAN"
                        log_info "Queued for deletion: $TO_DELETE"
                        break
                    else
                        log_warn "Invalid selection. Try again."
                    fi
                    ;;
                *)
                    log_warn "Invalid input. Try again."
                    ;;
            esac
        done
    fi
done < "$DUP_FILE"

log_info "Interactive review complete."
echo "[INFO] Deletions queued total : $(grep -c '^rm -f' "$DELETE_PLAN")"
echo "[INFO] Deletion plan saved to: $DELETE_PLAN"
echo "You can review and run it manually with:"
echo "  bash $DELETE_PLAN"
