#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp/}lucent-cbh-checks.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
SDK_DIR=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
SDK_COMPILER='Apple Swift version 6.3 effective-5.10 (swiftlang-6.3.0.123.4 clang-2100.0.123.2)'
READER_DIR="$PROJECT_DIR/Tools/ChessBaseReader"

clang++ -std=c++20 -O2 -DNDEBUG -target arm64-apple-macosx14.0 \
  -isysroot "$SDK_DIR" \
  -I"$READER_DIR/libcbh/include" -I"$READER_DIR/libcbh/src" \
  "$READER_DIR/main.cpp" "$READER_DIR"/libcbh/src/*.cpp \
  -o "$CHECK_DIR/LucentChessCBH"

python3 "$PROJECT_DIR/scripts/check_chessbase_comments.py" "$PROJECT_DIR/Tests/Fixtures/ChessBase" "$CHECK_DIR/LucentChessCBH"

CLANG_MODULE_CACHE_PATH="$CHECK_DIR/clang" swiftc \
  -interface-compiler-version "$SDK_COMPILER" -sdk "$SDK_DIR" \
  -target arm64-apple-macosx14.0 -parse-as-library -O \
  "$PROJECT_DIR"/Sources/LucentChess/Chess/*.swift \
  "$PROJECT_DIR/Sources/LucentChess/Models/Study.swift" \
  "$PROJECT_DIR/Sources/LucentChess/Models/LibraryPersistenceSnapshot.swift" \
  "$PROJECT_DIR/Sources/LucentChess/Services/PGNService.swift" \
  "$PROJECT_DIR/Sources/LucentChess/Services/CanonicalGameImportService.swift" \
  "$PROJECT_DIR/Sources/LucentChess/Services/LibraryStore.swift" \
  "$PROJECT_DIR/Sources/LucentChess/Services/CBVArchive.swift" \
  "$PROJECT_DIR/Sources/LucentChess/Services/ChessBaseImportService.swift" \
  "$PROJECT_DIR/scripts/ChessBaseImportChecks.swift" \
  -o "$CHECK_DIR/ChessBaseImportChecks"

"$CHECK_DIR/ChessBaseImportChecks" "$PROJECT_DIR/Tests/Fixtures/ChessBase" "$CHECK_DIR/LucentChessCBH" "$@"
