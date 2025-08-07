#!/bin/bash

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

# ───── Paths ─────
DUP_DIR="duplicate-hashes"
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

# ───── Dry Run Flag ─────
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    log_info "Running in DRY RUN mode. No files will be deleted."
fi

# ───── Startup Banner ─────
echo -e "${RED}=============================================================="
echo -e "WARNING: This script will delete surplus duplicate files."
echo -e "You will be shown each group and asked to confirm deletion."
echo -e "The NEWEST file in each group will be kept."
if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN ENABLED: No files will be deleted.${RED}"
fi
echo -e "A log will be saved in '${LOG_DIR}/'"
echo -e "==============================================================${NC}"

# ───── Select File ─────
FILES=($(ls -t "$DUP_DIR"/*-duplicate-hashes.txt 2>/dev/null))
if [ ${#FILES[@]} -eq 0 ]; then
    log_error "No duplicate hashes files found in '$DUP_DIR'."
    exit 1
fi

echo ""
echo "Select a duplicate hash report to process:"
for i in "${!FILES[@]}"; do
    index=$((i + 1))
    echo "  [$index] $(basename "${FILES[$i]}")"
done
echo ""

read -p "Enter file number: " selection
if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#FILES[@]} )); then
    INPUT_FILE="${FILES[$((selection - 1))]}"
else
    log_error "Invalid selection."
    exit 1
fi

log_info "Selected file: $(basename "$INPUT_FILE")"

# ───── Prepare Log File ─────
TIMESTAMP=$(date +'%Y-%m-%d-%H%M%S')
if $DRY_RUN; then
    LOG_FILE="$LOG_DIR/dry-run-deletions-$TIMESTAMP.log"
else
    LOG_FILE="$LOG_DIR/deletions-$TIMESTAMP.log"
fi
touch "$LOG_FILE"

# ───── Process Each Group ─────
awk -v RED="$RED" -v GREEN="$GREEN" -v CYAN="$CYAN" -v YELLOW="$YELLOW" -v NC="$NC" \
    -v log_file="$LOG_FILE" -v dry_run="$DRY_RUN" '
BEGIN {
    RS=""
    FS="\n"
}

function get_newest_file(files, count) {
    newest = files[1]
    cmd = "stat -c \"%Y\" \"" newest "\""
    cmd | getline max_time
    close(cmd)

    for (i = 2; i <= count; i++) {
        f = files[i]
        cmd = "stat -c \"%Y\" \"" f "\""
        cmd | getline f_time
        close(cmd)
        if (f_time > max_time) {
            max_time = f_time
            newest = f
        }
    }
    return newest
}

function confirm(prompt) {
    printf(YELLOW prompt " [y/N]: " NC)
    getline ans < "/dev/tty"
    return (ans ~ /^[Yy]$/)
}

{
    if ($1 ~ /^Duplicate hash ID:/) {
        hash_id = $1
        hash_val = $2
        split("", files)
        file_count = 0

        for (i = 3; i <= NF; i++) {
            if ($i ~ /^\/.*/) {
                file_count++
                files[file_count] = $i
            }
        }

        if (file_count <= 1) next

        newest = get_newest_file(files, file_count)

        print CYAN "\n" hash_id NC
        print "  " hash_val
        print GREEN "  Will keep: " newest NC

        for (i = 1; i <= file_count; i++) {
            if (files[i] != newest) {
                print RED "  Will delete: " files[i] NC
            }
        }

        if (confirm("Proceed with deletion of above files?")) {
            for (i = 1; i <= file_count; i++) {
                if (files[i] != newest) {
                    if (dry_run == "true") {
                        print "[DRY RUN] Would delete: " files[i] >> log_file
                    } else {
                        delete_cmd = "rm -rfv \"" files[i] "\" >> \"" log_file "\" 2>&1"
                        system(delete_cmd)
                        print "[DELETED] " files[i] >> log_file
                    }
                }
            }
        } else {
            print YELLOW "  Skipped group." NC
            print "[SKIPPED] Group ID: " hash_id >> log_file
        }
    }
}
' "$INPUT_FILE"

echo ""
if $DRY_RUN; then
    log_info "Dry run complete. Review log at: $LOG_FILE"
else
    log_info "Deletion process complete. Log saved to: $LOG_FILE"
fi
