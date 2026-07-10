#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SERVER="$ROOT/dist/Mongo Migrator.app/Contents/MacOS/MongoMigratorMCP"

claude mcp remove mongo-migrator --scope user >/dev/null 2>&1 || true
claude mcp add mongo-migrator --scope user -- "$SERVER"
