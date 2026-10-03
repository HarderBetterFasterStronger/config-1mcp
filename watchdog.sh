#!/bin/bash
# 1mcp watchdog - restarts the stack if the agent container is unhealthy or stopped.
# Designed to be invoked by launchd every 5 minutes.

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$COMPOSE_DIR/logs/watchdog.log"
MAX_LOG_SIZE=1048576 # 1 MB

# launchd gives us a bare environment, so ONE_MCP_PORT et al must come from .env
[[ -f "$COMPOSE_DIR/.env" ]] && { set -a; . "$COMPOSE_DIR/.env"; set +a; }

FAIL_STATE="$COMPOSE_DIR/logs/.probe-failures"
RESTART_STATE="$COMPOSE_DIR/logs/.probe-last-restart"
WARMUP_SECS=180        # clients reconnect lazily; don't probe a just-started container
PROBE_COOLDOWN=3600    # a genuine upstream outage shouldn't cause a restart loop
FAILS_BEFORE_RESTART=2

mkdir -p "$(dirname "$LOG")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# Rotate log if too large
if [[ -f "$LOG" ]] && (( $(stat -f%z "$LOG" 2>/dev/null || echo 0) > MAX_LOG_SIZE )); then
  mv "$LOG" "$LOG.1"
fi

# Wait for Docker daemon (up to 5 min at boot, then give up for this cycle)
RETRIES=0
MAX_RETRIES=30
while ! docker info &>/dev/null; do
  RETRIES=$((RETRIES + 1))
  if (( RETRIES > MAX_RETRIES )); then
    log "WARN: Docker daemon not running after ${MAX_RETRIES} attempts, skipping"
    exit 0
  fi
  sleep 10
done

cd "$COMPOSE_DIR"

AGENT_STATUS=$(docker compose ps --format json 2>/dev/null | \
  python3 -c "import sys,json
for line in sys.stdin:
    c=json.loads(line)
    if c.get('Service')=='1mcp':
        print(c.get('State','unknown'))
        break
else:
    print('missing')" 2>/dev/null || echo "error")

container_age() {
  local started
  started=$(docker inspect -f '{{.State.StartedAt}}' 1mcp-agent 2>/dev/null) || { echo 0; return; }
  python3 -c "
import datetime,sys
s='$started'.replace('Z','+00:00')
s=s[:s.index('.')+7]+'+00:00' if '.' in s else s
try: print(int((datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(s)).total_seconds()))
except Exception: print(0)" 2>/dev/null || echo 0
}

if [[ "$AGENT_STATUS" == "running" ]]; then
  # Also check health endpoint directly
  if docker exec 1mcp-agent node -e \
    "fetch('http://localhost:${ONE_MCP_PORT:-3050}/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))" \
    &>/dev/null; then

    # /health only reflects transport connection: a client whose upstream session
    # expired still counts healthy while serving zero tools. Probe tools/list instead.
    if (( $(container_age) < WARMUP_SECS )); then
      exit 0
    fi

    # `|| PROBE_RC=$?` is load-bearing: errexit would kill the script on a failing probe
    PROBE_RC=0
    PROBE_OUT=$("$COMPOSE_DIR/probe-servers.sh" --quiet 2>&1) || PROBE_RC=$?
    if (( PROBE_RC == 0 )); then
      rm -f "$FAIL_STATE"
      exit 0
    fi
    if (( PROBE_RC != 1 )); then
      log "WARN: server probe inconclusive (rc=$PROBE_RC): $PROBE_OUT"
      exit 0
    fi

    FAILS=$(( $(cat "$FAIL_STATE" 2>/dev/null || echo 0) + 1 ))
    echo "$FAILS" > "$FAIL_STATE"
    log "WARN: server probe failed (${FAILS}/${FAILS_BEFORE_RESTART}): $PROBE_OUT"
    if (( FAILS < FAILS_BEFORE_RESTART )); then
      exit 0
    fi

    SINCE=$(( $(date +%s) - $(cat "$RESTART_STATE" 2>/dev/null || echo 0) ))
    if (( SINCE < PROBE_COOLDOWN )); then
      log "INFO: probe-triggered restart on cooldown (${SINCE}s of ${PROBE_COOLDOWN}s), skipping"
      exit 0
    fi

    date +%s > "$RESTART_STATE"
    rm -f "$FAIL_STATE"
    log "WARN: servers still missing after ${FAILS} checks, restarting"
  else
    log "WARN: Agent container running but health check failed, restarting"
  fi
else
  log "WARN: Agent container status: $AGENT_STATUS, restarting"
fi

log "INFO: Restarting 1mcp stack..."
# `up -d` is a no-op on a running container, so a wedged agent needs an explicit restart
if [[ "$AGENT_STATUS" == "running" ]]; then
  RESTART_CMD=(docker compose restart 1mcp)
else
  # --remove-orphans so retired services aren't left running
  RESTART_CMD=(docker compose up -d --remove-orphans)
fi
if "${RESTART_CMD[@]}" 2>>"$LOG"; then
  log "INFO: Restart complete"
else
  log "ERROR: Restart failed (exit $?), will retry next cycle"
fi
