#!/bin/sh
# bin/hash-check.sh — lookup a file by its content hash in Hasher's outputs
# BusyBox/ash compatible

set -eu

HASH_DIR="${HASH_DIR:-./hashes}"
HASH_VALUE="${1:-}"

usage() {
    echo "Usage: $0 <sha256-hash>"
    echo "Looks for the hash in CSV/hash reports under: $HASH_DIR"
    exit 1
}

# basic SHA256 length check (64 hex chars)
is_valid_sha256() {
    [ ${#HASH_VALUE} -eq 64 ] && echo "$HASH_VALUE" | grep -qiE '^[0-9a-f]+$'
}

[ -z "$HASH_VALUE" ] && usage

if ! is_valid_sha256 ; then
    echo "ERROR: '$HASH_VALUE' does not look like a valid 64-char SHA256 hash."
    exit 2
fi

if [ ! -d "$HASH_DIR" ]; then
    echo "ERROR: hash directory '$HASH_DIR' not found."
    exit 3
fi

FOUND=0

# You can tailor this to your real filenames:
# - hasher-YYYY-MM-DD.csv
# - duplicate-hashes-latest.txt
# we just scan all text-y files in hashes/
for f in "$HASH_DIR"/*; do
    [ -f "$f" ] || continue
    # look for the hash
    if grep -Fq "$HASH_VALUE" "$f"; then
        echo "✅ Found in: $f"
        # print matching lines (limit to avoid huge output)
        grep -F "$HASH_VALUE" "$f" | head -200
        FOUND=1
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "❌ Hash not found in any known records under $HASH_DIR"
    exit 4
fi
