#!/bin/bash
# =============================================================================
# Hermes 项目自检脚本 — 由 cron 自动调用
# 检查: Shell语法、JS语法、CDN连通性、关键文件完整性
# =============================================================================
set +e  # 手动检查失败项，不因 set -e 提前退出
shopt -s expand_aliases 2>/dev/null

PROJECT="/www/wwwroot/hermes-windows-deploy"
CDN_BASE="http://121.40.165.216/hermes-cdn/files"
LOG_FILE="/var/log/hermes-self-check.log"
PASS=0
FAIL=0
ISSUES=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# ---- 1. Shell 语法 ----
log "--- Shell 语法检查 ---"
for f in "$PROJECT/scripts/"*.sh; do
    if bash -n "$f" 2>/dev/null; then
        log "  ✓ $(basename $f)"
        ((PASS++))
    else
        log "  ✗ $(basename $f) — 语法错误"
        ISSUES+="  SHELL_SYNTAX: $(basename $f)\n"
        ((FAIL++))
    fi
done

# ---- 2. JS 语法 ----
log "--- JS 语法检查 ---"
for f in "$PROJECT/desktop/chat/server/"*.js "$PROJECT/desktop/hitl/server/"*.js; do
    [ -f "$f" ] || continue
    if node -c "$f" 2>/dev/null; then
        log "  ✓ $(basename $f)"
        ((PASS++))
    else
        log "  ✗ $(basename $f) — 语法错误"
        ISSUES+="  JS_SYNTAX: $(basename $f)\n"
        ((FAIL++))
    fi
done

# ---- 3. Vue 标签配对 ----
log "--- Vue 标签配对 ---"
for f in $(find "$PROJECT/desktop" -name "*.vue" 2>/dev/null); do
    t_open=$(grep -c '<template>' "$f" 2>/dev/null || echo 0)
    t_close=$(grep -c '</template>' "$f" 2>/dev/null || echo 0)
    s_open=$(grep -c '<script' "$f" 2>/dev/null || echo 0)
    s_close=$(grep -c '</script>' "$f" 2>/dev/null || echo 0)
    if [ "$t_open" = "$t_close" ] && [ "$s_open" = "$s_close" ]; then
        log "  ✓ $(basename $f)"
        ((PASS++))
    else
        log "  ✗ $(basename $f) — 标签不配对 (template: $t_open/$t_close, script: $s_open/$s_close)"
        ISSUES+="  VUE_TAG: $(basename $f)\n"
        ((FAIL++))
    fi
done

# ---- 4. CDN 连通性 ----
log "--- CDN 连通性 ---"
for f in hermes-agent.tar.gz hermes-install-standalone.sh setup-node22.x wsl_update_x64.msi; do
    code=$(curl -sI -o /dev/null -w "%{http_code}" "$CDN_BASE/$f" --max-time 10 2>/dev/null)
    if [ "$code" = "200" ]; then
        log "  ✓ $f (HTTP 200)"
        ((PASS++))
    else
        log "  ✗ $f (HTTP $code)"
        ISSUES+="  CDN_OFFLINE: $f (HTTP $code)\n"
        ((FAIL++))
    fi
done

# ---- 5. 关键文件完整性 ----
log "--- 文件完整性 ---"
CRITICAL_FILES=(
    "scripts/install-hermes.ps1"
    "scripts/wsl-bootstrap.sh"
    "scripts/setup-mirrors.sh"
    "scripts/setup-systemd.sh"
    "scripts/integrate-desktop.sh"
    "scripts/post-install.ps1"
    "scripts/uninstall.ps1"
    "scripts/build.ps1"
    "desktop/chat/server/chat-endpoint.js"
    "desktop/chat/client/ChatPage.vue"
    "desktop/hitl/server/approval-ws.js"
    "desktop/hitl/client/ApprovalPanel.vue"
    "desktop/mcp/ToolHub.vue"
    "desktop/shell/register-shell.ps1"
    "desktop/shell/send-to-hermes.ps1"
    "desktop/shell/unregister-shell.ps1"
    "gui/HermesInstaller/HermesInstaller.csproj"
    "installer/hermes-installer.iss"
    "README.md"
    "实现计划书.md"
)
for f in "${CRITICAL_FILES[@]}"; do
    if [ -s "$PROJECT/$f" ]; then
        log "  ✓ $f"
        ((PASS++))
    else
        log "  ✗ $f — 缺失或为空"
        ISSUES+="  FILE_MISSING: $f\n"
        ((FAIL++))
    fi
done

# ---- 汇总 ----
log ""
log "========================================"
log "通过: $PASS  失败: $FAIL"
log "========================================"

if [ "$FAIL" -gt 0 ]; then
    log "⚠ 以下问题需关注:"
    echo -e "$ISSUES" | tee -a "$LOG_FILE"
else
    log "✅ 全部检查通过"
fi
