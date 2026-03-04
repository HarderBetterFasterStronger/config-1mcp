#!/bin/bash
# 1mcp control script
# Usage: ./ctl.sh {start|stop|restart|status|logs|watchdog-load|watchdog-unload}

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.1mcp.watchdog"
PLIST_SRC="$COMPOSE_DIR/$PLIST_NAME.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

cd "$COMPOSE_DIR"

install_plist() {
  mkdir -p "$(dirname "$PLIST_DST")"
  while IFS= read -r line; do
    printf '%s\n' "${line//__COMPOSE_DIR__/$COMPOSE_DIR}"
  done < "$PLIST_SRC" > "$PLIST_DST"
}

case "${1:-}" in
  start)
    echo "Starting 1mcp stack..."
    docker compose up -d
    echo "Loading watchdog..."
    [[ -f "$PLIST_DST" ]] && launchctl unload "$PLIST_DST" 2>/dev/null || true
    install_plist
    launchctl load "$PLIST_DST"
    echo "Done. Stack running, watchdog active."
    ;;

  stop)
    echo "Unloading watchdog..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "Stopping 1mcp stack..."
    docker compose down
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
    echo "=== Watchdog ==="
    if launchctl list "$PLIST_NAME" &>/dev/null; then
      echo "Watchdog: loaded"
      launchctl list "$PLIST_NAME"
    else
      echo "Watchdog: not loaded"
    fi
    ;;

  logs)
    docker compose logs --tail="${2:-100}" --follow
    ;;

  watchdog-load)
    [[ -f "$PLIST_DST" ]] && launchctl unload "$PLIST_DST" 2>/dev/null || true
    install_plist
    launchctl load "$PLIST_DST"
    echo "Watchdog loaded."
    ;;

  watchdog-unload)
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "Watchdog unloaded."
    ;;

  help|--help|-h)
    cat <<'USAGE'
1mcp control script

Commands:
  start            Start the stack and load the watchdog
  stop             Unload the watchdog and tear down the stack
  restart          Stop then start
  status           Show container and watchdog status
  logs [N]         Tail docker compose logs (default: last 100 lines)
  watchdog-load    Load just the watchdog (without touching containers)
  watchdog-unload  Unload just the watchdog
  help             Show this message
USAGE
    ;;

  *)
    "$0" help
    exit 1
    ;;
esac
