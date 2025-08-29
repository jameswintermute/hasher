#!/bin/bash
# Deprecated wrapper – prefer: ./delete-zero-length.sh
set -Eeuo pipefail
self="$(basename "$0")"
echo "[WARN] '$self' is deprecated. Use './delete-zero-length.sh' instead." >&2
exec "$(dirname "$0")/delete-zero-length.sh" "$@"
