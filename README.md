# config-1mcp

A Docker-based deployment for [1MCP](https://github.com/1mcp-app/agent), the unified MCP server proxy. Instead of wiring up each AI tool (Claude Desktop, Cursor, VS Code, etc.) to a half-dozen MCP servers individually, you point them all at one endpoint and let 1MCP handle the routing.

One connection. All your tools.

## What's in the box

This repo is configuration only. There's no application code to build. It runs the official `ghcr.io/1mcp-app/agent` Docker image behind an nginx reverse proxy that handles bearer token authentication.

**Currently configured MCP servers:**

| Server | Transport | What it does |
|--------|-----------|-------------|
| [Semaphore](https://semaphoreci.com) | HTTP | CI/CD pipelines and build management |
| [Jam](https://jam.dev) | HTTP | Frontend bug reports and session replay |
| [Sentry](https://sentry.io) | HTTP | Error monitoring and observability |
| [Shortcut](https://shortcut.com) | stdio | Project management (stories, epics, iterations) |
| [New Relic](https://newrelic.com) | stdio | APM, NRQL queries, alerting |
| [Intercom](https://intercom.com) | stdio | Customer conversations and contact lookup |

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
Token: Bearer <your MCP_PROXY_TOKEN from .env>
```

That's it. Your AI assistant now has access to every configured MCP server through this single endpoint.

## Architecture

```
AI Assistant (Claude, Cursor, etc.)
         |
         v
   nginx proxy (:9494)          -- bearer token auth, SSE streaming
         |
         v
   1MCP agent (:3050)           -- routing, tool aggregation, config reload
     |    |    |    |    |
     v    v    v    v    v
   Semaphore  Jam  Shortcut  New Relic  Intercom  ...
```

The proxy only exposes two paths:
- `/mcp` - the main MCP endpoint (authenticated)
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
| `SEMAPHORE_MCP_TOKEN` | Semaphore CI |
| `SHORTCUT_API_TOKEN` | Shortcut |
| `NEW_RELIC_API_KEY` | New Relic |
| `NEW_RELIC_ACCOUNT_ID` | New Relic |
| `JAM_MCP_TOKEN` | Jam |
| `INTERCOM_API_TOKEN` | Intercom |
| `MCP_PROXY_TOKEN` | nginx proxy auth |

**Optional tuning** (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `ONE_MCP_PORT` | `3050` | Internal agent port |
| `ONE_MCP_EXTERNAL_PORT` | `9494` | Host-facing proxy port |
| `ONE_MCP_EXTERNAL_URL` | `https://localhost:9494` | Public URL for OAuth callbacks |
| `ONE_MCP_LOG_LEVEL` | `info` | Log verbosity (debug, info, warn, error) |
| `ONE_MCP_ENABLE_ENV_SUBSTITUTION` | `true` | Allow `${VAR}` in mcp.json |
| `ONE_MCP_ENABLE_CONFIG_RELOAD` | `true` | Watch mcp.json for changes |
| `ONE_MCP_ENABLE_ASYNC_LOADING` | `true` | Load servers in parallel |
| `ONE_MCP_ENABLE_AUTH` | `false` | 1MCP's own auth (disabled since nginx handles it) |

## Logs and troubleshooting

Logs are written to `./logs/` (mounted into the container). You can also tail them live:

```bash
docker compose logs -f
```

The health endpoint is useful for quick checks:

```bash
curl http://localhost:9494/health
```

If a server requires OAuth (like Sentry), visit `https://localhost:9494/oauth` to complete the authorization flow.

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
