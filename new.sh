#!/bin/bash

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Defaults ─────
OUTPUT="hasher-$(date +'%Y-%m-%d').txt"
ALGO="sha256sum"

# ───── Parse Flags ─────
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --algo)
            case "$2" in
                sha256|sha1|md5)
                    ALGO="${2}sum"
                    ;;
                *)
                    log_error "Unsupported algorithm: $2. Use sha256, sha1, or md5."
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        -*)
            log_error "Unknown option $1"
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

set -- "${POSITIONAL[@]}"  # restore positional args

# ───── Validate Input ─────
if [ $# -eq 0 ]; then
    echo -e "${YELLOW}Usage:${NC} $0 [--output filename] [--algo sha256|sha1|md5] <file_or_dir1> [file_or_dir2 ...]"
    exit 1
fi

# ───── Collect Files ─────
FILES=()

for path in "$@"; do
    if [ -d "$path" ]; then
        while IFS= read -r -d '' file; do
            FILES+=("$file")
        done < <(find "$path" -type f -print0)
    else
        FILES+=("$path")
    fi
done

# ───── Hash Files ─────
TOTAL=${#FILES[@]}
COUNT=0

for file in "${FILES[@]}"; do
    COUNT=$((COUNT + 1))
    printf "[%d/%d] Processing: %s\n" "$COUNT" "$TOTAL" "$file"

    if [ ! -f "$file" ]; then
        log_error "File '$file' not found!"
        continue
    fi

    HASH=$(eval "$ALGO" \"\$file\" | awk '{print $1}')
    DATE=$(date +"%Y-%m-%d %H:%M:%S")
    PWD=$(pwd -L)
    #TYPE=$(file "$file" -b)

    log_info "Hashed '$file'"
    echo "$DATE,File:'$file',Hash:($ALGO): $HASH,Dir:$PWD" | tee -a "$OUTPUT"
done

# Run via:
# find . -type f -print0 | xargs -0 ./new.sh
