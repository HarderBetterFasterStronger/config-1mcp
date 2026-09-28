#!/bin/bash
# Probes the aggregate tools/list through the proxy and reports per-server tool counts.
# The container /health endpoint only tracks transport connection, so a server whose
# upstream session has expired still counts as "healthy" while exposing zero tools.
#
# Exit: 0 all expected servers present, 1 one or more missing, 2 probe itself failed.
# Usage: ./probe-servers.sh [--quiet]

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

[[ -f .env ]] && { set -a; . ./.env; set +a; }

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

MCP_URL="http://127.0.0.1:${PROXY_EXTERNAL_PORT:-9494}/mcp"

MCP_URL="$MCP_URL" TOKEN="${MCP_PROXY_TOKEN:-}" CONFIG="${PROBE_CONFIG:-${MCP_CONFIG:-./mcp.json}}" QUIET="$QUIET" python3 - <<'PY'
import collections, json, os, sys, urllib.error, urllib.request

URL, TOKEN, QUIET = os.environ["MCP_URL"], os.environ.get("TOKEN", ""), os.environ["QUIET"] == "1"
SEP = "_1mcp_"

def emit(msg):
    if not QUIET:
        print(msg)

def post(body, sid=None, timeout=90):
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if TOKEN:
        h["Authorization"] = "Bearer " + TOKEN
    if sid:
        h["mcp-session-id"] = sid
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(body).encode(), h), timeout=timeout)
    payload = None
    for line in r.read().decode().splitlines():
        line = line[6:] if line.startswith("data: ") else line
        if line.strip().startswith("{"):
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                pass
    return r.headers.get("mcp-session-id"), payload

def delete(sid):
    h = {"mcp-session-id": sid}
    if TOKEN:
        h["Authorization"] = "Bearer " + TOKEN
    req = urllib.request.Request(URL, headers=h, method="DELETE")
    try:
        urllib.request.urlopen(req, timeout=15).read()
    except Exception:
        pass  # session cleanup is best-effort; 1mcp expires it anyway

with open(os.environ["CONFIG"]) as f:
    servers = json.load(f)["mcpServers"]
expected = {n for n, c in servers.items() if not c.get("disabled")}

sid = None
try:
    sid, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "probe-servers", "version": "1"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)

    names, cursor, pages = [], None, 0
    while True:
        params = {} if cursor is None else {"cursor": cursor}
        _, d = post({"jsonrpc": "2.0", "id": 10 + pages, "method": "tools/list", "params": params}, sid)
        if d and "error" in d:
            print(f"PROBE ERROR: tools/list returned {d['error']}", file=sys.stderr)
            sys.exit(2)
        res = (d or {}).get("result", {})
        names += [t["name"] for t in res.get("tools", [])]
        cursor = res.get("nextCursor")
        pages += 1
        if not cursor or pages > 50:
            break
except urllib.error.HTTPError as e:
    print(f"PROBE ERROR: HTTP {e.code} from {URL}", file=sys.stderr)
    sys.exit(2)
except Exception as e:
    print(f"PROBE ERROR: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(2)
finally:
    if sid:
        delete(sid)

counts = collections.Counter(n.split(SEP)[0] for n in names if SEP in n)
missing = sorted(expected - set(counts))

emit(f"{len(names)} tools across {len(counts)}/{len(expected)} servers")
for name in sorted(expected):
    emit(f"  {counts.get(name, 0):4d}  {name}" + ("   <-- NO TOOLS" if name in missing else ""))

if missing:
    print("MISSING: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
