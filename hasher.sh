#!/bin/bash

# ───── Flags & Config ─────
HASHER_DIR="hasher"
RUN_IN_BACKGROUND=false
OUTPUT="$HASHER_DIR/hasher-$(date +'%Y-%m-%d').txt"
ALGO="sha256sum"
POSITIONAL=()
PATHFILE=""

# ───── Colors ─────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ───── Logging ─────
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ───── Parse Flags ─────
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
        --pathfile)
            PATHFILE="$2"
            shift 2
            ;;
        --background)
            RUN_IN_BACKGROUND=true
            shift
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

# ───── Relaunch in Background ─────
if [ "$RUN_IN_BACKGROUND" = true ] && [[ "$1" != "--internal" ]]; then
    mkdir -p "$HASHER_DIR"
    nohup bash "$0" --internal "${POSITIONAL[@]}" > "$HASHER_DIR/background.log" 2>&1 &
    echo -e "${GREEN}[INFO]${NC} Running in background (PID: $!). Logs: $HASHER_DIR/background.log"
    exit 0
fi

# ───── Only Internal Runs Reach Here ─────
main() {
    # ───── Directory Check ─────
    if [ -d "$HASHER_DIR" ]; then
        log_warn "Directory '$HASHER_DIR' already exists. Using existing directory."
    else
        mkdir -p "$HASHER_DIR"
        log_info "Created directory '$HASHER_DIR'."
    fi

    # ───── Read pathfile if given ─────
    if [[ -n "$PATHFILE" ]]; then
        if [[ ! -f "$PATHFILE" ]]; then
            log_error "Path file '$PATHFILE' does not exist."
            exit 1
        fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            POSITIONAL+=("$line")
        done < "$PATHFILE"
    fi

    set -- "${POSITIONAL[@]}"

    # ───── Validate Input ─────
    if [ $# -eq 0 ]; then
        echo -e "${YELLOW}Usage:${NC} $0 [--output file] [--algo sha256|sha1|md5] [--pathfile file] [--background] <file_or_dir1> [...]"
        exit 1
    fi

    # ───── Collect Files ─────
    FILES=()

    for path in "$@"; do
        if [ -d "$path" ]; then
            while IFS= read -r -d '' file; do
                FILES+=("$file")
            done < <(find "$path" -type f -print0)
        elif [ -f "$path" ]; then
            FILES+=("$path")
        else
            log_warn "Path '$path' does not exist or is not a regular file/directory."
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

        log_info "Hashed '$file'"
        echo "$HASH, Dir: $PWD, File: '$file', $ALGO, Time: $DATE" | tee -a "$OUTPUT"
    done
}

# ───── Execute Main ─────
main
