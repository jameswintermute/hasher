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
USE_MULTICORE=false

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
        --output) OUTPUT="$2"; shift 2 ;;
        --algo)
            case "$2" in
                sha256|sha1|md5) ALGO="${2}sum" ;;
                *) log_error "Unsupported algorithm: $2"; exit 1 ;;
            esac
            shift 2 ;;
        --pathfile) PATHFILE="$2"; shift 2 ;;
        --background) RUN_IN_BACKGROUND=true; shift ;;
        --internal) shift ;;  # internal flag for background relaunch
        -*|--*) log_error "Unknown option $1"; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# ───── Relaunch in background if requested ─────
if [ "$RUN_IN_BACKGROUND" = true ] && [[ "$1" != "--internal" ]]; then
    mkdir -p "$HASHES_DIR"
    nohup bash "$0" --internal "${POSITIONAL[@]}" </dev/null 2>&1 \
        | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }' >> "$BACKGROUND_LOG" &
    echo -e "${GREEN}[INFO]${NC} Running in background (PID: $!). Logs: $BACKGROUND_LOG"
    exit 0
fi

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
        if [[ ! -f "$PATHFILE" ]]; then log_error "Path file '$PATHFILE' not found."; exit 1; fi
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

    # ───── Build file list ─────
    FILES=()
    ZERO_LENGTH_FILES=()
    for path in "$@"; do
        if [ -d "$path" ]; then
            while IFS= read -r -d '' file; do
                skip=false
                for excl in "${EXCLUSIONS[@]}"; do [[ "$file" == *"$excl"* ]] && skip=true; done
                $skip && continue
                size=$(stat -c %s "$file" 2>/dev/null || echo 0)
                if [[ "$size" -eq 0 ]]; then
                    DATE=$(date +"%Y-%m-%d %H:%M:%S")
                    echo "\"$file\",\"$(dirname "$file")\",\"$DATE\"" >> "$ZERO_LENGTH_OUTPUT"
                    continue
                fi
                FILES+=("$file")
            done < <(find "$path" -type f -print0)
        elif [ -f "$path" ]; then
            size=$(stat -c %s "$path" 2>/dev/null || echo 0)
            if [[ "$size" -eq 0 ]]; then
                DATE=$(date +"%Y-%m-%d %H:%M:%S")
                echo "\"$path\",\"$(dirname "$path")\",\"$DATE\"" >> "$ZERO_LENGTH_OUTPUT"
                continue
            fi
            FILES+=("$path")
        fi
    done

    TOTAL=${#FILES[@]}
    log_info "Total files to hash: $TOTAL"

    # ───── Check for multi-core ─────
    CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    if (( CORES > 1 )); then
        read -p "System has $CORES cores. Use multi-core hashing? (y/N): " resp
        if [[ "$resp" =~ ^[Yy]$ ]]; then USE_MULTICORE=true; fi
    fi

    # ───── Prepare progress file ─────
    PROGRESS_COUNT_FILE=".hasher_progress_count"
    echo 0 > "$PROGRESS_COUNT_FILE"

    progress_logger() {
        local last_count=0
        while true; do
            sleep 10
            [[ ! -f "$PROGRESS_COUNT_FILE" ]] && break
            count=$(cat "$PROGRESS_COUNT_FILE")
            elapsed=$(( $(date +%s) - START_TIME ))
            percent=$((count*100/TOTAL))
            rate=$((count/elapsed+1))
            remaining=$(( (TOTAL-count)/rate ))
            printf "\r[Progress] %d / %d files (%d%%), ETA ~ %d sec" "$count" "$TOTAL" "$percent" "$remaining"
            [[ $count -ge $TOTAL ]] && break
        done
        echo ""
    }
    progress_logger & PROGRESS_LOGGER_PID=$!

    # ───── Hash function ─────
    hash_file() {
        local file="$1"
        local hash ts dir size size_mb
        ts=$(date +"%Y-%m-%d %H:%M:%S")
        dir=$(dirname "$file")
        size=$(stat -c %s "$file" 2>/dev/null)
        size_mb=$(awk -v b="$size" 'BEGIN { printf "%.2f", b / 1048576 }')
        hash=$(stdbuf -oL "$ALGO" "$file" | awk '{print $1}')
        # safe append using flock
        flock "$OUTPUT" -c "echo \"\$hash\",\"$dir\",\"$file\",\"$ALGO\",\"$ts\",\"$size_mb\" >> \"$OUTPUT\""
        # increment progress
        flock "$PROGRESS_COUNT_FILE" -c "count=\$(cat \"$PROGRESS_COUNT_FILE\"); echo \$((count+1)) > \"$PROGRESS_COUNT_FILE\""
    }

    # ───── Run hashing ─────
    if $USE_MULTICORE; then
        export ALGO OUTPUT PROGRESS_COUNT_FILE
        export -f hash_file
        printf "%s\n" "${FILES[@]}" | xargs -0 -n1 -P $CORES bash -c 'hash_file "$0"'
    else
        for file in "${FILES[@]}"; do hash_file "$file"; done
    fi

    # ───── Final cleanup ─────
    wait $PROGRESS_LOGGER_PID
    rm -f "$PROGRESS_COUNT_FILE"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $TOTAL / $TOTAL files hashed (100%)" >> "$BACKGROUND_LOG"

    # ───── Summary ─────
    {
        echo "========================================="
        echo "Hasher run completed: $NOW_HUMAN"
        echo "Algorithm used      : $ALGO"
        echo "Files hashed        : $TOTAL"
        echo "Output file         : $OUTPUT"
        echo "Run time (seconds)  : $DURATION"
        echo "Zero-length files   : $ZERO_LENGTH_OUTPUT"
        echo "========================================="
    } >> "$LOG_FILE"
    log_info "Summary written to '$LOG_FILE'"
}

main
