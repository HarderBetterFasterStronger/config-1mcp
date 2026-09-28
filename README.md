# config-1mcp

A Docker-based deployment for [1MCP](https://github.com/1mcp-app/agent), the unified MCP server proxy. Instead of wiring every AI client (Claude Code, Codex, Cursor, Claude Desktop, ...) to a dozen MCP servers individually, you point them all at one endpoint and 1MCP handles the routing.

One connection. All your tools.

This repo is configuration and ops tooling only - there's no application code to build. It runs the official `ghcr.io/1mcp-app/agent` image behind an nginx reverse proxy, plus a small macOS toolkit (`ctl.sh`, a launchd watchdog, and a tools-level health probe) that keeps the stack up unattended.

> The Docker setup runs anywhere. `ctl.sh` and the watchdog use launchd, so daemon management is macOS-only.

## What's included

`mcp.example.json` is a starter config with these servers:

| Server | Transport | What it does |
|--------|-----------|-------------|
| [GitHub](https://www.npmjs.com/package/@modelcontextprotocol/server-github) | stdio | Repos, issues, pull requests |
| [Sentry](https://www.npmjs.com/package/@sentry/mcp-server) | stdio | Error monitoring (User Auth Token, no browser flow) |
| [Shortcut](https://www.npmjs.com/package/@shortcut/mcp) | stdio | Stories, epics, iterations |
| [Notion](https://www.npmjs.com/package/@notionhq/notion-mcp-server) | stdio | Pages, databases, search (internal integration token) |
| [Semaphore](https://semaphoreci.com) | HTTP | CI/CD pipelines and job logs |
| [New Relic](https://www.npmjs.com/package/newrelic-mcp) | stdio | APM, NRQL queries, alerting |
| [Slack](https://mcp.slack.com) | stdio (mcp-remote) | Search and messaging as your Slack user - see [Slack setup](#slack-setup) |
| [PostgreSQL](https://www.npmjs.com/package/@modelcontextprotocol/server-postgres) | stdio | Read-only queries against a replica |
| [Filesystem](https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem) | stdio | File access inside the container (`/tmp`) |
| [Memory](https://www.npmjs.com/package/@modelcontextprotocol/server-memory) | stdio | Knowledge-graph scratchpad |

Remove what you don't use and add your own - anything 1MCP supports works. This setup has also been run with Intercom, Jam, Chargebee, Langfuse, Metabase, LogRocket, pganalyze, and host-side HTTP MCPs, 20+ servers and 400 tools behind one endpoint.

## Quick start

**1. Clone and configure**

```bash
git clone https://github.com/HarderBetterFasterStronger/config-1mcp.git
cd config-1mcp
cp .env.example .env
cp mcp.example.json mcp.json
```

Trim `mcp.json` to the servers you want and fill in their tokens in `.env`. Set `MCP_PROXY_TOKEN` to a random secret (`openssl rand -hex 32`) - clients use it to authenticate to the proxy.

**2. Start it**

```bash
./ctl.sh start          # macOS: stack + watchdog
# or
docker compose up -d    # anywhere: just the stack
```

The agent connects to all configured servers in parallel. HTTP servers are ready in seconds; `npx`-based ones can take a couple of minutes on first start while packages download.

**3. Connect your client**

Claude Code:

```bash
claude mcp add --transport http 1mcp http://127.0.0.1:9494/mcp \
  --header "Authorization: Bearer $MCP_PROXY_TOKEN"
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.1mcp]
url = "http://127.0.0.1:9494/mcp"
headers = { Authorization = "Bearer <your MCP_PROXY_TOKEN>" }
```

Any other client: HTTP transport, URL `http://127.0.0.1:9494/mcp`, header `Authorization: Bearer <token>`. Tools show up as `{server}_1mcp_{tool}`.

**4. Verify**

```bash
./ctl.sh probe
```

## Architecture

```
AI client (Claude Code, Codex, Cursor, ...)
         |
         v
   nginx proxy (127.0.0.1:9494)   bearer-token gate
         |
         v
   1MCP agent (:3050)             routing, tool aggregation, config hot-reload
     |      |      |      |
     v      v      v      v
  GitHub  Sentry  Slack  Postgres  ...
```

Proxy paths:
- `/mcp` - the MCP endpoint (bearer token required)
- `/health` - health check (unauthenticated)
- `/oauth`, `/.well-known/*`, `/authorize`, `/token`, `/register`, `/revoke` - passed through for servers whose own OAuth flow runs via 1MCP

Everything binds to `127.0.0.1` only.

## Configuration

### Adding a server

Edit `mcp.json`. HTTP servers:

```json
"my_server": {
  "type": "http",
  "url": "https://mcp.example.com/mcp",
  "headers": { "Authorization": "Bearer ${MY_SERVER_TOKEN}" },
  "tags": ["category"]
}
```

Stdio servers (run via `npx` inside the container):

```json
"my_server": {
  "command": "npx",
  "args": ["-y", "some-mcp-package"],
  "env": { "API_KEY": "${MY_SERVER_API_KEY}" },
  "tags": ["category"]
}
```

Add the referenced variables to `.env` - it's loaded into the agent container, and `${VAR}` references in `mcp.json` are substituted at load time. Config reload is on by default, so most edits apply without a restart.

Server names must not contain hyphens (use underscores). A `validate-config` container checks this before the agent starts, because hyphens break LiteLLM's tool-prefix parsing and Gemini's function-name validation ([1mcp-app/agent#263](https://github.com/1mcp-app/agent/issues/263)).

To reach an MCP server running on the host, use `http://host.docker.internal:<port>/mcp`.

### Environment variables

Server tokens are whatever your `mcp.json` references - see `.env.example` for the starter set. Stack settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_PROXY_TOKEN` | *(required)* | Bearer token clients send to the proxy |
| `MCP_CONFIG` | `./mcp.json` | Path to the server config (see [Keeping a private config](#keeping-a-private-config)) |
| `ONE_MCP_PORT` | `3050` | Internal agent port |
| `PROXY_EXTERNAL_PORT` | `9494` | Host-facing proxy port |
| `ONE_MCP_EXTERNAL_URL` | `http://127.0.0.1:9494` | Public URL used in OAuth callbacks |
| `ONE_MCP_ENABLE_AUTH` | `false` | 1MCP's own OAuth (see below) |
| `ONE_MCP_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `ONE_MCP_ENABLE_CONFIG_RELOAD` | `true` | Watch `mcp.json` for changes |
| `ONE_MCP_ENABLE_ASYNC_LOADING` | `true` | Load servers in parallel |
| `ONE_MCP_TRUST_PROXY` | `uniquelocal` | Trust `X-Forwarded-*` from the proxy |
| `DATA_RO_CONNECT` | *(unset)* | Host script that opens the Postgres tunnel before startup |

### Alternative: 1MCP OAuth instead of a bearer token

By default nginx checks a static bearer token and 1MCP auth is off. To have clients authenticate through 1MCP's OAuth flow instead:

1. Set `ONE_MCP_ENABLE_AUTH=true` in `.env`.
2. In `docker-compose.yml`, mount `./proxy/nginx.conf.oauth.template` instead of `nginx.conf.token.template`.
3. `docker compose up -d --force-recreate proxy 1mcp`

Clients then connect to `http://127.0.0.1:9494/mcp` with no header and complete the browser flow at `/oauth` on first connect. OAuth state persists in `./data/1mcp`.

## Slack setup

Slack's MCP server requires a pre-registered app with a client secret, which 1MCP's native HTTP transport can't do yet, so Slack runs through [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) as a stdio bridge.

**1. Create the app.** At [api.slack.com/apps](https://api.slack.com/apps), create an app from `slack-manifest.yaml`. It sets up the user-token scopes, a minimal bot user, and the `http://localhost:3118/oauth/callback` redirect. Trim the scopes to what you need.

**2. Enable MCP.** Under **App Settings > Agents & Assistants**, turn on both the Agents & Assistants toggle and the MCP toggle.

**3. Add credentials.** Copy Client ID and Client Secret from **Basic Information** into `.env` as `SLACK_MCP_CLIENT_ID` and `SLACK_MCP_CLIENT_SECRET`.

**4. Authorize once on the host.** `mcp-remote` binds its callback to `127.0.0.1`, which isn't reachable inside the container, so the first flow runs on the host:

```bash
docker compose stop 1mcp        # free port 3118
npx mcp-remote https://mcp.slack.com/mcp 3118 \
  --static-oauth-client-info '{"client_id":"YOUR_CLIENT_ID","client_secret":"YOUR_CLIENT_SECRET"}' \
  --auth-timeout 120
# authorize in the browser, wait for "Connected", then Ctrl+C
docker compose up -d
```

The token is cached in `~/.mcp-auth/`, which is mounted into the container, so later restarts need no browser.

**Re-auth** when Slack stops returning tools: `docker compose stop 1mcp`, `rm -rf ~/.mcp-auth/mcp-remote-*`, and repeat step 4.

## Running as a daemon (macOS)

```bash
./ctl.sh start            # tunnel (if configured), stack, and watchdogs
./ctl.sh stop             # unload watchdogs, tear down stack
./ctl.sh restart
./ctl.sh status           # containers and watchdog state
./ctl.sh probe            # per-server tool counts
./ctl.sh logs [N]         # tail compose logs
./ctl.sh watchdog-load    # watchdog only, containers untouched
./ctl.sh watchdog-unload
```

`ctl.sh start` installs `com.1mcp.watchdog.plist` into `~/Library/LaunchAgents/` (substituting the repo path) and launchd runs `watchdog.sh` every 5 minutes. The watchdog waits for Docker, restarts the stack if the agent container is stopped or unhealthy, and logs to `logs/watchdog.log` (rotated at 1 MB).

### Detecting servers that go dark

The agent's `/health` endpoint only reflects transport connections. When an upstream session expires behind a connected client, that server keeps reporting healthy while serving zero tools.

So once `/health` passes, the watchdog runs `probe-servers.sh`: it opens a real MCP session through the proxy, pages through `tools/list`, and compares the servers actually serving tools against the enabled entries in your config. Restarts are guarded so an upstream outage can't cause a loop:

- **Warmup** - no probing in the first 180s after the container starts.
- **Two strikes** - a server must be missing on two consecutive checks.
- **Cooldown** - at most one probe-triggered restart per hour.
- **Inconclusive is not failure** - if the probe itself errors, it's logged and not counted.

`./ctl.sh probe` exits 0 when all servers are present, 1 when some are missing, 2 when the probe failed.

## Keeping a private config

The repo is meant to be cloned and made your own without forking. Personal files go in `private/`, which is gitignored here and works well as its own private git repo:

```bash
mkdir private && git -C private init
mv mcp.json private/
echo 'MCP_CONFIG=./private/mcp.json' >> .env
```

```
private/
├── mcp.json        your real server list
├── launchd/        extra launchd agents, loaded and unloaded by ctl.sh with the stack
└── ...             docs, scripts, anything else
```

Compose, `ctl.sh`, and the probe all read `MCP_CONFIG`, so upstream changes pull cleanly and nothing personal can be committed to this repo by accident. Plists in `private/launchd/` support the same `__COMPOSE_DIR__` and `__HOME__` placeholders as the main watchdog, plus `__LOCAL_DIR__`. Set `LOCAL_DIR` to use a different directory.

Keep `.env` out of git either way - back it up with a password manager.

## Troubleshooting

**Postgres queries fail with `MCP error -32603` while `psql` on the same port works.** The Postgres server opens its pool when the container starts, so if the tunnel wasn't up at that moment it holds a dead pool until restarted. Restart the agent. To prevent it, set `DATA_RO_CONNECT` to the script that opens your tunnel (SSM, SSH, etc.); `ctl.sh start` runs `<script> ${DATA_RO_ENV:-production} --as-user <user> --local-port <port> --daemon` before starting the stack, with user and port taken from `REPLICA_DATABASE_URL`. It's best-effort: if the tunnel fails, the stack starts anyway. `./ctl.sh ensure-tunnel` runs just that step.

**An OAuth-based server stops returning tools.** Its upstream token expired and didn't refresh. Re-run that server's auth flow (for Slack, see [Re-auth](#slack-setup)). The watchdog restarts the stack when a server goes dark, but it can't refresh a token.

**`./ctl.sh probe` fails with a connection reset while containers look healthy.** Docker Desktop's port forwarding is wedged. Restart Docker Desktop, not the stack.

**Servers show 0 tools right after a restart.** Normal for the first few minutes while `npx` servers install and slow upstreams connect.

Logs: `./ctl.sh logs`, `./logs/`, and `curl http://127.0.0.1:9494/health`.

## Project structure

```
.
├── docker-compose.yml         config validator, 1MCP agent, nginx proxy
├── mcp.example.json           starter server config (copy to mcp.json)
├── .env.example               template for secrets and settings
├── validate-config.sh         rejects hyphenated server names before startup
├── ctl.sh                     start/stop/status/probe/logs
├── watchdog.sh                launchd watchdog
├── probe-servers.sh           tools-level health probe
├── com.1mcp.watchdog.plist    launchd template
├── slack-manifest.yaml        Slack app manifest
└── proxy/
    ├── nginx.conf.token.template   bearer-token mode (default)
    └── nginx.conf.oauth.template   1MCP OAuth mode
```

## Links

- [1MCP documentation](https://docs.1mcp.app)
- [1MCP agent on GitHub](https://github.com/1mcp-app/agent)
- [MCP config schema](https://docs.1mcp.app/schemas/v1.0.0/mcp-config.json)

## License

[MIT](LICENSE)
