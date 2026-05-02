<!--
=============================================================================
Agent Chat 对话面板 — Vue 3 组件
挂载到 hermes-web-ui 前端，提供类 ChatGPT 的对话体验
=============================================================================
-->
<template>
  <div class="chat-panel">
    <!-- 消息列表 -->
    <div class="messages-container" ref="messagesContainer">
      <div v-if="messages.length === 0" class="empty-state">
        <div class="empty-icon">⚡</div>
        <h3>Hermes Agent</h3>
        <p>AI 助手已就绪，开始对话吧</p>
        <div class="quick-actions">
          <button v-for="act in quickActions" :key="act" @click="sendMessage(act)"
                  class="quick-btn">{{ act }}</button>
        </div>
      </div>

      <div v-for="(msg, idx) in messages" :key="idx"
           :class="['message', msg.role]">
        <div class="message-avatar">
          {{ msg.role === 'user' ? '👤' : '🤖' }}
        </div>
        <div class="message-content">
          <div class="message-text" v-html="renderMarkdown(msg.content)"></div>
          <div v-if="msg.toolCalls" class="tool-calls">
            <div v-for="tc in msg.toolCalls" :key="tc.id" class="tool-call">
              <span class="tool-icon">🔧</span>
              <span class="tool-name">{{ tc.name }}</span>
              <span class="tool-status" :class="tc.status">{{ tc.status }}</span>
            </div>
          </div>
          <div class="message-time">{{ formatTime(msg.timestamp) }}</div>
        </div>
      </div>

      <!-- 流式输出中 -->
      <div v-if="isStreaming" class="message assistant streaming">
        <div class="message-avatar">🤖</div>
        <div class="message-content">
          <div class="message-text">{{ streamingContent }}</div>
          <span class="cursor-blink">▊</span>
        </div>
      </div>
    </div>

    <!-- 输入区 -->
    <div class="input-area">
      <textarea
        v-model="inputMessage"
        @keydown.enter.exact.prevent="sendMessage(inputMessage)"
        @keydown.shift.enter="inputMessage += '\n'"
        placeholder="输入消息，Enter 发送，Shift+Enter 换行..."
        rows="1"
        ref="inputBox"
        :disabled="isStreaming"
      ></textarea>
      <button @click="sendMessage(inputMessage)" :disabled="!inputMessage.trim() || isStreaming"
              class="send-btn">
        <span v-if="!isStreaming">↑</span>
        <span v-else class="spinner">◌</span>
      </button>
    </div>
  </div>
</template>

<script setup>
import { ref, nextTick, onMounted, onUnmounted } from 'vue';

const messages = ref([]);
const inputMessage = ref('');
const isStreaming = ref(false);
const streamingContent = ref('');
const messagesContainer = ref(null);

const quickActions = [
  '帮我分析这个项目',
  '写一个 Python 脚本',
  '解释这段代码',
  '有什么好用的 AI 工具推荐？',
];

function formatTime(ts) {
  return new Date(ts).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
}

// 安全的 Markdown 渲染：先 HTML 转义防止 XSS，再转换 Markdown 语法
function escapeHtml(text) {
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#x27;',
  };
  return text.replace(/[&<>"']/g, ch => map[ch]);
}

function renderMarkdown(text) {
  if (!text) return '';
  // 1. 先转义所有 HTML，杜绝 XSS
  let safe = escapeHtml(text);
  // 2. 在已转义的文本上应用 Markdown 规则
  safe = safe.replace(/```(\w*)\n([\s\S]*?)```/g, '<pre><code>$2</code></pre>');
  safe = safe.replace(/`([^`]+)`/g, '<code>$1</code>');
  safe = safe.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  safe = safe.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  safe = safe.replace(/\n/g, '<br>');
  return safe;
}

async function sendMessage(text) {
  const msg = text?.trim();
  if (!msg || isStreaming.value) return;

  // 添加用户消息
  messages.value.push({
    role: 'user',
    content: msg,
    timestamp: Date.now(),
  });
  inputMessage.value = '';
  isStreaming.value = true;
  streamingContent.value = '';

  await nextTick();
  scrollToBottom();

  try {
    // 认证通过 x-api-key header，由服务端 requireAuth 中间件处理
    // 前端无需额外处理 CSRF（API Key 认证本身不受 CSRF 影响）
    const headers = { 'Content-Type': 'application/json' };
    const response = await fetch('/api/chat', {
      method: 'POST',
      headers,
      body: JSON.stringify({ message: msg }),
    });

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (line.startsWith('event: ')) continue; // 事件类型行

        if (line.startsWith('data: ')) {
          try {
            const data = JSON.parse(line.slice(6));
            if (data.type === 'token') {
              streamingContent.value += data.content;
            } else if (data.type === 'tool_call') {
              streamingContent.value += '\n\n🔧 ' + data.message;
            } else if (data.type === 'done') {
              // 流式完成
              messages.value.push({
                role: 'assistant',
                content: streamingContent.value,
                timestamp: Date.now(),
              });
              streamingContent.value = '';
            }
          } catch (e) {
            // 非 JSON 行，追加到流式内容（限制最大长度防异常数据撑爆内存）
            if (line.length <= 5000) {
              streamingContent.value += line;
            }
          }
        }
      }
    }
  } catch (err) {
    messages.value.push({
      role: 'assistant',
      content: `❌ 连接错误: ${err.message}`,
      timestamp: Date.now(),
    });
  } finally {
    isStreaming.value = false;
    await nextTick();
    scrollToBottom();
  }
}

function scrollToBottom() {
  if (messagesContainer.value) {
    messagesContainer.value.scrollTop = messagesContainer.value.scrollHeight;
  }
}

// Ctrl+L 清空对话
let ctrlLHandler = null;
onMounted(() => {
  ctrlLHandler = (e) => {
    if (e.ctrlKey && e.key === 'l') {
      e.preventDefault();
      messages.value = [];
      streamingContent.value = '';
    }
  };
  document.addEventListener('keydown', ctrlLHandler);
});
onUnmounted(() => {
  if (ctrlLHandler) {
    document.removeEventListener('keydown', ctrlLHandler);
  }
});
</script>

<style scoped>
.chat-panel {
  display: flex;
  flex-direction: column;
  height: 100vh;
  max-width: 800px;
  margin: 0 auto;
  background: #ffffff;
}

.messages-container {
  flex: 1;
  overflow-y: auto;
  padding: 24px;
}

.empty-state {
  text-align: center;
  margin-top: 120px;
}

.empty-icon {
  font-size: 56px;
  margin-bottom: 16px;
}

.empty-state h3 {
  font-size: 22px;
  margin-bottom: 8px;
  color: #1a1a2e;
}

.empty-state p {
  color: #888;
  margin-bottom: 24px;
}

.quick-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  justify-content: center;
}

.quick-btn {
  padding: 8px 16px;
  border: 1px solid #e0e0e0;
  border-radius: 20px;
  background: #fff;
  cursor: pointer;
  font-size: 13px;
  color: #555;
  transition: all 0.2s;
}

.quick-btn:hover {
  border-color: #6C63FF;
  color: #6C63FF;
}

.message {
  display: flex;
  gap: 12px;
  margin-bottom: 24px;
}

.message.assistant {
  flex-direction: row;
}

.message.user {
  flex-direction: row-reverse;
}

.message.user .message-content {
  background: #6C63FF;
  color: white;
  border-radius: 12px 12px 4px 12px;
}

.message.assistant .message-content {
  background: #f5f5f5;
  border-radius: 12px 12px 12px 4px;
}

.message-avatar {
  width: 32px;
  height: 32px;
  border-radius: 50%;
  background: #eee;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
  flex-shrink: 0;
}

.message-content {
  max-width: 70%;
  padding: 12px 16px;
  color: #333;
}

.message-text {
  font-size: 14px;
  line-height: 1.6;
}

.message-text :deep(pre) {
  background: #1e1e1e;
  color: #d4d4d4;
  padding: 12px;
  border-radius: 6px;
  overflow-x: auto;
  font-size: 13px;
  margin: 8px 0;
}

.message-text :deep(code) {
  background: rgba(0,0,0,0.08);
  padding: 2px 6px;
  border-radius: 3px;
  font-size: 13px;
}

.message-time {
  font-size: 11px;
  opacity: 0.5;
  margin-top: 4px;
}

.cursor-blink {
  animation: blink 1s step-end infinite;
  color: #6C63FF;
}

@keyframes blink {
  50% { opacity: 0; }
}

.streaming {
  opacity: 0.9;
}

.input-area {
  padding: 16px 24px;
  border-top: 1px solid #f0f0f0;
  display: flex;
  gap: 8px;
  align-items: flex-end;
}

.input-area textarea {
  flex: 1;
  padding: 12px 16px;
  border: 1px solid #e0e0e0;
  border-radius: 12px;
  font-size: 14px;
  resize: none;
  max-height: 120px;
  font-family: inherit;
  outline: none;
  transition: border-color 0.2s;
}

.input-area textarea:focus {
  border-color: #6C63FF;
}

.send-btn {
  width: 40px;
  height: 40px;
  border-radius: 50%;
  border: none;
  background: #6C63FF;
  color: white;
  cursor: pointer;
  font-size: 18px;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background 0.2s;
  flex-shrink: 0;
}

.send-btn:hover {
  background: #5A52D5;
}

.send-btn:disabled {
  background: #ccc;
  cursor: not-allowed;
}

.spinner {
  animation: spin 1s linear infinite;
}

@keyframes spin {
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
}
</style>
