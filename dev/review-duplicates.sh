#!/bin/bash

# ───── Flags & Config ─────
HASHES_DIR="hashes"
RUN_IN_BACKGROUND=false
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"
ZERO_FILE="$HASHES_DIR/zero-length-files-$DATE_TAG.csv"
LOG_FILE="hasher-logs.txt"
BACKGROUND_LOG="background.log"
POSITIONAL=()
ALGO="sha256sum"
PATHFILE=""
EXCLUSIONS_FILE="exclusions.txt"

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
        --internal)
            shift
            ;;
        -*|--*)
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
    mkdir -p "$HASHES_DIR"
    nohup bash "$0" --internal "${POSITIONAL[@]}" </dev/null 2>&1 \
        | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }' >> "$BACKGROUND_LOG" &
    echo -e "${GREEN}[INFO]${NC} Running in background (PID: $!). Logs: $BACKGROUND_LOG"
    exit 0
fi

# ───── Main function ─────
main() {
    START_TIME=$(date +%s)
    NOW_HUMAN=$(date +"%Y-%m-%d %H:%M:%S")

    mkdir -p "$HASHES_DIR"
    echo "\"Hash\",\"Directory\",\"File\",\"Algorithm\",\"Timestamp\",\"Size_MB\"" > "$OUTPUT"
    echo "\"File\",\"Directory\",\"Timestamp\"" > "$ZERO_FILE"
    log_info "Using output file: $OUTPUT"
    log_info "Zero-length files will be logged to: $ZERO_FILE"

    # ───── Load exclusions ─────
    EXCLUSIONS=()
    if [[ -f "$EXCLUSIONS_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            EXCLUSIONS+=("$line")
        done < "$EXCLUSIONS_FILE"
        log_info "Loaded ${#EXCLUSIONS[@]} exclusions from $EXCLUSIONS_FILE"
    fi

    # ───── Load paths from --pathfile if given ─────
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
    if [ $# -eq 0 ]; then
        echo -e "${YELLOW}Usage:${NC} $0 [--output file] [--algo sha256|sha1|md5] [--pathfile file] [--background] <file_or_dir1> [...]"
        exit 1
    fi

    FILES=()
    for path in "$@"; do
        if [ -d "$path" ]; then
            while IFS= read -r -d '' file; do
                skip=false
                for excl in "${EXCLUSIONS[@]}"; do
                    [[ "$file" == *"$excl"* ]] && skip=true && break
                done
                $skip || FILES+=("$file")
            done < <(find "$path" -type f -print0)
        elif [ -f "$path" ]; then
            FILES+=("$path")
        else
            log_warn "Path '$path' does not exist or is not a regular file/directory."
        fi
    done

    TOTAL=${#FILES[@]}
    COUNT=0

    PROGRESS_COUNT_FILE=".hasher_progress_count"
    PROGRESS_FLAG_FILE=".hasher_running"
    echo 0 > "$PROGRESS_COUNT_FILE"
    touch "$PROGRESS_FLAG_FILE"

    # ───── Progress logger ─────
    progress_logger() {
        while [[ -f "$PROGRESS_FLAG_FILE" ]]; do
            if [[ -f "$PROGRESS_COUNT_FILE" ]]; then
                COUNT=$(cat "$PROGRESS_COUNT_FILE")
            else
                COUNT=0
            fi
            PERCENT=0
            (( TOTAL > 0 )) && PERCENT=$((COUNT * 100 / TOTAL))
            echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $COUNT / $TOTAL files hashed ($PERCENT%)" >> "$BACKGROUND_LOG"
            sleep 15
        done
    }
    progress_logger &
    PROGRESS_LOGGER_PID=$!

    # ───── Function to hash a single file ─────
    hash_file() {
        local file="$1"
        if [ ! -f "$file" ]; then
            log_error "File '$file' not found!"
            return
        fi

        SIZE_BYTES=$(stat -c %s "$file" 2>/dev/null)
        if [[ "$SIZE_BYTES" -eq 0 ]]; then
            DATE_NOW=$(date +"%Y-%m-%d %H:%M:%S")
            echo "\"$file\",\"$(dirname "$file")\",\"$DATE_NOW\"" >> "$ZERO_FILE"
            return
        fi

        HASH=$(stdbuf -oL "$ALGO" "$file" | awk '{print $1}')
        DATE=$(date +"%Y-%m-%d %H:%M:%S")
        PWD=$(dirname "$file")
        SIZE_MB=$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b / 1048576 }')

        # ───── FLOCK to avoid concurrent writes ─────
        (
            flock 200
            echo "\"$HASH\",\"$PWD\",\"$file\",\"$ALGO\",\"$DATE\",\"$SIZE_MB\"" >> "$OUTPUT"
        ) 200>"$OUTPUT".lock

        log_info "Hashed '$file'"
    }

    # ───── Multi-core detection ─────
    NUM_CORES=$(nproc 2>/dev/null || echo 1)
    MULTICORE=false
    if [ "$NUM_CORES" -gt 1 ]; then
        read -p "System has $NUM_CORES cores, use multi-core hashing? (y/N): " yn
        case "$yn" in
            [Yy]*) MULTICORE=true ;;
        esac
    fi

    # ───── Main hashing loop ─────
    if [ "$MULTICORE" = true ]; then
        printf "%s\0" "${FILES[@]}" | xargs -0 -n1 -P"$NUM_CORES" bash -c 'hash_file "$0"' 
    else
        for file in "${FILES[@]}"; do
            COUNT=$((COUNT + 1))
            echo "$COUNT" > "$PROGRESS_COUNT_FILE"
            hash_file "$file"
        done
    fi

    rm -f "$PROGRESS_FLAG_FILE"
    wait "$PROGRESS_LOGGER_PID" 2>/dev/null
    rm -f "$PROGRESS_COUNT_FILE"

    # ───── Final Progress Log ─────
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $TOTAL / $TOTAL files hashed (100%)" >> "$BACKGROUND_LOG"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    {
        echo "========================================="
        echo "Hasher run completed: $NOW_HUMAN"
        echo "Algorithm used      : $ALGO"
        echo "Files hashed        : $TOTAL"
        echo "Output file         : $OUTPUT"
        echo "Zero-length files   : $ZERO_FILE"
        echo "Run time (seconds)  : $DURATION"
        echo "========================================="
        echo ""
    } >> "$LOG_FILE"

    log_info "Summary written to '$LOG_FILE'"
}

main
