# config-1mcp

A Docker-based deployment for [1MCP](https://github.com/1mcp-app/agent), the unified MCP server proxy. Instead of wiring up each AI tool (Claude Desktop, Cursor, VS Code, etc.) to a half-dozen MCP servers individually, you point them all at one endpoint and let 1MCP handle the routing.

One connection. All your tools.

## What's in the box

This repo is configuration only. There's no application code to build. It runs the official `ghcr.io/1mcp-app/agent` Docker image behind an nginx reverse proxy. Authentication is now handled by 1MCP's OAuth flow (no proxy bearer token required for `/mcp`).

**Currently configured MCP servers:**

| Server | Transport | What it does |
|--------|-----------|-------------|
| [Semaphore](https://semaphoreci.com) | HTTP | CI/CD pipelines and build management |
| [Jam](https://jam.dev) | HTTP | Frontend bug reports and session replay |
| [Sentry](https://sentry.io) | stdio | Error monitoring and observability |
| [Shortcut](https://shortcut.com) | stdio | Project management (stories, epics, iterations) |
| [New Relic](https://newrelic.com) | stdio | APM, NRQL queries, alerting |
| [Intercom](https://intercom.com) | stdio | Customer conversations and contact lookup |
| [Filesystem](https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem) | stdio | Local file access (restricted to `/tmp`) |
| [Memory](https://www.npmjs.com/package/@modelcontextprotocol/server-memory) | stdio | Scratchpad / notes |
| [Notion](https://notion.so) | HTTP | Notion MCP (OAuth) |
| [GitHub](https://github.com) | stdio | Repo access via GitHub MCP |

That's 100+ tools accessible through a single authenticated endpoint.

## Quick start

**1. Clone and configure**

```bash
git clone https://github.com/HarderBetterFasterStronger/config-1mcp.git
cd config-1mcp
cp .env.example .env
```

Edit `.env` and fill in your API tokens. Every token marked with `?Set in .env` in the compose file is required for the corresponding server to connect.

**2. Start it up**

```bash
docker compose up -d
```

This pulls the 1MCP agent image and an nginx:alpine image, then starts both containers. The agent will connect to all configured MCP servers in parallel and report readiness via health checks.

**3. Connect your AI tool**

Point your MCP client at:

```
URL:   http://localhost:9494/mcp
```

On first connect, your MCP client will run an OAuth handshake against 1MCP. Complete the browser flow, then restart your client if it doesn't reconnect automatically.

## Architecture

```
AI Assistant (Claude, Cursor, etc.)
         |
         v
   nginx proxy (:9494)          -- forwards OAuth + MCP endpoints
         |
         v
   1MCP agent (:3050)           -- routing, tool aggregation, config reload
     |    |    |    |    |
     v    v    v    v    v
   Semaphore  Jam  Shortcut  New Relic  Intercom  ...
```

The proxy exposes these paths:
- `/mcp` - the main MCP endpoint (OAuth-authenticated by 1MCP)
- `/oauth` - OAuth management dashboard
- `/.well-known/*` - OAuth discovery endpoints
- `/authorize`, `/token`, `/revoke`, `/register` - OAuth endpoints
- `/health` - health check (unauthenticated)

All traffic stays on localhost. The proxy binds to `127.0.0.1` only.

## Configuration

### Adding a new MCP server

Edit `mcp.json`. HTTP servers look like this:

```json
"my-server": {
  "type": "http",
  "url": "https://mcp.example.com/mcp",
  "headers": {
    "Authorization": "Bearer ${MY_SERVER_TOKEN}"
  },
  "tags": ["category"]
}
```

Stdio servers (run via npx) look like this:

```json
"my-server": {
  "command": "npx",
  "args": ["-y", "some-mcp-package"],
  "env": {
    "API_KEY": "${MY_SERVER_API_KEY}"
  },
  "tags": ["category"]
}
```

Add the corresponding secrets to your `.env` file and to the `environment` section of the `1mcp` service in `docker-compose.yml`.

If config reload is enabled (it is by default), the agent picks up changes to `mcp.json` without a restart.

### Environment variables

**Required secrets** (one per MCP server):

| Variable | Server |
|----------|--------|
| `SENTRY_AUTH_TOKEN` | Sentry |
| `SENTRY_HOST` | Sentry (your org, e.g. `your-org.sentry.io`) |
| `SEMAPHORE_MCP_TOKEN` | Semaphore CI |
| `SHORTCUT_API_TOKEN` | Shortcut |
| `NEW_RELIC_API_KEY` | New Relic |
| `NEW_RELIC_ACCOUNT_ID` | New Relic |
| `JAM_MCP_TOKEN` | Jam |
| `INTERCOM_API_TOKEN` | Intercom |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub MCP |
| `MCP_PROXY_TOKEN` | nginx proxy auth |

**Optional tuning** (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `ONE_MCP_PORT` | `3050` | Internal agent port |
| `ONE_MCP_EXTERNAL_PORT` | `9494` | Host-facing proxy port |
| `ONE_MCP_EXTERNAL_URL` | `http://127.0.0.1:9494` | Public URL for OAuth callbacks |
| `ONE_MCP_LOG_LEVEL` | `info` | Log verbosity (debug, info, warn, error) |
| `ONE_MCP_ENABLE_ENV_SUBSTITUTION` | `true` | Allow `${VAR}` in mcp.json |
| `ONE_MCP_ENABLE_CONFIG_RELOAD` | `true` | Watch mcp.json for changes |
| `ONE_MCP_ENABLE_ASYNC_LOADING` | `true` | Load servers in parallel |
| `ONE_MCP_ENABLE_AUTH` | `true` | Enable 1MCP OAuth authentication |
| `ONE_MCP_TRUST_PROXY` | `uniquelocal` | Trust proxy for X-Forwarded-* |

### OAuth vs. legacy token bypass

Previously this setup relied on a proxy bearer token (`MCP_PROXY_TOKEN`) to gate `/mcp`. That mode bypassed 1MCP auth entirely.

Now:
- `/mcp` is **not** protected by the proxy token.
- 1MCP OAuth is enabled (`ONE_MCP_ENABLE_AUTH=true`).
- Clients complete the OAuth handshake once, then reuse the issued session.
- 1MCP state is persisted via `./data/1mcp:/root/.config/1mcp` in `docker-compose.yml` to survive restarts.

If you still want to use a proxy token gate, you'd need to disable 1MCP OAuth and reintroduce the bearer check on `/mcp`. That is not the current configuration.

### Switching Back to Proxy Token Auth (Bypass Mode)

You can revert to the legacy proxy-token gate with a simple config swap.

**1. Update `.env`**

```
ONE_MCP_ENABLE_AUTH=false
MCP_PROXY_TOKEN=your-proxy-bearer-token
```

**2. Swap nginx template**

Edit `docker-compose.yml` and change the proxy template mount:

From:
```
./proxy/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro
```

To:
```
./proxy/nginx.conf.token.template:/etc/nginx/templates/default.conf.template:ro
```

**3. Restart**

```bash
docker compose up -d --force-recreate proxy 1mcp
```

This restores the original flow:
- Clients must send `Authorization: Bearer ${MCP_PROXY_TOKEN}` to `/mcp`
- 1MCP OAuth is disabled
- `/oauth` and OAuth endpoints are not used

To switch back to OAuth mode, revert the template to `proxy/nginx.conf.oauth.template` (or `proxy/nginx.conf.template`) and set `ONE_MCP_ENABLE_AUTH=true`.

#### Client configuration (Token Bypass)

Claude Code:

```json
{
  "type": "http",
  "url": "http://127.0.0.1:9494/mcp",
  "headers": {
    "Authorization": "Bearer ${MCP_PROXY_TOKEN}"
  }
}
```

CLI:

```bash
claude mcp add --transport http 1mcp http://127.0.0.1:9494/mcp --header "Authorization: Bearer ${MCP_PROXY_TOKEN}"
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.1mcp]
url = "http://127.0.0.1:9494/mcp"
headers = { Authorization = "Bearer ${MCP_PROXY_TOKEN}" }
```

CLI:

```bash
codex mcp add 1mcp http://127.0.0.1:9494/mcp --header "Authorization: Bearer ${MCP_PROXY_TOKEN}"
```

### Claude Code configuration (OAuth)

- Use this exact JSON object:

```json
{
  "type": "http",
  "url": "http://127.0.0.1:9494/mcp"
}
```

- **Do not** set an `Authorization` header for this server.
- On first connect, complete the OAuth flow in your browser (via `http://127.0.0.1:9494/oauth`).
- Restart Claude Code if it doesn't reconnect automatically after auth.

You can also add it via CLI:

```bash
claude mcp add --transport http 1mcp http://127.0.0.1:9494/mcp
```

### Codex configuration (OAuth)

Point Codex at the same MCP URL and complete the OAuth flow once:

- Server URL: `http://127.0.0.1:9494/mcp`
- No bearer token header.
- Complete OAuth at `http://127.0.0.1:9494/oauth`.

If you use `~/.codex/config.toml`, add this exact block:

```toml
[mcp_servers.1mcp]
url = "http://127.0.0.1:9494/mcp"
```

You can also add it via CLI:

```bash
codex mcp add 1mcp http://127.0.0.1:9494/mcp
```

The exact file or UI depends on which Codex client you're using; the key requirement is to use OAuth, not a static bearer token.

## Logs and troubleshooting

Logs are written to `./logs/` (mounted into the container). You can also tail them live:

```bash
docker compose logs -f
```

The health endpoint is useful for quick checks:

```bash
curl http://localhost:9494/health
```

Sentry uses a local stdio process with a User Auth Token for unattended access — no OAuth browser flow required.

## Project structure

```
.
├── docker-compose.yml       # 1MCP agent + nginx proxy
├── mcp.json                 # MCP server definitions
├── .env.example             # Template for secrets
├── .env                     # Your secrets (gitignored)
├── proxy/
│   └── nginx.conf.template  # Reverse proxy config
└── logs/                    # Runtime logs (gitignored)
```

## Links

- [1MCP documentation](https://docs.1mcp.app)
- [1MCP agent on GitHub](https://github.com/1mcp-app/agent)
- [MCP config schema](https://docs.1mcp.app/schemas/v1.0.0/mcp-config.json)
