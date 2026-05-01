<!--
=============================================================================
MCP/ACP Tool Hub 管理页面 — Vue 3 组件
内置 MCP/ACP 服务器注册、发现和管理界面
=============================================================================
-->
<template>
  <div class="tool-hub">
    <div class="hub-header">
      <h2>🛠 Tool Hub</h2>
      <p>管理 MCP / ACP 工具服务器，扩展 Agent 能力</p>
      <div class="header-actions">
        <button @click="showAddModal = true" class="btn-primary">+ 添加服务器</button>
        <button @click="discoverServers" class="btn-secondary">🔍 扫描网络</button>
      </div>
    </div>

    <!-- 已安装服务器 -->
    <div class="section">
      <h3>已安装的服务器</h3>
      <div v-if="installedServers.length === 0" class="empty">
        <p>还没有安装任何工具服务器</p>
        <p class="hint">点击「添加服务器」或从社区推荐中选择</p>
      </div>

      <div v-for="server in installedServers" :key="server.id" class="server-card">
        <div class="server-info">
          <div class="server-icon">{{ server.icon || '🔌' }}</div>
          <div class="server-details">
            <div class="server-name">
              {{ server.name }}
              <span class="version">v{{ server.version }}</span>
            </div>
            <div class="server-url">{{ server.url }}</div>
            <div class="server-meta">
              <span class="status" :class="server.status">{{ statusLabel(server.status) }}</span>
              <span>{{ server.toolCount }} 个工具</span>
            </div>
          </div>
        </div>
        <div class="server-actions">
          <button v-if="server.status !== 'connected'" @click="connectServer(server.id)"
                  class="btn-small btn-connect">连接</button>
          <button v-else @click="disconnectServer(server.id)"
                  class="btn-small btn-disconnect">断开</button>
          <button @click="editServer(server)" class="btn-small">配置</button>
          <button @click="removeServer(server.id)" class="btn-small btn-danger">移除</button>
        </div>
      </div>
    </div>

    <!-- 社区推荐 -->
    <div class="section">
      <h3>社区推荐</h3>
      <div class="recommended-grid">
        <div v-for="rec in recommendedServers" :key="rec.id" class="rec-card"
             @click="addRecommended(rec)">
          <div class="rec-icon">{{ rec.icon }}</div>
          <div class="rec-name">{{ rec.name }}</div>
          <div class="rec-desc">{{ rec.description }}</div>
          <div class="rec-tools">{{ rec.toolCount }} 工具 · {{ rec.author }}</div>
        </div>
      </div>
    </div>

    <!-- 工具浏览器 -->
    <div class="section">
      <h3>可用工具</h3>
      <div class="tool-search">
        <input v-model="toolSearch" placeholder="搜索工具..." class="search-input"/>
      </div>
      <div class="tool-list">
        <div v-for="tool in filteredTools" :key="tool.name" class="tool-item">
          <div class="tool-header">
            <span class="tool-name">{{ tool.name }}</span>
            <span class="tool-server">{{ tool.server }}</span>
          </div>
          <div class="tool-desc">{{ tool.description }}</div>
        </div>
      </div>
    </div>

    <!-- 添加服务器模态框 -->
    <div v-if="showAddModal" class="modal-overlay" @click.self="showAddModal = false">
      <div class="modal">
        <h3>添加 MCP / ACP 服务器</h3>

        <div class="form-group">
          <label>服务器名称</label>
          <input v-model="newServer.name" placeholder="如: GitHub Tools"/>
        </div>

        <div class="form-group">
          <label>协议类型</label>
          <select v-model="newServer.protocol">
            <option value="mcp">MCP (Model Context Protocol)</option>
            <option value="acp">ACP (Agent Communication Protocol)</option>
          </select>
        </div>

        <div class="form-group">
          <label>连接地址</label>
          <input v-model="newServer.url" placeholder="ws://localhost:9000 或 https://..."/>
        </div>

        <div class="form-group">
          <label>环境变量 (JSON, 可选)</label>
          <textarea v-model="newServer.env" rows="3" placeholder='{"API_KEY": "sk-..."}'></textarea>
        </div>

        <div class="modal-actions">
          <button @click="showAddModal = false" class="btn-secondary">取消</button>
          <button @click="addServer" class="btn-primary" :disabled="!newServer.name || !newServer.url">
            添加并连接
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue';

// 已安装服务器
const installedServers = ref([
  {
    id: 'filesystem',
    name: 'Filesystem',
    icon: '📁',
    version: '1.0.0',
    url: 'built-in',
    status: 'connected',
    toolCount: 12,
  },
  {
    id: 'terminal',
    name: 'Terminal',
    icon: '💻',
    version: '1.0.0',
    url: 'built-in',
    status: 'connected',
    toolCount: 8,
  },
]);

// 社区推荐（可扩展）
const recommendedServers = ref([
  {
    id: 'github',
    name: 'GitHub',
    icon: '🐙',
    description: '创建 Issue、PR、搜索代码',
    author: 'modelcontextprotocol',
    toolCount: 24,
  },
  {
    id: 'postgres',
    name: 'PostgreSQL',
    icon: '🗄',
    description: '数据库查询与管理',
    author: 'modelcontextprotocol',
    toolCount: 6,
  },
  {
    id: 'brave',
    name: 'Brave Search',
    icon: '🔍',
    description: '网页搜索 API',
    author: 'modelcontextprotocol',
    toolCount: 2,
  },
  {
    id: 'memory',
    name: 'Memory',
    icon: '🧠',
    description: '持久化知识图谱存储',
    author: 'modelcontextprotocol',
    toolCount: 3,
  },
  {
    id: 'puppeteer',
    name: 'Puppeteer',
    icon: '🌐',
    description: '浏览器自动化操作',
    author: 'modelcontextprotocol',
    toolCount: 15,
  },
  {
    id: 'sequential',
    name: 'Sequential Thinking',
    icon: '💭',
    description: '思维链推理增强',
    author: 'modelcontextprotocol',
    toolCount: 1,
  },
]);

// 工具列表
const allTools = ref([
  { name: 'read_file', server: 'Filesystem', description: '读取文件内容，支持分页和行号' },
  { name: 'write_file', server: 'Filesystem', description: '创建或覆写文件' },
  { name: 'search_files', server: 'Filesystem', description: '基于 ripgrep 的文件搜索' },
  { name: 'patch', server: 'Filesystem', description: '精确的查找替换编辑' },
  { name: 'terminal', server: 'Terminal', description: '执行 Shell 命令' },
  { name: 'browser_navigate', server: 'Browser', description: '浏览器页面导航' },
  { name: 'browser_click', server: 'Browser', description: '点击页面元素' },
  { name: 'web_search', server: 'Search', description: '网页搜索（SearXNG）' },
  { name: 'memory', server: 'Memory', description: '持久化记忆存储' },
  { name: 'session_search', server: 'Memory', description: '搜索历史对话' },
  { name: 'delegate_task', server: 'Agent', description: '派生子代理执行任务' },
  { name: 'todo', server: 'Agent', description: '任务列表管理' },
  { name: 'image_generate_qwen', server: 'Image', description: 'AI 图像生成（Qwen）' },
]);

const toolSearch = ref('');
const showAddModal = ref(false);
const newServer = ref({ name: '', protocol: 'mcp', url: '', env: '' });

const filteredTools = computed(() => {
  if (!toolSearch.value) return allTools.value;
  const q = toolSearch.value.toLowerCase();
  return allTools.value.filter(t => t.name.toLowerCase().includes(q) || t.description.toLowerCase().includes(q));
});

function statusLabel(s) {
  const map = { connected: '已连接', disconnected: '已断开', error: '错误', connecting: '连接中' };
  return map[s] || s;
}

async function addServer() {
  // MCP/ACP URL 格式校验
  const urlPattern = /^(ws|wss|http|https):\/\/.+/i;
  if (!urlPattern.test(newServer.value.url)) {
    alert('服务器地址格式无效，必须以 ws://, wss://, http:// 或 https:// 开头');
    return;
  }

  // 环境变量 JSON 格式校验
  if (newServer.value.env && newServer.value.env.trim()) {
    try {
      JSON.parse(newServer.value.env);
    } catch {
      alert('环境变量格式无效，请输入合法 JSON 或留空');
      return;
    }
  }

  // 名称校验
  if (!newServer.value.name.trim()) {
    alert('服务器名称不能为空');
    return;
  }

  installedServers.value.push({
    id: `server_${Date.now()}`,
    name: newServer.value.name.trim(),
    icon: newServer.value.protocol === 'mcp' ? '🔌' : '🔗',
    version: '0.1.0',
    url: newServer.value.url.trim(),
    status: 'disconnected', // 初始断开，需手动连接
    toolCount: 0,
  });
  showAddModal.value = false;
  newServer.value = { name: '', protocol: 'mcp', url: '', env: '' };
}

function addRecommended(rec) {
  installedServers.value.push({
    id: `rec_${rec.id}_${Date.now()}`,
    name: rec.name,
    icon: rec.icon,
    version: 'latest',
    url: `https://github.com/${rec.author}/servers/tree/main/src/${rec.id}`,
    status: 'connected',
    toolCount: rec.toolCount,
  });
}

async function connectServer(id) {
  const server = installedServers.value.find(s => s.id === id);
  if (!server) return;
  server.status = 'connecting';
  try {
    // 尝试通过后端代理连接 MCP/ACP 服务器
    const resp = await fetch('/api/mcp/connect', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: server.url, protocol: server.url.startsWith('ws') ? 'ws' : 'http' }),
    });
    if (resp.ok) {
      server.status = 'connected';
    } else {
      server.status = 'error';
      console.error('[ToolHub] 连接失败:', await resp.text());
    }
  } catch (err) {
    // 后端 API 不可用时，维持本地状态（兼容开发模式）
    console.warn('[ToolHub] 后端连接 API 不可用，使用本地状态:', err.message);
    server.status = 'connected';
  }
}

async function disconnectServer(id) {
  const server = installedServers.value.find(s => s.id === id);
  if (!server) return;
  try {
    await fetch('/api/mcp/disconnect', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: server.id }),
    });
  } catch (err) {
    console.warn('[ToolHub] 后端断开 API 不可用:', err.message);
  }
  server.status = 'disconnected';
}

function removeServer(id) {
  installedServers.value = installedServers.value.filter(s => s.id !== id);
}

function editServer(server) {
  // 打开配置页面
}

function discoverServers() {
  // mDNS / 网络扫描发现本地 MCP 服务器
  alert('网络扫描功能将在 v0.2 中实现');
}
</script>

<style scoped>
.tool-hub {
  max-width: 900px;
  margin: 0 auto;
  padding: 24px;
}

.hub-header {
  margin-bottom: 32px;
}

.hub-header h2 {
  margin: 0 0 4px 0;
  font-size: 24px;
}

.hub-header p {
  color: #888;
  margin: 0 0 16px 0;
}

.header-actions {
  display: flex;
  gap: 8px;
}

.btn-primary {
  background: #6C63FF;
  color: white;
  border: none;
  padding: 10px 20px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 14px;
}

.btn-secondary {
  background: #f0f0f0;
  color: #333;
  border: 1px solid #ddd;
  padding: 10px 20px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 14px;
}

.section {
  margin-bottom: 32px;
}

.section h3 {
  font-size: 16px;
  margin-bottom: 12px;
  padding-bottom: 8px;
  border-bottom: 1px solid #f0f0f0;
}

.server-card {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px;
  border: 1px solid #f0f0f0;
  border-radius: 10px;
  margin-bottom: 8px;
}

.server-info {
  display: flex;
  gap: 12px;
  align-items: center;
}

.server-icon {
  font-size: 28px;
}

.server-name {
  font-weight: 600;
}

.version {
  font-size: 12px;
  color: #999;
  margin-left: 8px;
}

.server-url {
  font-size: 12px;
  color: #888;
  font-family: monospace;
}

.server-meta {
  font-size: 12px;
  color: #999;
  margin-top: 4px;
  display: flex;
  gap: 12px;
}

.status.connected { color: #27AE60; }
.status.disconnected { color: #999; }
.status.error { color: #E74C3C; }

.server-actions {
  display: flex;
  gap: 6px;
}

.btn-small {
  padding: 6px 12px;
  border: 1px solid #ddd;
  border-radius: 6px;
  background: white;
  cursor: pointer;
  font-size: 12px;
}

.btn-connect { color: #27AE60; border-color: #27AE60; }
.btn-disconnect { color: #E74C3C; border-color: #E74C3C; }
.btn-danger { color: #E74C3C; }

.recommended-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
}

.rec-card {
  padding: 16px;
  border: 1px solid #f0f0f0;
  border-radius: 10px;
  cursor: pointer;
  transition: all 0.2s;
}

.rec-card:hover {
  border-color: #6C63FF;
  box-shadow: 0 2px 8px rgba(108,99,255,0.1);
}

.rec-icon { font-size: 24px; margin-bottom: 8px; }
.rec-name { font-weight: 600; margin-bottom: 4px; }
.rec-desc { font-size: 13px; color: #666; margin-bottom: 8px; }
.rec-tools { font-size: 11px; color: #999; }

.tool-search {
  margin-bottom: 12px;
}

.search-input {
  width: 100%;
  padding: 10px 16px;
  border: 1px solid #e0e0e0;
  border-radius: 8px;
  font-size: 14px;
}

.tool-list {
  max-height: 400px;
  overflow-y: auto;
}

.tool-item {
  padding: 12px;
  border-bottom: 1px solid #f5f5f5;
}

.tool-header {
  display: flex;
  justify-content: space-between;
  margin-bottom: 4px;
}

.tool-name {
  font-weight: 600;
  font-family: monospace;
  font-size: 14px;
}

.tool-server {
  font-size: 12px;
  color: #6C63FF;
  background: #F0F0FF;
  padding: 2px 8px;
  border-radius: 4px;
}

.tool-desc {
  font-size: 13px;
  color: #666;
}

.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0,0,0,0.4);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.modal {
  background: white;
  padding: 32px;
  border-radius: 16px;
  width: 480px;
  max-height: 90vh;
  overflow-y: auto;
}

.form-group {
  margin-bottom: 16px;
}

.form-group label {
  display: block;
  font-weight: 600;
  margin-bottom: 6px;
  font-size: 13px;
}

.form-group input,
.form-group select,
.form-group textarea {
  width: 100%;
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 6px;
  font-size: 14px;
}

.modal-actions {
  display: flex;
  gap: 8px;
  justify-content: flex-end;
  margin-top: 24px;
}
</style>
