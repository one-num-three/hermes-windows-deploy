#!/bin/bash
# =============================================================================
# systemd 服务配置 + 启动
# 在 WSL Ubuntu 内执行: sudo bash setup-systemd.sh
# 环境变量: WSL_USER, WEB_PORT (由 PowerShell 传入)
# =============================================================================
set -e

USER="${WSL_USER:-hermes}"
PORT="${WEB_PORT:-8648}"
HOME_DIR="/home/$USER"
HERMES_HOME="$HOME_DIR/.hermes"

echo "=== 配置 Hermes systemd 服务 ==="
echo "用户: $USER"
echo "端口: $PORT"

# 1. 确保 systemd 可用（使用目录检测替代 pidof，更可靠）
if [ ! -d /run/systemd/system ]; then
    echo "systemd 未运行，尝试启动..."
    # 检查 /etc/wsl.conf
    if ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
        # 检查 [boot] 节是否已存在，避免重复追加
        if grep -q "^\[boot\]" /etc/wsl.conf 2>/dev/null; then
            # [boot] 节已存在，在节内追加 systemd=true
            echo "systemd=true" >> /etc/wsl.conf
        else
            echo "[boot]" >> /etc/wsl.conf
            echo "systemd=true" >> /etc/wsl.conf
        fi
        echo "已添加 systemd=true 到 /etc/wsl.conf"
        echo "请重启 WSL: wsl --shutdown && wsl"
    fi
    # 配置成功 → 返回 0（非致命）。安装脚本将提示重启
    exit 0
fi

# 2. 检查 hermes 是否已安装
if ! su - "$USER" -c "command -v hermes" 2>/dev/null; then
    echo "Hermes 未安装，请先运行安装脚本"
    exit 1
fi

# 3. 创建服务文件
cat > /etc/systemd/system/hermes.service << SERVICEEOF
[Unit]
Description=Hermes Agent Gateway Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HERMES_HOME
ExecStart=$HOME_DIR/.local/bin/hermes-start $PORT
Restart=always
RestartSec=10
Environment=HOME=$HOME_DIR
Environment=PATH=$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SERVICEEOF

echo "服务文件已创建: /etc/systemd/system/hermes.service"

# 4. 确保 .hermes 目录存在且权限正确
mkdir -p "$HERMES_HOME"
chown -R "$USER:$USER" "$HERMES_HOME"

# 5. 重新加载 systemd
systemctl daemon-reload

# 6. 启用并启动
systemctl enable hermes
systemctl start hermes || {
    echo "服务启动失败，查看日志:"
    journalctl -u hermes --no-pager -n 20
    exit 1
}

# 7. 验证（重试循环取代固定 sleep，提高可靠性）
for i in 1 2 3 4 5; do
    if systemctl is-active --quiet hermes 2>/dev/null; then
        echo "=== Hermes 服务运行中 ==="
        systemctl status hermes --no-pager
        exit 0
    fi
    echo "等待服务启动... (${i}s)"
    sleep 1
done
echo "Hermes 服务未运行"
journalctl -u hermes --no-pager -n 20
exit 1
