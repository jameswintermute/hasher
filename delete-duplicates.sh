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

# ───── File Paths ─────
DUP_DIR="duplicate-hashes"

# ───── Check for Duplicate Folder ─────
if [ ! -d "$DUP_DIR" ]; then
    log_error "Folder '$DUP_DIR' does not exist."
    exit 1
fi

# ───── Intro Banner ─────
echo -e "${RED}=============================================================="
echo -e "WARNING: This script will delete surplus duplicate files."
echo -e "It will automatically KEEP the NEWEST file in each group."
echo -e "All other duplicates will be deleted."
echo -e "Always ONE COPY WILL BE PRESERVED."
echo -e "==============================================================${NC}"

# ───── Let User Select Duplicate Hash File ─────
FILES=($(ls -t "$DUP_DIR"/*-duplicate-hashes.txt 2>/dev/null))

if [ ${#FILES[@]} -eq 0 ]; then
    log_error "No duplicate hashes file found in '$DUP_DIR'."
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
echo ""

# ───── Parse and Process Each Group ─────
awk -v RED="$RED" -v GREEN="$GREEN" -v CYAN="$CYAN" -v NC="$NC" '
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
        print GREEN "  Keeping: " newest NC

        for (i = 1; i <= file_count; i++) {
            if (files[i] != newest) {
                printf RED "  Deleting: %s\n" NC, files[i]
                system("rm -rfv \"" files[i] "\"")
            }
        }
    }
}
' "$INPUT_FILE"

echo ""
log_info "Duplicate deletion (auto keep newest) completed."
