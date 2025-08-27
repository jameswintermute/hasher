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

# ───── Parameters ─────
ZERO_FILE_CSV="hashes/zero-length-files-$(date +'%Y-%m-%d').csv"
VERIFY_LIST="hashes/zero-length-files-verified-$(date +'%Y-%m-%d').csv"
MODE="$1"  # verify or delete
BATCH_SIZE=15

if [[ -z "$MODE" || ! "$MODE" =~ ^(verify|delete)$ ]]; then
    log_error "Usage: $0 [verify|delete]"
    exit 1
fi

if [ ! -f "$ZERO_FILE_CSV" ]; then
    log_error "Zero-length file list not found: $ZERO_FILE_CSV"
    exit 1
fi

# ───── Read Files ─────
FILES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    FILES+=("$line")
done < "$ZERO_FILE_CSV"

TOTAL=${#FILES[@]}
if [ "$TOTAL" -eq 0 ]; then
    log_info "No zero-length files to process."
    exit 0
fi

if [ "$MODE" == "verify" ]; then
    log_info "Starting verification of zero-length files..."
    : > "$VERIFY_LIST"
    verified_count=0
    skipped_count=0

    for file in "${FILES[@]}"; do
        if [ ! -e "$file" ]; then
            log_warn "File no longer exists: $file"
            skipped_count=$((skipped_count+1))
            continue
        fi
        SIZE=$(stat -c %s "$file" 2>/dev/null || echo "-1")
        if [ "$SIZE" -eq 0 ]; then
            echo "$file" >> "$VERIFY_LIST"
            verified_count=$((verified_count+1))
        else
            log_warn "File is no longer zero-length, skipping: $file ($SIZE bytes)"
            skipped_count=$((skipped_count+1))
        fi
    done

    log_info "Verification complete."
    log_info "Verified files: $verified_count"
    log_info "Skipped files: $skipped_count"
    log_info "Verified list saved to: $VERIFY_LIST"

elif [ "$MODE" == "delete" ]; then
    if [ ! -f "$VERIFY_LIST" ]; then
        log_error "Verified list not found: $VERIFY_LIST. Run verify mode first."
        exit 1
    fi

    # Read verified files
    FILES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        FILES+=("$line")
    done < "$VERIFY_LIST"

    TOTAL=${#FILES[@]}
    if [ "$TOTAL" -eq 0 ]; then
        log_info "No verified zero-length files to delete."
        exit 0
    fi

    log_info "Starting deletion of $TOTAL zero-length files..."

    deleted_count=0
    skipped_count=0
    batch_files=()

    for file in "${FILES[@]}"; do
        if [ ! -e "$file" ]; then
            log_warn "File no longer exists, skipping: $file"
            skipped_count=$((skipped_count+1))
            continue
        fi

        SIZE=$(stat -c %s "$file" 2>/dev/null || echo "-1")
        if [ "$SIZE" -ne 0 ]; then
            log_warn "File is no longer zero-length, skipping: $file ($SIZE bytes)"
            skipped_count=$((skipped_count+1))
            continue
        fi

        batch_files+=("$file")

        # Batch confirmation
        if [ "${#batch_files[@]}" -ge "$BATCH_SIZE" ]; then
            echo -e "\nThe following zero-length files are ready to be deleted:"
            for f in "${batch_files[@]}"; do
                echo "  $f"
            done
            read -p "Delete these ${#batch_files[@]} files? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                for f in "${batch_files[@]}"; do
                    rm -f "$f" && deleted_count=$((deleted_count+1))
                done
            else
                skipped_count=$((skipped_count+${#batch_files[@]}))
                log_warn "Skipped this batch."
            fi
            batch_files=()
        fi
    done

    # Final batch
    if [ "${#batch_files[@]}" -gt 0 ]; then
        echo -e "\nThe following zero-length files are ready to be deleted:"
        for f in "${batch_files[@]}"; do
            echo "  $f"
        done
        read -p "Delete these ${#batch_files[@]} files? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            for f in "${batch_files[@]}"; do
                rm -f "$f" && deleted_count=$((deleted_count+1))
            done
        else
            skipped_count=$((skipped_count+${#batch_files[@]}))
            log_warn "Skipped this batch."
        fi
    fi

    # ───── Summary ─────
    echo -e "\n${GREEN}[INFO]${NC} Zero-length file deletion complete."
    echo "Deleted files : $deleted_count"
    echo "Skipped files : $skipped_count"
    echo "Total files processed: $TOTAL"
fi
