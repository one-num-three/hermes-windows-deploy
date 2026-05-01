<!--
=============================================================================
HITL 审批面板 — Vue 3 组件
当 Agent 需要执行敏感操作时弹出，用户可批准/拒绝/修改命令
=============================================================================
-->
<template>
  <div class="approval-panel">
    <!-- 通知徽章 -->
    <div class="approval-badge" v-if="pendingApprovals.length > 0" @click="togglePanel">
      <span class="badge-count">{{ pendingApprovals.length }}</span>
      <span class="badge-label">待审批</span>
    </div>

    <!-- 审批面板 -->
    <transition name="slide">
      <div v-if="isPanelOpen" class="approval-drawer">
        <div class="drawer-header">
          <h3>操作审批中心</h3>
          <button @click="isPanelOpen = false" class="close-btn">✕</button>
        </div>

        <!-- 审批列表 -->
        <div v-if="pendingApprovals.length === 0" class="empty-approvals">
          <p>暂无待审批操作</p>
          <p class="sub">Agent 执行敏感操作时会出现在这里</p>
        </div>

        <div v-for="approval in pendingApprovals" :key="approval.id" class="approval-card">
          <!-- 风险级别标签 -->
          <div class="card-header">
            <span class="risk-badge" :class="approval.risk">
              {{ riskLabel(approval.risk) }}
            </span>
            <span class="category">{{ categoryLabel(approval.category) }}</span>
            <span class="timestamp">{{ formatTime(approval.timestamp) }}</span>
          </div>

          <!-- 操作内容 -->
          <div class="action-content">
            <code>{{ approval.action }}</code>
          </div>

          <!-- 操作按钮 -->
          <div class="action-buttons">
            <button @click="respond(approval.id, 'approved')" class="btn-approve">
              ✓ 批准
            </button>
            <button @click="editApproval(approval)" class="btn-edit">
              ✎ 修改
            </button>
            <button @click="respond(approval.id, 'rejected')" class="btn-reject">
              ✗ 拒绝
            </button>
          </div>

          <!-- 修改模式 -->
          <div v-if="editingId === approval.id" class="edit-area">
            <textarea v-model="editedCommand" rows="2"></textarea>
            <button @click="respond(approval.id, 'modified', editedCommand)" class="btn-approve">
              批准修改后的命令
            </button>
          </div>
        </div>
      </div>
    </transition>

    <!-- 审批历史（可选） -->
    <div v-if="history.length > 0 && showHistory" class="approval-history">
      <h4>审批历史</h4>
      <div v-for="h in history" :key="h.id" class="history-item">
        <span :class="'decision ' + h.decision">{{ decisionIcon(h.decision) }}</span>
        <code>{{ truncate(h.action, 60) }}</code>
        <span class="time">{{ formatTime(h.timestamp) }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue';

const pendingApprovals = ref([]);
const history = ref([]);
const isPanelOpen = ref(false);
const showHistory = ref(false);
const editingId = ref(null);
const editedCommand = ref('');
let ws = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_DELAY = 30000; // 最大重连间隔 30 秒

// WebSocket 连接
function connect() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${location.host}/ws/approval`);

  ws.onopen = () => {
    reconnectAttempts = 0; // 连接成功后重置计数
    const authToken = document.querySelector('meta[name="hermes-approval-token"]')?.content || 'hermes-dev-secret-change-in-production';
    ws.send(JSON.stringify({ type: 'auth', token: authToken }));
  };

  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch (parseErr) {
      console.error('[Approval] 无效消息格式:', parseErr.message);
      return;
    }

    switch (msg.type) {
      case 'connected':
        console.log('[Approval]', msg.message);
        break;

      case 'approval_request':
        pendingApprovals.value.unshift(msg.approval);
        // 自动打开面板
        isPanelOpen.value = true;
        break;

      case 'approval_resolved':
        // 移动到历史
        const idx = pendingApprovals.value.findIndex(a => a.id === msg.approvalId);
        if (idx >= 0) {
          const resolved = { ...pendingApprovals.value[idx], decision: msg.decision };
          pendingApprovals.value.splice(idx, 1);
          history.value.unshift(resolved);
        }
        break;

      case 'approval_timeout':
        const timeoutIdx = pendingApprovals.value.findIndex(a => a.id === msg.approvalId);
        if (timeoutIdx >= 0) {
          pendingApprovals.value.splice(timeoutIdx, 1);
        }
        break;
    }
  };

  ws.onclose = () => {
    // 指数退避重连：1s → 2s → 4s → 8s → ... → 最大 30s
    reconnectAttempts++;
    const delay = Math.min(1000 * Math.pow(2, reconnectAttempts - 1), MAX_RECONNECT_DELAY);
    console.log(`[Approval] 连接断开，${delay / 1000}s 后重连 (第 ${reconnectAttempts} 次)`);
    setTimeout(connect, delay);
  };
}

function respond(id, decision, reason = '') {
  // 校验修改后的命令（长度限制 + 禁止空值）
  if (decision === 'modified') {
    if (!reason || typeof reason !== 'string' || reason.trim().length === 0) {
      console.error('[Approval] 修改命令不能为空');
      return;
    }
    if (reason.length > 10000) {
      console.error('[Approval] 修改命令过长');
      return;
    }
  }

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'approval_response',
      approvalId: id,
      decision,
      reason: reason || (decision === 'rejected' ? '用户手动拒绝' : '用户手动批准'),
    }));
  }
  editingId.value = null;
}

function editApproval(approval) {
  editingId.value = approval.id;
  editedCommand.value = approval.action;
}

function togglePanel() {
  isPanelOpen.value = !isPanelOpen.value;
}

function riskLabel(risk) {
  const map = { low: '低风险', medium: '中风险', high: '高风险', critical: '严重' };
  return map[risk] || risk;
}

function categoryLabel(cat) {
  const map = { file: '文件操作', network: '网络', shell: '命令', message: '消息' };
  return map[cat] || cat;
}

function decisionIcon(d) {
  const map = { approved: '✓', rejected: '✗', modified: '✎', timeout: '⏱' };
  return map[d] || '?';
}

function formatTime(ts) {
  return new Date(ts).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
}

function truncate(text, len) {
  return text && text.length > len ? text.slice(0, len) + '...' : text;
}

onMounted(() => {
  connect();
});

onUnmounted(() => {
  if (ws) ws.close();
});
</script>

<style scoped>
.approval-panel {
  position: fixed;
  bottom: 0;
  right: 0;
  z-index: 1000;
}

.approval-badge {
  background: #E74C3C;
  color: white;
  padding: 8px 12px;
  border-radius: 8px 0 0 0;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 6px;
}

.badge-count {
  background: rgba(255,255,255,0.3);
  padding: 2px 6px;
  border-radius: 10px;
  font-weight: bold;
}

.approval-drawer {
  background: white;
  border: 1px solid #e0e0e0;
  border-radius: 12px 0 0 0;
  width: 420px;
  max-height: 500px;
  overflow-y: auto;
  box-shadow: -4px -4px 20px rgba(0,0,0,0.1);
}

.drawer-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px;
  border-bottom: 1px solid #f0f0f0;
}

.drawer-header h3 {
  margin: 0;
  font-size: 16px;
}

.close-btn {
  background: none;
  border: none;
  font-size: 18px;
  cursor: pointer;
  color: #999;
}

.empty-approvals {
  padding: 32px;
  text-align: center;
  color: #999;
}

.approval-card {
  padding: 16px;
  border-bottom: 1px solid #f5f5f5;
}

.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
}

.risk-badge {
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 11px;
  font-weight: 600;
}

.risk-badge.low { background: #E8F5E9; color: #2E7D32; }
.risk-badge.medium { background: #FFF3E0; color: #E65100; }
.risk-badge.high { background: #FFEBEE; color: #C62828; }
.risk-badge.critical { background: #B71C1C; color: white; }

.action-content {
  background: #1E1E1E;
  padding: 12px;
  border-radius: 6px;
  margin-bottom: 12px;
}

.action-content code {
  color: #D4D4D4;
  font-size: 13px;
  word-break: break-all;
}

.action-buttons {
  display: flex;
  gap: 8px;
}

.action-buttons button {
  flex: 1;
  padding: 8px;
  border: none;
  border-radius: 6px;
  cursor: pointer;
  font-size: 13px;
  font-weight: 500;
}

.btn-approve { background: #27AE60; color: white; }
.btn-edit { background: #F39C12; color: white; }
.btn-reject { background: #E74C3C; color: white; }

.edit-area {
  margin-top: 8px;
}

.edit-area textarea {
  width: 100%;
  padding: 8px;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-family: monospace;
  font-size: 13px;
}

.slide-enter-active, .slide-leave-active {
  transition: transform 0.3s ease;
}
.slide-enter-from, .slide-leave-to {
  transform: translateY(100%);
}
</style>
