#!/bin/bash

# ───── Config ─────
DUPLICATE_DIR="duplicate-hashes"
mkdir -p "$DUPLICATE_DIR"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── List available reports ─────
REPORTS=( "$DUPLICATE_DIR"/*-duplicate-hashes.txt )
if [ ${#REPORTS[@]} -eq 0 ]; then
    log_error "No duplicate reports found in $DUPLICATE_DIR"
    exit 1
fi

log_info "Available duplicate reports:"
for i in "${!REPORTS[@]}"; do
    echo "  [$((i+1))] $(basename "${REPORTS[$i]}")"
done

read -p "Enter report number: " REPORT_NUM
if ! [[ "$REPORT_NUM" =~ ^[0-9]+$ ]] || [ "$REPORT_NUM" -lt 1 ] || [ "$REPORT_NUM" -gt "${#REPORTS[@]}" ]; then
    log_error "Invalid report number"
    exit 1
fi

REPORT="${REPORTS[$((REPORT_NUM-1))]}"
log_info "Using report: $(basename "$REPORT")"

# ───── Interactive Review ─────
log_info "Starting interactive review..."
DELETE_PLAN="$DUPLICATE_DIR/delete-plan.sh"
echo "#!/bin/bash" > "$DELETE_PLAN"

group_count=0
total_groups=$(grep -c "^Duplicate hash ID:" "$REPORT")
current_hash=""
files=()

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^Duplicate\ hash\ ID: ]]; then
        # Process previous group
        if [ ${#files[@]} -ge 2 ]; then
            group_count=$((group_count+1))
            echo ""
            echo "────────────────────────────────────────────"
            echo "Group $group_count of $total_groups"
            echo "Duplicate hash: \"$current_hash\""
            echo ""
            echo "Options:"
            echo "  S = Skip this group"
            echo "  Q = Quit review (you can resume later)"
            echo ""
            echo "Select the file number to DELETE:"
            printf "  No.  | File path\n  ─\n"
            for i in "${!files[@]}"; do
                size_bytes=$(stat -c %s "${files[$i]}" 2>/dev/null || echo 0)
                [[ "$size_bytes" -eq 0 ]] && continue
                printf "  %d    | %s\n" "$((i+1))" "${files[$i]}"
            done

            while true; do
                read -p "Your choice (S, Q or 1-${#files[@]}): " choice
                case "$choice" in
                    S|s) break ;;
                    Q|q) log_info "Quitting review"; exit 0 ;;
                    ''|*[!0-9]*) log_warn "Invalid input. Try again." ;;
                    *)
                        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
                            selected="${files[$((choice-1))]}"
                            echo "rm -v \"$selected\"" >> "$DELETE_PLAN"
                            log_info "Queued for deletion: $selected"
                            break
                        else
                            log_warn "Invalid number. Try again."
                        fi
                        ;;
                esac
            done
        fi
        # Reset for new group
        current_hash=""
        files=()
    fi

    if [[ "$line" =~ ^Duplicate\ hash:\ \"([a-f0-9]+)\" ]]; then
        current_hash="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^\"[a-f0-9]+\",\".+\",\"(.+)\"," ]]; then
        file_path="${BASH_REMATCH[1]}"
        size_bytes=$(stat -c %s "$file_path" 2>/dev/null || echo 0)
        [[ "$size_bytes" -eq 0 ]] && continue
        files+=("$file_path")
    fi
done < "$REPORT"

log_info "Interactive review complete."
log_info "Deletion plan saved to: $DELETE_PLAN"
echo "You can review and run it manually with:"
echo "  bash $DELETE_PLAN"
