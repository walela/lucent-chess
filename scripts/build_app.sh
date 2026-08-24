#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
OUTPUT_DIR=${1:-"$PROJECT_DIR/dist"}
APP_DIR="$OUTPUT_DIR/Lucent Chess.app"
CACHE_DIR="$PROJECT_DIR/.build-local/clang"
BIN_DIR="$PROJECT_DIR/.build-local/bin"
SDK_DIR=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
SDK_COMPILER='Apple Swift version 6.3 effective-5.10 (swiftlang-6.3.0.123.4 clang-2100.0.123.2)'

mkdir -p "$CACHE_DIR" "$BIN_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

CLANG_MODULE_CACHE_PATH="$CACHE_DIR" swiftc \
  -interface-compiler-version "$SDK_COMPILER" \
  -sdk "$SDK_DIR" \
  -target arm64-apple-macosx14.0 \
  -parse-as-library \
  -O \
  -module-name LucentChess \
  "$PROJECT_DIR"/Sources/LucentChess/**/*.swift \
  -o "$BIN_DIR/LucentChess"

cp "$BIN_DIR/LucentChess" "$APP_DIR/Contents/MacOS/LucentChess"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
mkdir -p "$APP_DIR/Contents/Resources/Pieces"
mkdir -p "$APP_DIR/Contents/Resources/BoardThemes"
mkdir -p "$APP_DIR/Contents/Resources/SeedGames"
ditto "$PROJECT_DIR/Sources/LucentChess/Resources/Pieces" "$APP_DIR/Contents/Resources/Pieces"
ditto "$PROJECT_DIR/Sources/LucentChess/Resources/BoardThemes" "$APP_DIR/Contents/Resources/BoardThemes"
ditto "$PROJECT_DIR/Sources/LucentChess/Resources/SeedGames" "$APP_DIR/Contents/Resources/SeedGames"
if [[ -f "$PROJECT_DIR/Sources/LucentChess/Resources/THIRD_PARTY_NOTICES.txt" ]]; then
  cp "$PROJECT_DIR/Sources/LucentChess/Resources/THIRD_PARTY_NOTICES.txt" "$APP_DIR/Contents/Resources/"
fi
if [[ -f "$PROJECT_DIR/Sources/LucentChess/Resources/GPL-2.0.txt" ]]; then
  cp "$PROJECT_DIR/Sources/LucentChess/Resources/GPL-2.0.txt" "$APP_DIR/Contents/Resources/"
fi
cp "$PROJECT_DIR/Sources/LucentChess/Resources/LICHESS-COPYING.md" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Sources/LucentChess/Resources/LICHESS-AGPL-3.0.txt" "$APP_DIR/Contents/Resources/"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
