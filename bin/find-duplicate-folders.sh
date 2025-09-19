\
    #!/usr/bin/env bash
    # find-duplicate-folders.sh — folder-level dedupe using CSV size_bytes (fast path)
    # Additions:
    #  • TTY color (no dependencies)
    #  • Spinner while sorting
    #  • CSV indexing % progress
    #  • du-based recursive size estimate with progress
    #  • TIP to proceed to option 6
    set -Eeuo pipefail
    IFS=$'\n\t'; LC_ALL=C

    ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"
    LOGS_DIR="${LOGS_DIR:-$(pwd)/logs}"
    mkdir -p "$LOGS_DIR"

    INPUT="${INPUT:-}"
    MODE="plan"
    MIN_GROUP_SIZE=2
    KEEP_POLICY="shortest-path"   # shortest-path|longest-path|first-seen
    SCOPE="recursive"
    SIGNATURE="name+content"

    TMP_GROUP=""
    plan_dirs_bytes=0

    # ── Colors (TTY only) ────────────────────────────────────────────────
    init_colors() {
      if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        CINFO="\033[1;34m"; CWORK="\033[1;36m"; COK="\033[1;32m"; CWARN="\033[1;33m"; CERR="\033[1;31m"; CRESET="\033[0m"
      else
        CINFO=""; CWORK=""; COK=""; CWARN=""; CERR=""; CRESET=""
      fi
    }
    info(){ printf "%b[INFO]%b %s\n" "$CINFO" "$CRESET" "$*"; }
    work(){ printf "%b[WORK]%b %s\n" "$CWORK" "$CRESET" "$*"; }
    ok(){   printf "%b[OK]%b %s\n"   "$COK"   "$CRESET" "$*"; }
    warn(){ printf "%b[WARN]%b %s\n" "$CWARN" "$CRESET" "$*"; }
    err(){  printf "%b[ERROR]%b %s\n" "$CERR" "$CRESET" "$*"; }
    init_colors

    usage() {
      printf "%s\n" \
        "Usage: find-duplicate-folders.sh --input <hashes.csv> [--mode plan] [--min-group-size N] [--keep POLICY]" \
        "" \
        "  -i, --input FILE         CSV/TSV with columns: path,size_bytes,algo,hash" \
        "  -m, --mode MODE          Only 'plan' is supported [default: plan]" \
        "  -g, --min-group-size N   Minimum duplicate dirs in a group [default: 2]" \
        "  -k, --keep POLICY        shortest-path|longest-path|first-seen [default: shortest-path]" \
        "  -s, --scope SCOPE        Informational label [default: recursive]" \
        "  -h, --help               Show help"
    }

    # Parse CLI
    while [ $# -gt 0 ]; do
      case "$1" in
        -i|--input)           INPUT="${2:-}"; shift 2;;
        -m|--mode)            MODE="${2:-}"; shift 2;;
        -g|--min-group-size)  MIN_GROUP_SIZE="${2:-}"; shift 2;;
        -k|--keep)            KEEP_POLICY="${2:-}"; shift 2;;
        -s|--scope)           SCOPE="${2:-}"; shift 2;;
        -h|--help)            usage; exit 0;;
        *) err "Unknown arg: $1"; usage; exit 2;;
      esac
    done

    if [ -z "${INPUT:-}" ] || [ ! -f "$INPUT" ]; then
      err "--input FILE is required and must exist."
      exit 2
    fi

    # ── Quarantine explainer ─────────────────────────────────────────────
    resolve_quarantine_dir() {
      local raw=""
      if [ -f "$ROOT_DIR/local/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$ROOT_DIR/local/hasher.conf" | tail -n1 || true)"
      fi
      if [ -z "$raw" ] && [ -f "$ROOT_DIR/default/hasher.conf" ]; then
        raw="$(grep -E '^[[:space:]]*QUARANTINE_DIR[[:space:]]*=' "$ROOT_DIR/default/hasher.conf" | tail -n1 || true)"
      fi
      local val
      val="$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]*QUARANTINE_DIR[[:space:]]*=[[:space:]]*//; s/^[\"\x27]//; s/[\"\x27]$//')"
      if [ -z "$val" ]; then
        val="$ROOT_DIR/quarantine-$(date +%F)"
      else
        val="${val//\$\((date +%F)\)/$(date +%F)}"
        val="${val//\$(date +%F)/$(date +%F)}"
      fi
      printf '%s\n' "$val"
    }
    qdir="$(resolve_quarantine_dir)"
    mkdir -p -- "$qdir" 2>/dev/null || true
    dfh="$(df -h "$qdir" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
    info "Quarantine: $qdir — $dfh"

    # ── Delimiter & required columns ──────────────────────────────────────
    header="$(head -n1 -- "$INPUT" || true)"
    if printf %s "$header" | grep -q $'\t'; then
      DELIM=$'\t'
    else
      DELIM=','
    fi

    # Identify column indexes (1-based), case-insensitive headers
    get_col_idx() {
      local want="$1" hdr="$2" dlm="$3"
      printf '%s\n' "$hdr" | awk -v want="$want" -v dlm="$dlm" 'BEGIN{FS=dlm}
        NR==1{for(i=1;i<=NF;i++){h=tolower($i); gsub(/^[ \t"]+|[ \t"]+$/,"",h); if(h==want){print i; exit}}}'
    }

    COL_PATH="$(get_col_idx "path" "$header" "$DELIM")"
    COL_SIZE="$(get_col_idx "size_bytes" "$header" "$DELIM")"
    COL_HASH="$(get_col_idx "hash" "$header" "$DELIM")"
    if [ -z "${COL_PATH:-}" ] || [ -z "${COL_HASH:-}" ]; then
      err "Input missing required columns: path, hash."
      exit 2
    fi
    HAVE_SIZE_COL=0; [ -n "${COL_SIZE:-}" ] && HAVE_SIZE_COL=1

    info "Using hashes file: $INPUT"
    info "Input: $INPUT"
    info "Mode: $MODE  | Min group size: $MIN_GROUP_SIZE  | Scope: $SCOPE  | Keep: $KEEP_POLICY  | Signature: $SIGNATURE"
    if [ "$HAVE_SIZE_COL" -eq 1 ]; then
      info "Using size_bytes from CSV/TSV (fast path)."
    else
      info "CSV had no size_bytes; falling back to filesystem stat (slower)."
    fi

    # ── Temp files ────────────────────────────────────────────────────────
    TMP_DIRMAP="$(mktemp -t fdf-dirmap.XXXXXX)"
    TMP_DIRSORT="$(mktemp -t fdf-dirsort.XXXXXX)"
    TMP_SIGS="$(mktemp -t fdf-sigs.XXXXXX)"
    PLAN_FILE="$LOGS_DIR/duplicate-folders-plan-$(date +%F)-$$.txt"
    cleanup() { rm -f -- "$TMP_DIRMAP" "$TMP_DIRSORT" "$TMP_SIGS" 2>/dev/null || true; }
    trap cleanup EXIT

    # ── Progress: indexing files from CSV ─────────────────────────────────
    FILES_TOTAL="$(wc -l < "$INPUT" | tr -d ' ')"
    [ "${FILES_TOTAL:-0}" -gt 0 ] && FILES_TOTAL=$((FILES_TOTAL-1)) || FILES_TOTAL=0
    if [ "$HAVE_SIZE_COL" -eq 1 ]; then
      awk -v FS="$DELIM" -v p="$COL_PATH" -v s="$COL_SIZE" -v h="$COL_HASH" -v TOT="$FILES_TOTAL" '
        BEGIN{last=-1}
        NR>1 {
          n=NR-1
          if (TOT>0) {
            pct=int((n*100)/TOT)
            if (pct!=last && pct%5==0) { printf("\r[WORK] indexing files %d%% (%d/%d)", pct, n, TOT) > "/dev/stderr"; last=pct }
          }
          path=$p; gsub(/^"|"$/,"",path)
          nsplit=split(path, a, "/"); file=a[nsplit]
          dir=substr(path, 1, length(path)-length(file)-1); if (dir=="") dir="/"
          size=$s; if (size=="" || size !~ /^[0-9]+$/) size=0
          print dir "\t" file "\t" $h "\t" size
        }
        END{ if (TOT>0) printf("\r[WORK] indexing files 100%% (%d/%d)\n", TOT, TOT) > "/dev/stderr" }
      ' "$INPUT" > "$TMP_DIRMAP"
    else
      awk -v FS="$DELIM" -v p="$COL_PATH" -v h="$COL_HASH" -v TOT="$FILES_TOTAL" '
        BEGIN{last=-1}
        NR>1 {
          n=NR-1
          if (TOT>0) {
            pct=int((n*100)/TOT)
            if (pct!=last && pct%5==0) { printf("\r[WORK] indexing files %d%% (%d/%d)", pct, n, TOT) > "/dev/stderr"; last=pct }
          }
          path=$p; gsub(/^"|"$/,"",path)
          nsplit=split(path, a, "/"); file=a[nsplit]
          dir=substr(path, 1, length(path)-length(file)-1); if (dir=="") dir="/"
          # stat size
          cmd="stat -c %s -- \042" path "\042 2>/dev/null || stat -f %z -- \042" path "\042 2>/dev/null"
          cmd | getline size; close(cmd)
          if (size=="" || size !~ /^[0-9]+$/) size=0
          print dir "\t" file "\t" $h "\t" size
        }
        END{ if (TOT>0) printf("\r[WORK] indexing files 100%% (%d/%d)\n", TOT, TOT) > "/dev/stderr" }
      ' "$INPUT" > "$TMP_DIRMAP"
    fi

    # ── Spinner while sorting ─────────────────────────────────────────────
    work "Sorting index…"
    ( LC_ALL=C sort -t$'\t' -k1,1 -k2,2 -k3,3 -- "$TMP_DIRMAP" > "$TMP_DIRSORT" ) &
    SORT_PID=$!
    if [ -t 2 ]; then
      spin='|/-\\'; i=0
      while kill -0 "$SORT_PID" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\\r[WORK] sorting %s" "${spin:$i:1}" >&2
        sleep 0.2
      done
      printf "\\r" >&2
    fi
    wait "$SORT_PID"
    ok "Sorting complete."

    # ── Collapse per directory ────────────────────────────────────────────
    : > "$TMP_SIGS"
    prev_dir=""; concat=""; sum_bytes=0
    flush_prev() { if [ -n "$prev_dir" ]; then sig="$(printf '%s' "$concat" | cksum | awk '{print $1}')"; printf '%s\t%s\t%s\n' "$sig" "$prev_dir" "$sum_bytes" >> "$TMP_SIGS"; fi; }
    while IFS=$'\t' read -r dir file hash size; do
      : "${size:=0}"
      if [ -n "$prev_dir" ] && [ "$dir" != "$prev_dir" ]; then flush_prev; concat=""; sum_bytes=0; fi
      prev_dir="$dir"; concat+="${file}|${hash}"$'\n'; sum_bytes=$(( 10#${sum_bytes:-0} + 10#${size:-0} ))
    done < "$TMP_DIRSORT"
    flush_prev

    # ── Group & plan ─────────────────────────────────────────────────────
    plan_dirs_bytes=0
    awk -F'\t' -v mgs="$MIN_GROUP_SIZE" -v keep="$KEEP_POLICY" -v plan="$PLAN_FILE" '
      { sig=$1; dir=$2; sz=$3+0; count[sig]++; idx=count[sig]; ddir[sig,idx]=dir; dsz[sig,idx]=sz; }
      END{
        for (s in count) {
          n=count[s]; if (n>=mgs) {
            best=1
            if (keep=="shortest-path") { bestlen=length(ddir[s,1]); for (i=2;i<=n;i++) if (length(ddir[s,i])<bestlen){best=i;bestlen=length(ddir[s,i])} }
            else if (keep=="longest-path") { bestlen=length(ddir[s,1]); for (i=2;i<=n;i++) if (length(ddir[s,i])>bestlen){best=i;bestlen=length(ddir[s,i])} }
            for (i=1;i<=n;i++){ if (i==best) continue; print ddir[s,i] >> plan; total+=dsz[s,i]; dirs++ } groups++
          }
        }
        printf("[INFO] Duplicate folder groups planned (>= %d): %d\n", mgs, groups) > "/dev/stderr"
        printf("[INFO] Directories in plan (excluding kept): %d\n", dirs) > "/dev/stderr"
        print total
      }
    ' "$TMP_SIGS" 2> >(tee /dev/stderr) | {
      read -r total_bytes || total_bytes=0
      plan_dirs_bytes="$total_bytes"
      awk -v b="$plan_dirs_bytes" 'BEGIN{ gb=b/1024/1024/1024; mb=b/1024/1024; if (gb>=1) printf("[INFO] Estimated plan size (direct files only): %.2f GB\n", gb); else printf("[INFO] Estimated plan size (direct files only): %.2f MB\n", mb); }'
    }

    if [ -s "$PLAN_FILE" ]; then
      ok "Plan created: $PLAN_FILE"
    else
      ok "No duplicate folder groups (>= $MIN_GROUP_SIZE). No plan created."
      rm -f -- "$PLAN_FILE" 2>/dev/null || true
      exit 0
    fi

    # ── Recursive on-disk size (du) with progress ────────────────────────
    if command -v du >/dev/null 2>&1; then
      PLAN_DIRS_TOTAL="$(wc -l < "$PLAN_FILE" | tr -d ' ')"
      du_total_k=0; idx=0
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        idx=$((idx+1))
        if [ $((idx % 5)) -eq 0 ] || [ "$idx" -eq "$PLAN_DIRS_TOTAL" ]; then
          work "sizing plan ($idx/$PLAN_DIRS_TOTAL)"
        fi
        kb="$(du -sk -- "$d" 2>/dev/null | awk 'NR==1{print $1}')"
        if ! [[ "$kb" =~ ^[0-9]+$ ]]; then
          kb="$(du -k -- "$d" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
        fi
        du_total_k=$(( 10#${du_total_k:-0} + 10#${kb:-0} ))
      done < "$PLAN_FILE"
      du_bytes=$((du_total_k * 1024))
      awk -v b="$du_bytes" 'BEGIN{ gb=b/1024/1024/1024; mb=b/1024/1024; if (gb>=1) printf("[INFO] Estimated plan size (recursive, on-disk): %.2f GB\n", gb); else printf("[INFO] Estimated plan size (recursive, on-disk): %.2f MB\n", mb); }'
    fi

    # ── Quarantine free-space warning (cross-FS) ─────────────────────────
    free_bytes="$(df -Pk "$qdir" | awk 'NR==2{print $4 * 1024}')"
    first_dir="$(head -n1 "$PLAN_FILE" || true)"
    if [ -n "$first_dir" ]; then
      src_fs="$(df -Pk "$first_dir" | awk 'NR==2{print $1}')"
      q_fs="$(df -Pk "$qdir" | awk 'NR==2{print $1}')"
      bytes_for_check="${du_bytes:-$plan_dirs_bytes}"
      if [ "$src_fs" != "$q_fs" ] && [ "${bytes_for_check:-0}" -gt "${free_bytes:-0}" ]; then
        warn "Plan size may exceed free space on quarantine filesystem for a cross-filesystem move."
      fi
    fi

    info "TIP: Next, run option 6 in the launcher to apply the folder plan (move directories to quarantine)."
    exit 0
