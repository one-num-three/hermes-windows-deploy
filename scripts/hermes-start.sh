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
if [ ! -f /opt/hermes/hermes-web-ui/dist/server/index.js ]; then
  echo "hermes-web-ui server entry not found" >>"$LOG_FILE"
  exit 1
fi

INDEX_FILE="/opt/hermes/hermes-web-ui/dist/client/index.html"
if [ -f "$INDEX_FILE" ] && ! grep -q "hermes-installer-locale-default" "$INDEX_FILE"; then
  python3 - <<'PY'
from pathlib import Path

path = Path("/opt/hermes/hermes-web-ui/dist/client/index.html")
text = path.read_text(encoding="utf-8")
snippet = """  <script id="hermes-installer-locale-default">
    try {
      var hashQuery = (location.hash.split("?")[1] || "");
      var params = new URLSearchParams(hashQuery);
      if (params.get("lang") === "zh" || !localStorage.getItem("hermes_locale")) {
        localStorage.setItem("hermes_locale", "zh");
      }
    } catch (e) {}
  </script>
"""
if "hermes-installer-locale-default" not in text:
    text = text.replace("</head>", snippet + "</head>")
    path.write_text(text, encoding="utf-8")
PY
fi

if [ ! -f "$TOKEN_FILE" ] || ! tr -d '\r\n' < "$TOKEN_FILE" | grep -Eq '^[0-9a-f]{64}$'; then
  python3 - <<'PY' > "$TOKEN_FILE"
import secrets
print(secrets.token_hex(32))
PY
  chmod 600 "$TOKEN_FILE"
fi

export AUTH_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
export PORT="$PORT"
hermes-web-ui stop >>"$LOG_FILE" 2>&1 || true
fuser -k "$PORT/tcp" >>"$LOG_FILE" 2>&1 || true
chmod +x /opt/hermes/hermes-web-ui/node_modules/node-pty/prebuilds/*/spawn-helper 2>/dev/null || true
exec node /opt/hermes/hermes-web-ui/dist/server/index.js >>"$LOG_FILE" 2>&1
