#!/bin/bash

# ───── Flags & Config ─────
HASHES_DIR="hashes"
RUN_IN_BACKGROUND=false
DATE_TAG="$(date +'%Y-%m-%d')"
OUTPUT="$HASHES_DIR/hasher-$DATE_TAG.csv"
ZERO_LENGTH_OUTPUT="$HASHES_DIR/zero-length-files-$DATE_TAG.csv"
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
            OUTPUT="$2"; shift 2 ;;
        --algo)
            case "$2" in
                sha256|sha1|md5) ALGO="${2}sum";;
                *) log_error "Unsupported algorithm: $2"; exit 1 ;;
            esac
            shift 2 ;;
        --pathfile) PATHFILE="$2"; shift 2 ;;
        --background) RUN_IN_BACKGROUND=true; shift ;;
        --internal) shift ;; # internal flag for background
        -*|--*) log_error "Unknown option $1"; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
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

# ───── Main Function ─────
main() {
    START_TIME=$(date +%s)
    NOW_HUMAN=$(date +"%Y-%m-%d %H:%M:%S")

    mkdir -p "$HASHES_DIR"
    echo "\"Hash\",\"Directory\",\"File\",\"Algorithm\",\"Timestamp\",\"Size_MB\"" > "$OUTPUT"
    echo "\"File\",\"Directory\",\"Timestamp\"" > "$ZERO_LENGTH_OUTPUT"
    log_info "Using output file: $OUTPUT"
    log_info "Zero-length files will be logged to: $ZERO_LENGTH_OUTPUT"

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
        if [[ ! -f "$PATHFILE" ]]; then log_error "Path file '$PATHFILE' not found"; exit 1; fi
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

    # ───── Collect Files ─────
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

    # ───── Progress Logger ─────
    PROGRESS_COUNT_FILE=".hasher_progress_count"
    PROGRESS_FLAG_FILE=".hasher_running"
    echo 0 > "$PROGRESS_COUNT_FILE"
    touch "$PROGRESS_FLAG_FILE"

    progress_logger() {
        while [[ -f "$PROGRESS_FLAG_FILE" ]]; do
            COUNT=$(cat "$PROGRESS_COUNT_FILE" 2>/dev/null || echo 0)
            PERCENT=0
            (( TOTAL > 0 )) && PERCENT=$((COUNT*100/TOTAL))
            echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $COUNT / $TOTAL files hashed ($PERCENT%)" >> "$BACKGROUND_LOG"
            sleep 15
        done
    }
    progress_logger &
    PROGRESS_LOGGER_PID=$!

    # ───── Multi-core check ─────
    NUM_CORES=$(nproc 2>/dev/null || echo 1)
    MULTICORE=false
    if (( NUM_CORES > 1 )); then
        read -p "System has $NUM_CORES cores, use multi-core hashing? (y/N): " REPLY
        [[ "$REPLY" =~ ^[Yy]$ ]] && MULTICORE=true
    fi

    # ───── Hash File Function ─────
    hash_file() {
        local file="$1"
        if [ ! -f "$file" ]; then return; fi
        SIZE_BYTES=$(stat -c %s "$file" 2>/dev/null)
        if [[ "$SIZE_BYTES" -eq 0 ]]; then
            echo "\"$file\",\"$(dirname "$file")\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$ZERO_LENGTH_OUTPUT"
            return
        fi
        HASH=$(stdbuf -oL "$ALGO" "$file" | awk '{print $1}')
        DATE=$(date +"%Y-%m-%d %H:%M:%S")
        PWD=$(dirname "$file")
        SIZE_MB=$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b/1048576 }')
        (
            flock 200
            echo "\"$HASH\",\"$PWD\",\"$file\",\"$ALGO\",\"$DATE\",\"$SIZE_MB\"" >> "$OUTPUT"
        ) 200>"$OUTPUT.lock"
        log_info "Hashed '$file'"
    }

    # ───── Main Hashing Loop ─────
    if [ "$MULTICORE" = true ]; then
        log_info "Starting multi-core hashing on $NUM_CORES cores..."
        semaphore="/tmp/.hasher_semaphore_$$"
        mkfifo "$semaphore"
        exec 3<>"$semaphore"
        rm "$semaphore"
        for ((i=0;i<NUM_CORES;i++)); do echo >&3; done

        for file in "${FILES[@]}"; do
            read -u 3
            {
                COUNT=$((COUNT + 1))
                echo "$COUNT" > "$PROGRESS_COUNT_FILE"
                hash_file "$file"
                echo >&3
            } &
        done
        wait
        exec 3>&-
    else
        for file in "${FILES[@]}"; do
            COUNT=$((COUNT + 1))
            echo "$COUNT" > "$PROGRESS_COUNT_FILE"
            hash_file "$file"
        done
    fi

    rm -f "$PROGRESS_FLAG_FILE" "$PROGRESS_COUNT_FILE"

    # ───── Final Progress Log ─────
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $TOTAL / $TOTAL files hashed (100%)" >> "$BACKGROUND_LOG"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME-START_TIME))

    {
        echo "========================================="
        echo "Hasher run completed: $NOW_HUMAN"
        echo "Algorithm used      : $ALGO"
        echo "Files hashed        : $TOTAL"
        echo "Output file         : $OUTPUT"
        echo "Zero-length files   : $ZERO_LENGTH_OUTPUT"
        echo "Run time (seconds)  : $DURATION"
        echo "========================================="
        echo ""
    } >> "$LOG_FILE"

    log_info "Summary written to '$LOG_FILE'"
}

main
