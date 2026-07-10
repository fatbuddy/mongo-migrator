#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.pi"
cp "$ROOT/mcp/pi.mcp.json" "$ROOT/.pi/mcp.json"
pi install npm:pi-mcp-extension -l
