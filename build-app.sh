#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/Mongo Migrator.app"
BIN="$ROOT/.build/release/MongoMigrator"
MCP_BIN="$ROOT/.build/release/MongoMigratorMCP"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"

cd "$ROOT"
swift build -c release --arch arm64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MongoMigrator"
cp "$MCP_BIN" "$APP/Contents/MacOS/MongoMigratorMCP"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/mcp/claude.mcp.json" "$ROOT/mcp/pi.mcp.json" "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
print "$APP"
