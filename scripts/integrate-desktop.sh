#!/bin/bash
# =============================================================================
# Hermes 桌面增强功能集成脚本
# 在 hermes-web-ui 安装后执行，注入 Chat/审批/ToolHub 等模块
# 调用: sudo bash integrate-desktop.sh <username>
# =============================================================================
set -e

USER="${1:-hermes}"
HOME_DIR="/home/$USER"

echo "=== Hermes 桌面增强集成 ==="
echo "用户: $USER"

# ---- 1. 找到 hermes-web-ui 安装位置 ----
WEBUI_DIR=$(npm root -g 2>/dev/null)/hermes-web-ui
if [ ! -d "$WEBUI_DIR" ]; then
    # 尝试其他可能路径
    WEBUI_DIR="/usr/lib/node_modules/hermes-web-ui"
fi
if [ ! -d "$WEBUI_DIR" ]; then
    echo "错误: 找不到 hermes-web-ui，请先安装"
    exit 1
fi
echo "[1/6] hermes-web-ui 位置: $WEBUI_DIR"

# ---- 2. 注入 Chat API 端点 ----
echo "[2/6] 注入 Agent Chat API..."
CHAT_SRC="/tmp/chat-endpoint.js"
CHAT_DST="$WEBUI_DIR/server/routes/chat.js"

if [ -f "$CHAT_SRC" ]; then
    cp "$CHAT_SRC" "$CHAT_DST"
    echo "  已安装: server/routes/chat.js"

    # 注册路由（在 server 入口添加）
    SERVER_MAIN="$WEBUI_DIR/server/index.js"
    if [ -f "$SERVER_MAIN" ] && ! grep -q "require.*routes/chat" "$SERVER_MAIN"; then
        echo "const chatRouter = require('./routes/chat');" >> "$SERVER_MAIN"
        echo "app.use('/api/chat', chatRouter);" >> "$SERVER_MAIN"
        echo "  已注册 /api/chat 路由"
    fi
else
    echo "  跳过（源码未找到）"
fi

# ---- 3. 注入 Vue 组件 ----
echo "[3/6] 注入前端组件..."

COMPONENTS_DIR="$WEBUI_DIR/client/src/views"
mkdir -p "$COMPONENTS_DIR/hermes"

# ChatPage
if [ -f "/tmp/ChatPage.vue" ]; then
    cp "/tmp/ChatPage.vue" "$COMPONENTS_DIR/hermes/ChatPage.vue"
    echo "  已安装: ChatPage.vue"
fi

# ApprovalPanel
if [ -f "/tmp/ApprovalPanel.vue" ]; then
    cp "/tmp/ApprovalPanel.vue" "$COMPONENTS_DIR/hermes/ApprovalPanel.vue"
    echo "  已安装: ApprovalPanel.vue"
fi

# ToolHub
if [ -f "/tmp/ToolHub.vue" ]; then
    cp "/tmp/ToolHub.vue" "$COMPONENTS_DIR/hermes/ToolHub.vue"
    echo "  已安装: ToolHub.vue"
fi

# ---- 4. 注册前端路由 ----
echo "[4/6] 注册前端路由..."
ROUTER_FILE="$WEBUI_DIR/client/src/router/index.js"
if [ -f "$ROUTER_FILE" ]; then
    if ! grep -q "ChatPage" "$ROUTER_FILE"; then
        # 在路由数组前添加 import
        sed -i '1i import ChatPage from "@/views/hermes/ChatPage.vue"' "$ROUTER_FILE" 2>/dev/null || true
        sed -i '1i import ApprovalPanel from "@/views/hermes/ApprovalPanel.vue"' "$ROUTER_FILE" 2>/dev/null || true
        sed -i '1i import ToolHub from "@/views/hermes/ToolHub.vue"' "$ROUTER_FILE" 2>/dev/null || true
        echo "  已添加路由导入"
    fi
fi

# ---- 5. 配置 WebSocket 代理 ----
echo "[5/6] 配置 WebSocket 审批..."
APPROVAL_SRC="/tmp/approval-ws.js"
if [ -f "$APPROVAL_SRC" ]; then
    cp "$APPROVAL_SRC" "$WEBUI_DIR/server/approval-ws.js"
    echo "  已安装: server/approval-ws.js"

    SERVER_MAIN="$WEBUI_DIR/server/index.js"
    if [ -f "$SERVER_MAIN" ] && ! grep -q "ApprovalManager" "$SERVER_MAIN"; then
        echo "const ApprovalManager = require('./approval-ws');" >> "$SERVER_MAIN"
        echo "const approvalMgr = new ApprovalManager(server);" >> "$SERVER_MAIN"
        echo "  已注册 WebSocket 审批服务"
    fi
fi

# ---- 6. 创建启动脚本（同时启动 gateway + web-ui） ----
echo "[6/6] 创建启动脚本..."

cat > "$HOME_DIR/.local/bin/hermes-start" << 'STARTEOF'
#!/bin/bash
# Hermes 完整启动：Gateway + Web UI + 桌面增强

HERMES_PORT="${1:-8648}"

echo "启动 Hermes Gateway..."
hermes gateway --port $HERMES_PORT &
GATEWAY_PID=$!

sleep 3

echo "启动 Web UI..."
hermes-web-ui start --port $HERMES_PORT &
WEBUI_PID=$!

echo ""
echo "==================================="
echo "  Hermes Agent 已启动"
echo "  Web UI: http://localhost:$HERMES_PORT"
echo "  Chat:   http://localhost:$HERMES_PORT/chat"
echo "  审批:   自动运行（右下角面板）"
echo "==================================="

wait
STARTEOF

chmod +x "$HOME_DIR/.local/bin/hermes-start"
chown "$USER:$USER" "$HOME_DIR/.local/bin/hermes-start"

echo "=== 集成完成 ==="
echo ""
echo "新增功能:"
echo "  • Agent Chat 对话面板 → http://localhost:8648/chat"
echo "  • HITL 审批面板 → 敏感操作自动弹出"
echo "  • MCP Tool Hub → 工具注册管理"
echo "  • 右键菜单 → Windows 资源管理器集成"
