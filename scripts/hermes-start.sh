#!/bin/bash
set -euo pipefail

PORT="${1:-8648}"
LOG_DIR="/var/log/hermes"
LOG_FILE="$LOG_DIR/webui.log"
export HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
APP_HOME="/root/.hermes-web-ui"
TOKEN_FILE="$APP_HOME/.token"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
mkdir -p "$APP_HOME"

cd /opt/hermes/hermes-web-ui
if ! command -v hermes-web-ui >/dev/null 2>&1; then
  echo "hermes-web-ui command not found" >>"$LOG_FILE"
  exit 1
fi

if [ ! -f "$TOKEN_FILE" ] || ! tr -d '\r\n' < "$TOKEN_FILE" | grep -Eq '^[0-9a-f]{64}$'; then
  python3 - <<'PY' > "$TOKEN_FILE"
import secrets
print(secrets.token_hex(32))
PY
  chmod 600 "$TOKEN_FILE"
fi

export AUTH_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
hermes-web-ui start "$PORT" >>"$LOG_FILE" 2>&1
