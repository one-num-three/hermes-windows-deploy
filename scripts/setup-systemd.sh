#!/bin/bash
# =============================================================================
# systemd service setup + startup
# Run inside WSL Ubuntu: sudo bash setup-systemd.sh
# Env vars: WSL_USER, WEB_PORT
# =============================================================================
set -euo pipefail

if [ -n "${WSL_USER:-}" ] && ! echo "$WSL_USER" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
    echo "Invalid WSL_USER: $WSL_USER" >&2
    exit 1
fi
if [ -n "${WEB_PORT:-}" ] && ! echo "$WEB_PORT" | grep -qE '^[0-9]+$'; then
    echo "Invalid WEB_PORT: $WEB_PORT" >&2
    exit 1
fi
if [ -n "${WEB_PORT:-}" ] && { [ "$WEB_PORT" -lt 1 ] || [ "$WEB_PORT" -gt 65535 ]; } 2>/dev/null; then
    echo "WEB_PORT out of range: $WEB_PORT" >&2
    exit 1
fi

USER_NAME="${WSL_USER:-hermes}"
PORT="${WEB_PORT:-8648}"
START_SCRIPT="/usr/local/bin/hermes-start"

echo "=== Configure Hermes systemd service ==="
echo "User: $USER_NAME"
echo "Port: $PORT"

if [ ! -d /run/systemd/system ]; then
    echo "systemd is not active inside WSL"
    if ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
        if grep -q "^\[boot\]" /etc/wsl.conf 2>/dev/null; then
            sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        else
            {
                echo "[boot]"
                echo "systemd=true"
            } >> /etc/wsl.conf
        fi
        echo "Added systemd=true to /etc/wsl.conf"
        echo "Restart WSL with: wsl --shutdown"
    fi
    exit 0
fi

if ! command -v hermes >/dev/null 2>&1; then
    echo "Hermes is not installed yet" >&2
    exit 1
fi

if ! command -v hermes-web-ui >/dev/null 2>&1; then
    echo "hermes-web-ui is not installed yet" >&2
    exit 1
fi

cat > "$START_SCRIPT" <<'EOF'
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
EOF
chmod +x "$START_SCRIPT"

cat > /etc/systemd/system/hermes.service <<EOF
[Unit]
Description=Hermes Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hermes/hermes-web-ui
ExecStart=$START_SCRIPT $PORT
Environment=HOME=/root
Environment=HERMES_HOME=/root/.hermes
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=3
KillMode=control-group

[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl disable --now hermes || true

echo "Hermes systemd service file is installed but disabled."
echo "Windows uses the HermesAgent-StartWSL scheduled task as the foreground keep-alive process."
exit 0
