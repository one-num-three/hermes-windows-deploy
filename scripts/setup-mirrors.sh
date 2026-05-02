#!/bin/bash
# =============================================================================
# 国内镜像源自动配置脚本
# 配置 apt / pip / npm 使用国内镜像
# 调用: sudo bash setup-mirrors.sh
# =============================================================================
set -e

echo "=== 配置国内镜像源 ==="

# ---- apt 源 → 清华镜像 ----
echo "[1/3] 配置 apt 镜像源..."
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    # Ubuntu 24.04+ 使用 deb822 格式
    # 保留原文件（如果备份已存在则不重复备份）
    if [ ! -f /etc/apt/sources.list.d/ubuntu.sources.bak ]; then
        cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak 2>/dev/null || true
    else
        echo "  ubuntu.sources.bak 已存在，跳过备份"
    fi
    sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources
    sed -i 's|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources
    sed -i 's|http://ports.ubuntu.com/ubuntu-ports/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' /etc/apt/sources.list.d/ubuntu.sources
elif [ -f /etc/apt/sources.list ]; then
    # 旧版格式
    if command -v lsb_release &> /dev/null; then
        CODENAME=$(lsb_release -cs)
    else
        CODENAME="noble"
    fi
    if [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
    else
        echo "  sources.list.bak 已存在，跳过备份"
    fi
    cat > /etc/apt/sources.list << EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $CODENAME main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $CODENAME-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $CODENAME-security main restricted universe multiverse
EOF
fi

echo "apt 镜像源已配置"
sudo apt-get update -qq 2>/dev/null || {
    echo "apt update 失败，还原备份..."
    if [ -f /etc/apt/sources.list.bak ]; then
        mv /etc/apt/sources.list.bak /etc/apt/sources.list
    fi
    if [ -f /etc/apt/sources.list.d/ubuntu.sources.bak ]; then
        mv /etc/apt/sources.list.d/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources
    fi
}

# ---- pip 源 → 清华镜像 ----
echo "[2/3] 配置 pip 镜像源..."
pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null || true

# ---- npm 源 → 淘宝镜像 ----
echo "[3/3] 配置 npm 镜像源..."
if command -v npm &> /dev/null; then
    npm config set registry https://registry.npmmirror.com 2>/dev/null || true
else
    echo "npm 未安装，跳过"
fi

echo "=== 镜像源配置完成 ==="
