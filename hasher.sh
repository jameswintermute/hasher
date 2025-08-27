#!/bin/bash
# hasher.sh - multi-core aware, flock-safe, zero-length aware

# ───── Config ─────
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
        --output) OUTPUT="$2"; shift 2 ;;
        --algo)
            case "$2" in
                sha256|sha1|md5) ALGO="${2}sum";;
                *) log_error "Unsupported algorithm $2"; exit 1;;
            esac
            shift 2
            ;;
        --pathfile) PATHFILE="$2"; shift 2 ;;
        --background) RUN_IN_BACKGROUND=true; shift ;;
        --internal) shift ;; # internal flag for background relaunch
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

main() {
    START_TIME=$(date +%s)
    NOW_HUMAN=$(date +"%Y-%m-%d %H:%M:%S")

    mkdir -p "$HASHES_DIR"
    echo "\"Hash\",\"Directory\",\"File\",\"Algorithm\",\"Timestamp\",\"Size_MB\"" > "$OUTPUT"
    echo "\"File\",\"Directory\",\"Size_MB\"" > "$ZERO_FILE"
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

    # ───── Load paths from pathfile ─────
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

    # ───── Gather files ─────
    FILES=()
    for path in "$@"; do
        if [ -d "$path" ]; then
            while IFS= read -r -d '' file; do
                skip=false
                for excl in "${EXCLUSIONS[@]}"; do
                    [[ "$file" == *"$excl"* ]] && skip=true
                done
                $skip || FILES+=("$file")
            done < <(find "$path" -type f -print0)
        elif [ -f "$path" ]; then
            FILES+=("$path")
        fi
    done

    # ───── Count & display ─────
    TOTAL=${#FILES[@]}
    COUNT=0
    log_info "Total files to hash: $TOTAL"

    # ───── Multi-core detection ─────
    NPROC=$(nproc 2>/dev/null || echo 1)
    use_multi="n"
    if [ "$RUN_IN_BACKGROUND" = false ] && (( NPROC > 1 )); then
        read -rp "System has $NPROC cores, use multi-core hashing? (y/N): " use_multi
    fi

    # ───── Progress logging ─────
    PROGRESS_COUNT_FILE=".hasher_progress_count"
    PROGRESS_FLAG_FILE=".hasher_running"
    echo 0 > "$PROGRESS_COUNT_FILE"
    touch "$PROGRESS_FLAG_FILE"

    progress_logger() {
        while [[ -f "$PROGRESS_FLAG_FILE" ]]; do
            if [[ -f "$PROGRESS_COUNT_FILE" ]]; then
                COUNT=$(cat "$PROGRESS_COUNT_FILE")
            else
                COUNT=0
            fi
            PERCENT=0
            (( TOTAL>0 )) && PERCENT=$((COUNT*100/TOTAL))
            echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $COUNT / $TOTAL files hashed ($PERCENT%)" >> "$BACKGROUND_LOG"
            sleep 15
        done
    }
    progress_logger &
    PROGRESS_LOGGER_PID=$!

    # ───── Hashing ─────
    for file in "${FILES[@]}"; do
        ((COUNT++))
        echo "$COUNT" > "$PROGRESS_COUNT_FILE"

        if [ ! -f "$file" ]; then
            log_error "File '$file' not found!"
            continue
        fi

        SIZE_BYTES=$(stat -c %s "$file" 2>/dev/null || echo 0)
        if (( SIZE_BYTES == 0 )); then
            flock "$ZERO_FILE" bash -c "echo \"$(basename "$file")\",\"$(dirname "$file")\",0\" >> \"$ZERO_FILE\""
            continue
        fi

        SIZE_MB=$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.2f", b/1048576}')

        # Multi-core execution
        if [[ "$use_multi" =~ ^[Yy]$ ]]; then
            HASH=$(cat "$file" | xargs -P "$NPROC" -I{} $ALGO "{}" 2>/dev/null | awk '{print $1}')
        else
            HASH=$($ALGO "$file" | awk '{print $1}')
        fi

        DATE=$(date +"%Y-%m-%d %H:%M:%S")
        PWD=$(dirname "$file")

        # Write with flock
        flock "$OUTPUT" bash -c "echo \"$HASH\",\"$PWD\",\"$file\",\"$ALGO\",\"$DATE\",\"$SIZE_MB\" >> \"$OUTPUT\""
        log_info "Hashed '$file'"
    done

    rm -f "$PROGRESS_FLAG_FILE"
    wait "$PROGRESS_LOGGER_PID" 2>/dev/null
    rm -f "$PROGRESS_COUNT_FILE"

    # ───── Final progress log ─────
    echo "$(date '+[%Y-%m-%d %H:%M:%S]') [PROGRESS] $TOTAL / $TOTAL files hashed (100%)" >> "$BACKGROUND_LOG"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME-START_TIME))

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
