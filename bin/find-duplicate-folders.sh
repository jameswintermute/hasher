\
    #!/usr/bin/env bash
    # find-duplicate-folders.sh — folder-level dedupe using CSV size_bytes (fast path)
    # Minimal changes, now *heredoc-free* to avoid terminator issues.
    #
    set -Eeuo pipefail
    IFS=$'\n\t'; LC_ALL=C

    # ────────────────────────────── Defaults ──────────────────────────────
    INPUT="${INPUT:-}"
    MODE="plan"
    MIN_GROUP_SIZE=2
    KEEP_POLICY="shortest-path"   # shortest-path|longest-path|first-seen
    SCOPE="recursive"
    SIGNATURE="name+content"
    LOGS_DIR="${LOGS_DIR:-$(pwd)/logs}"
    mkdir -p "$LOGS_DIR"

    TMP_GROUP=""
    plan_dirs_bytes=0

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

    # ────────────────────────────── CLI ───────────────────────────────────
    while [ $# -gt 0 ]; do
      case "$1" in
        -i|--input)           INPUT="${2:-}"; shift 2;;
        -m|--mode)            MODE="${2:-}"; shift 2;;
        -g|--min-group-size)  MIN_GROUP_SIZE="${2:-}"; shift 2;;
        -k|--keep)            KEEP_POLICY="${2:-}"; shift 2;;
        -s|--scope)           SCOPE="${2:-}"; shift 2;;
        -h|--help)            usage; exit 0;;
        *) echo "[ERROR] Unknown arg: $1"; usage; exit 2;;
      esac
    done

    if [ -z "${INPUT:-}" ] || [ ! -f "$INPUT" ]; then
      echo "[ERROR] --input FILE is required and must exist." >&2
      exit 2
    fi

    # ────────────────────────────── Delimiter & Columns ───────────────────
    header="$(head -n1 -- "$INPUT" || true)"
    if printf %s "$header" | grep -q $'\t'; then
      DELIM=$'\t'
    else
      DELIM=','
    fi

    # Identify column indexes (1-based), case-insensitive headers (no process substitution)
    get_col_idx() {
      # $1 = wanted name, $2 = header, $3 = delimiter
      local want="$1" hdr="$2" dlm="$3"
      printf '%s\n' "$hdr" | awk -v want="$want" -v dlm="$dlm" 'BEGIN{FS=dlm}
        NR==1{
          for(i=1;i<=NF;i++){
            h=tolower($i); gsub(/^[ \t"]+|[ \t"]+$/,"",h)
            if(h==want){print i; exit}
          }
        }'
    }

    COL_PATH="$(get_col_idx "path" "$header" "$DELIM")"
    COL_SIZE="$(get_col_idx "size_bytes" "$header" "$DELIM")"
    COL_HASH="$(get_col_idx "hash" "$header" "$DELIM")"

    if [ -z "${COL_PATH:-}" ] || [ -z "${COL_HASH:-}" ]; then
      echo "[ERROR] Input missing required columns: path, hash." >&2
      exit 2
    fi

    HAVE_SIZE_COL=0
    if [ -n "${COL_SIZE:-}" ]; then
      HAVE_SIZE_COL=1
    fi

    echo "[INFO] Using hashes file: $INPUT"
    echo "[INFO] Input: $INPUT"
    echo "[INFO] Mode: $MODE  | Min group size: $MIN_GROUP_SIZE  | Scope: $SCOPE  | Keep: $KEEP_POLICY  | Signature: $SIGNATURE"
    if [ "$HAVE_SIZE_COL" -eq 1 ]; then
      echo "[INFO] Using size_bytes from CSV/TSV (fast path)."
    else
      echo "[INFO] CSV had no size_bytes; falling back to filesystem stat (slower)."
    fi

    # ────────────────────────────── Temp files ────────────────────────────
    TMP_DIRMAP="$(mktemp -t fdf-dirmap.XXXXXX)"
    TMP_DIRSORT="$(mktemp -t fdf-dirsort.XXXXXX)"
    TMP_SIGS="$(mktemp -t fdf-sigs.XXXXXX)"
    PLAN_FILE="$LOGS_DIR/duplicate-folders-plan-$(date +%F)-$$.txt"

    cleanup() { rm -f -- "$TMP_DIRMAP" "$TMP_DIRSORT" "$TMP_SIGS" 2>/dev/null || true; }
    trap cleanup EXIT

    # ────────────────────────────── Build dir map ─────────────────────────
    # Emit: dir \t file \t hash \t size_bytes
    if [ "$HAVE_SIZE_COL" -eq 1 ]; then
      awk -v FS="$DELIM" -v p="$COL_PATH" -v s="$COL_SIZE" -v h="$COL_HASH" '
        NR>1 {
          path=$p
          gsub(/^"|"$/,"",path)
          n=split(path, a, "/")
          file=a[n]
          dir=substr(path, 1, length(path)-length(file)-1)
          if (dir=="") dir="/"
          size=$s
          if (size=="" || size !~ /^[0-9]+$/) size=0
          print dir "\t" file "\t" $h "\t" size
        }
      ' "$INPUT" > "$TMP_DIRMAP"
    else
      # filesystem stat fallback
      awk -v FS="$DELIM" -v p="$COL_PATH" -v h="$COL_HASH" '
        NR>1 {
          path=$p
          gsub(/^"|"$/,"",path)
          n=split(path, a, "/")
          file=a[n]
          dir=substr(path, 1, length(path)-length(file)-1)
          if (dir=="") dir="/"
          cmd="stat -c %s -- \042" path "\042 2>/dev/null || stat -f %z -- \042" path "\042 2>/dev/null"
          cmd | getline size
          close(cmd)
          if (size=="" || size !~ /^[0-9]+$/) size=0
          print dir "\t" file "\t" $h "\t" size
        }
      ' "$INPUT" > "$TMP_DIRMAP"
    fi

    # Sort canonical: dir, then (file,hash)
    sort -t$'\t' -k1,1 -k2,2 -k3,3 -- "$TMP_DIRMAP" > "$TMP_DIRSORT"

    # ────────────────────────────── Collapse per directory ────────────────
    : > "$TMP_SIGS"
    prev_dir=""
    concat=""
    sum_bytes=0

    flush_prev() {
      if [ -n "$prev_dir" ]; then
        sig="$(printf '%s' "$concat" | cksum | awk '{print $1}')"
        printf '%s\t%s\t%s\n' "$sig" "$prev_dir" "$sum_bytes" >> "$TMP_SIGS"
      fi
    }

    while IFS=$'\t' read -r dir file hash size; do
      : "${size:=0}"
      if [ -n "$prev_dir" ] && [ "$dir" != "$prev_dir" ]; then
        flush_prev
        concat=""
        sum_bytes=0
      fi
      prev_dir="$dir"
      concat+="${file}|${hash}"$'\n'
      sum_bytes=$(( 10#${sum_bytes:-0} + 10#${size:-0} ))
    done < "$TMP_DIRSORT"
    flush_prev

    # ────────────────────────────── Group & plan ──────────────────────────
    plan_dirs_bytes=0
    awk -F'\t' -v mgs="$MIN_GROUP_SIZE" -v keep="$KEEP_POLICY" -v plan="$PLAN_FILE" '
      {
        sig=$1; dir=$2; sz=$3+0
        count[sig]++
        idx=count[sig]
        ddir[sig,idx]=dir
        dsz[sig,idx]=sz
      }
      END{
        for (s in count) {
          n=count[s]
          if (n>=mgs) {
            best=1
            if (keep=="shortest-path") {
              bestlen=length(ddir[s,1])
              for (i=2;i<=n;i++) if (length(ddir[s,i]) < bestlen) { best=i; bestlen=length(ddir[s,i]) }
            } else if (keep=="longest-path") {
              bestlen=length(ddir[s,1])
              for (i=2;i<=n;i++) if (length(ddir[s,i]) > bestlen) { best=i; bestlen=length(ddir[s,i]) }
            } else {
              best=1
            }
            for (i=1;i<=n;i++) {
              if (i==best) continue
              print ddir[s,i] >> plan
              total += dsz[s,i]
              dirs++
            }
            groups++
          }
        }
        printf("[INFO] Duplicate folder groups planned (>= %d): %d\n", mgs, groups) > "/dev/stderr"
        printf("[INFO] Directories in plan (excluding kept): %d\n", dirs) > "/dev/stderr"
        print total
      }
    ' "$TMP_SIGS" 2> >(tee /dev/stderr) | {
      read -r total_bytes || total_bytes=0
      plan_dirs_bytes="$total_bytes"
      awk -v b="$plan_dirs_bytes" 'BEGIN{
        gb=b/1024/1024/1024; mb=b/1024/1024;
        if (gb>=1) printf("[INFO] Estimated plan size: %.2f GB\n", gb);
        else printf("[INFO] Estimated plan size: %.2f MB\n", mb);
      }'
    }

    if [ -s "$PLAN_FILE" ]; then
      echo "[OK] Plan created: $PLAN_FILE"
    else
      echo "[OK] No duplicate folder groups (>= $MIN_GROUP_SIZE). No plan created."
      rm -f -- "$PLAN_FILE" 2>/dev/null || true
      exit 0
    fi

    # ────────────────────────────── Quarantine heads-up ───────────────────
    if [ -n "${QUARANTINE_DIR:-}" ]; then
      mkdir -p -- "$QUARANTINE_DIR" 2>/dev/null || true
      free_bytes="$(df -Pk "$QUARANTINE_DIR" | awk 'NR==2{print $4 * 1024}')"
      human_free="$(df -h "$QUARANTINE_DIR" | awk 'NR==2{print $4" free on "$1" ("$6")"}')"
      echo "[INFO] Quarantine: $QUARANTINE_DIR — $human_free"
      first_dir="$(head -n1 "$PLAN_FILE" || true)"
      if [ -n "$first_dir" ]; then
        src_fs="$(df -Pk "$first_dir" | awk 'NR==2{print $1}')"
        q_fs="$(df -Pk "$QUARANTINE_DIR" | awk 'NR==2{print $1}')"
        if [ "$src_fs" != "$q_fs" ] && [ "${plan_dirs_bytes:-0}" -gt "${free_bytes:-0}" ]; then
          echo "[WARN] Plan size exceeds free space on quarantine filesystem for a cross-filesystem move."
          echo "       Set QUARANTINE_DIR to the same filesystem as sources, or reduce the plan."
        fi
      fi
    fi

    exit 0
