#!/bin/bash
# 1mcp control script
# Usage: ./ctl.sh {start|stop|restart|status|probe|logs|ensure-tunnel|watchdog-load|watchdog-unload}

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="${LOCAL_DIR:-$COMPOSE_DIR/private}"
PLIST_NAME="com.1mcp.watchdog"
PLIST_SRC="$COMPOSE_DIR/$PLIST_NAME.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

cd "$COMPOSE_DIR"

# The postgres_replica server dials the DB when the container starts, not on first query, so if
# the SSM tunnel isn't up yet it comes up with a dead pool and every query fails with an opaque
# -32603 until 1mcp is restarted. Bringing the tunnel up first makes that race impossible.
#
# Strictly best-effort: this must never stop the other servers from starting, so every step
# is guarded (the script runs under `set -e`) and failure only prints a warning.
ensure_replica_tunnel() {
  local script url user port
  script="${DATA_RO_CONNECT:-}"
  if [[ -z "$script" ]]; then
    script="$(grep -m1 '^DATA_RO_CONNECT=' .env 2>/dev/null | cut -d= -f2- || true)"
  fi
  script="${script/#\~/$HOME}"
  [[ -x "$script" ]] || return 0

  # Derive user and port from the URL already in .env - no second place to keep in sync.
  url="$(grep -m1 '^REPLICA_DATABASE_URL=' .env 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "$url" ]] || return 0
  user="$(printf '%s' "$url" | sed -n 's|^postgresql://\([^:]*\):.*|\1|p' || true)"
  port="$(printf '%s' "$url" | sed -n 's|.*@[^:]*:\([0-9]*\)/.*|\1|p' || true)"
  [[ -n "$user" && -n "$port" ]] || return 0

  echo "Ensuring data-ro tunnel on :$port ..."
  if "$script" "${DATA_RO_ENV:-production}" --as-user "$user" --local-port "$port" --daemon; then
    return 0
  fi
  echo "  WARNING: could not establish the data-ro tunnel."
  echo "  Starting anyway - every other MCP server is unaffected. Once the tunnel is up, run"
  echo "  '$0 restart' so postgres_replica reconnects."
  return 0
}

install_plist() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  while IFS= read -r line; do
    line="${line//__COMPOSE_DIR__/$COMPOSE_DIR}"
    line="${line//__LOCAL_DIR__/$LOCAL_DIR}"
    printf '%s\n' "${line//__HOME__/$HOME}"
  done < "$src" > "$dst"
}

load_plist() {
  local src="$1" dst="$HOME/Library/LaunchAgents/$(basename "$1")"
  [[ -f "$dst" ]] && launchctl unload "$dst" 2>/dev/null || true
  install_plist "$src" "$dst"
  launchctl load "$dst"
}

unload_plist() {
  launchctl unload "$HOME/Library/LaunchAgents/$(basename "$1")" 2>/dev/null || true
}

# Personal launchd agents (e.g. a watchdog for a host-side MCP) live in the gitignored overlay
extra_plists() {
  compgen -G "$LOCAL_DIR/launchd/*.plist" || true
}

config_path() {
  local cfg="${MCP_CONFIG:-}"
  [[ -n "$cfg" ]] || cfg="$(grep -m1 '^MCP_CONFIG=' .env 2>/dev/null | cut -d= -f2- || true)"
  printf '%s' "${cfg:-./mcp.json}"
}

case "${1:-}" in
  ensure-tunnel)
    ensure_replica_tunnel
    ;;

  start)
    if [[ ! -f "$(config_path)" ]]; then
      echo "No server config at $(config_path). Run: cp mcp.example.json mcp.json" >&2
      exit 1
    fi
    echo "Starting 1mcp stack..."
    ensure_replica_tunnel || true
    # --remove-orphans so retired services with "restart: always" can't resurrect themselves
    docker compose up -d --remove-orphans
    echo "Loading watchdogs..."
    load_plist "$PLIST_SRC"
    while IFS= read -r plist; do
      [[ -n "$plist" ]] && load_plist "$plist" && echo "  loaded $(basename "$plist" .plist)"
    done < <(extra_plists)
    echo "Done. Stack running, watchdogs active."
    ;;

  stop)
    echo "Unloading watchdogs..."
    unload_plist "$PLIST_SRC"
    while IFS= read -r plist; do
      [[ -n "$plist" ]] && unload_plist "$plist"
    done < <(extra_plists)
    echo "Stopping 1mcp stack..."
    docker compose down --remove-orphans
    echo "Done."
    ;;

  restart)
    "$0" stop
    "$0" start
    ;;

  status)
    echo "=== Containers ==="
    docker compose ps
    echo ""
    echo "=== Watchdogs ==="
    while IFS= read -r plist; do
      [[ -n "$plist" ]] || continue
      label="$(basename "$plist" .plist)"
      if launchctl list "$label" &>/dev/null; then
        echo "$label: loaded"
      else
        echo "$label: not loaded"
      fi
    done < <(printf '%s\n' "$PLIST_SRC"; extra_plists)
    ;;

  probe)
    exec "$COMPOSE_DIR/probe-servers.sh" "${@:2}"
    ;;

  logs)
    docker compose logs --tail="${2:-100}" --follow
    ;;

  watchdog-load)
    load_plist "$PLIST_SRC"
    echo "Watchdog loaded."
    ;;

  watchdog-unload)
    unload_plist "$PLIST_SRC"
    echo "Watchdog unloaded."
    ;;

  help|--help|-h)
    cat <<'USAGE'
1mcp control script

Commands:
  start                 Start the stack and load the watchdogs
  stop                  Unload the watchdogs and tear down the stack
  restart               Stop then start
  status                Show container and watchdog status
  probe [--quiet]       Check every configured server actually serves tools
  logs [N]              Tail docker compose logs (default: last 100 lines)
  ensure-tunnel         Open the replica DB tunnel without starting the stack
  watchdog-load         Load just the 1mcp watchdog (without touching containers)
  watchdog-unload       Unload just the 1mcp watchdog
  help                  Show this message

Extra launchd agents in $LOCAL_DIR/launchd/*.plist are loaded and unloaded with the stack.
USAGE
    ;;

  *)
    "$0" help
    exit 1
    ;;
esac
