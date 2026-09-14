#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
CHECK_DIR="$PROJECT_DIR/.build-local/position-checks"
mkdir -p "$CHECK_DIR"
READER_DIR="$PROJECT_DIR/Tools/ChessBaseReader"
clang++ -std=c++20 -O2 -DNDEBUG -I"$READER_DIR/libcbh/include" -I"$READER_DIR/libcbh/src" "$PROJECT_DIR/scripts/PositionIndexChecks.cpp" "$READER_DIR"/libcbh/src/*.cpp -lsqlite3 -lcompression -lz -framework CoreFoundation -o "$CHECK_DIR/PositionIndexChecks"
TEMP_ROOT=$(mktemp -d /private/tmp/lucent-position-faults.XXXXXX)
trap 'rm -rf "$TEMP_ROOT"' EXIT
"$CHECK_DIR/PositionIndexChecks" "$TEMP_ROOT"
