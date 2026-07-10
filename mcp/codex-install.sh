#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SERVER="$ROOT/dist/Mongo Migrator.app/Contents/MacOS/MongoMigratorMCP"

codex mcp remove mongo-migrator >/dev/null 2>&1 || true
codex mcp add mongo-migrator -- "$SERVER"
