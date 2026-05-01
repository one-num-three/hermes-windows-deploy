#!/bin/bash
# =============================================================================
# Hermes WSL 引导脚本
# 首次登录后初始化 WSL Ubuntu 环境
# 调用: bash bootstrap.sh <username>
# =============================================================================
set -e

USERNAME="${1:-hermes}"
HOME_DIR="/home/$USERNAME"
HERMES_HOME="$HOME_DIR/.hermes"

echo "=== Hermes WSL 引导脚本 ==="
echo "用户: $USERNAME"

# 更新 apt
echo "[1/6] 更新 apt 包列表..."
sudo apt-get update -qq

# 安装基础包
echo "[2/6] 安装基础依赖..."
sudo apt-get install -y -qq python3 python3-pip python3-venv python3-dev curl git wget build-essential

# 设置 pip 镜像
echo "[3/6] 配置 pip 镜像源..."
mkdir -p "$HOME_DIR/.pip"
cat > "$HOME_DIR/.pip/pip.conf" << EOF
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF

# 设置 git 代理
echo "[4/6] 配置 Git 代理..."
git config --global url."https://ghproxy.com/https://github.com/".insteadOf "https://github.com/"

# 确保 ~/.local/bin 在 PATH
echo "[5/6] 配置 PATH..."
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"

# 创建 Hermes 目录结构
echo "[6/6] 创建 Hermes 目录..."
mkdir -p "$HERMES_HOME"
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"

echo "=== 引导完成 ==="
