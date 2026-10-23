#!/bin/sh
# Memory regression test for the capture overlay. Fails if memory keeps growing across repeated captures.
# Usage: tools/leak-check.sh [cycles]      (default 40; needs a logged-in GUI session)
set -e
cd "$(dirname "$0")/.."
LIMIT_MB=6
OUT=$(mktemp -d)
swiftc -o "$OUT/leak-check" tools/leak-check/main.swift Sources/Shot/Overlay/*.swift \
    Sources/Shot/Annotation.swift Sources/Shot/Preferences.swift Sources/Shot/Clipboard.swift
CYCLES="${1:-40}" "$OUT/leak-check" | tee "$OUT/log"
DRIFT=$(awk '/^drift:/ {gsub(/[+MB]/, "", $2); print int($2)}' "$OUT/log")
rm -rf "$OUT"
if [ "$DRIFT" -gt "$LIMIT_MB" ]; then
    echo "FAIL: memory grew by ${DRIFT} MB across captures (limit ${LIMIT_MB} MB)"
    exit 1
fi
echo "OK: no leak (drift ${DRIFT} MB, limit ${LIMIT_MB} MB)"
