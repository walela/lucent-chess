#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
CHECK_DIR="$PROJECT_DIR/.build-local/reference-bench"
MODE=${1:-cbh}
shift
case "$MODE" in
 cbh) BENCH=ReferenceBench ;;
 pgn) BENCH=PGNReferenceBench ;;
 *) echo "Usage: $0 cbh <disposable-catalog.sqlite> [folder-id] | pgn <source-catalog.sqlite> <disposable-output-directory>" >&2; exit 2 ;;
esac
mkdir -p "$CHECK_DIR"
SDK_DIR=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
READER_DIR="$PROJECT_DIR/Tools/ChessBaseReader"
clang++ -std=c++20 -O2 -DNDEBUG -target arm64-apple-macosx14.0 -isysroot "$SDK_DIR" -I"$READER_DIR/libcbh/include" -I"$READER_DIR/libcbh/src" "$READER_DIR/main.cpp" "$READER_DIR"/libcbh/src/*.cpp -lsqlite3 -lcompression -lz -framework CoreFoundation -o "$CHECK_DIR/LucentChessCBH"
CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build-local/clang" swiftc -interface-compiler-version 'Apple Swift version 6.3 effective-5.10 (swiftlang-6.3.0.123.4 clang-2100.0.123.2)' -sdk "$SDK_DIR" -target arm64-apple-macosx14.0 -parse-as-library -O \
 "$PROJECT_DIR"/Sources/LucentChess/Chess/*.swift \
 "$PROJECT_DIR/Sources/LucentChess/Models/Study.swift" "$PROJECT_DIR/Sources/LucentChess/Models/LibraryPersistenceSnapshot.swift" \
 "$PROJECT_DIR/Sources/LucentChess/Services/PGNService.swift" "$PROJECT_DIR/Sources/LucentChess/Services/CanonicalGameImportService.swift" \
 "$PROJECT_DIR/Sources/LucentChess/Services/LibraryStore.swift" "$PROJECT_DIR/Sources/LucentChess/Services/CBVArchive.swift" \
 "$PROJECT_DIR/Sources/LucentChess/Services/ChessBaseImportService.swift" "$PROJECT_DIR/Sources/LucentChess/Services/DatabaseCatalog.swift" "$PROJECT_DIR/Sources/LucentChess/Services/LocalCatalog.swift" "$PROJECT_DIR/Sources/LucentChess/Services/InteractiveCatalogService.swift" "$PROJECT_DIR/Sources/LucentChess/Services/CatalogFilter.swift" "$PROJECT_DIR/Sources/LucentChess/Services/PositionSearchService.swift" "$PROJECT_DIR/Sources/LucentChess/Services/PGNPositionScanner.swift" \
 "$PROJECT_DIR/Sources/LucentChess/Services/IndexedDatabaseImport.swift" "$PROJECT_DIR/scripts/$BENCH.swift" -o "$CHECK_DIR/$BENCH"
"$CHECK_DIR/$BENCH" "$@"
