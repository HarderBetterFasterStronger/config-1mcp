#!/bin/sh
# Validates 1MCP config files before the agent starts.
# Rejects server names containing hyphens - these break LiteLLM's
# MCP tool prefix separator (defaults to "-") and Gemini's function
# name validation. See: https://github.com/1mcp-app/agent/issues/263
#
# Usage: validate-config.sh <config.json>

set -e

CONFIG="${1:-/usr/src/app/mcp.json}"

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: config file not found: $CONFIG" >&2
  exit 1
fi

# Extract top-level keys under mcpServers and check for hyphens
BAD_NAMES=$(node -e "
  const cfg = JSON.parse(require('fs').readFileSync('$CONFIG', 'utf8'));
  const servers = cfg.mcpServers || {};
  const bad = Object.keys(servers).filter(n => n.includes('-'));
  if (bad.length) {
    bad.forEach(n => console.log('  ' + n + '  ->  ' + n.replace(/-/g, '_')));
    process.exit(1);
  }
" 2>&1) || {
  echo "ERROR: MCP server names must not contain hyphens." >&2
  echo "Rename the following servers in $CONFIG:" >&2
  echo "$BAD_NAMES" >&2
  echo "" >&2
  echo "Hyphens in server names break LiteLLM MCP gateway prefix parsing" >&2
  echo "and Gemini API function name validation." >&2
  echo "See: https://github.com/1mcp-app/agent/issues/263" >&2
  exit 1
}

echo "Config OK: no hyphenated server names in $CONFIG"
