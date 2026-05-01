/**
 * =============================================================================
 * HITL 审批 WebSocket 服务
 * 当 Agent 需要执行敏感操作时，通过 WebSocket 推送审批请求到前端
 * =============================================================================
 */

const WebSocket = require('ws');

// 从环境变量读取共享密钥，未配置则拒绝启动（生产安全要求）
const SHARED_SECRET = process.env.HERMES_APPROVAL_SECRET;
if (!SHARED_SECRET) {
    console.error('[Approval] FATAL: HERMES_APPROVAL_SECRET environment variable is required.');
    console.error('[Approval] Please set it before starting the server, e.g.:');
    console.error('[Approval]   export HERMES_APPROVAL_SECRET="$(openssl rand -hex 32)"');
    process.exit(1);
}
const AUTH_TIMEOUT_MS = 10000; // 客户端需在 10 秒内完成认证

class ApprovalManager {
    constructor(server) {
        this.wss = new WebSocket.Server({ server, path: '/ws/approval' });
        this.pendingApprovals = new Map();
        this.clients = new Set();

        this.wss.on('connection', (ws) => {
            let authenticated = false;
            let authTimer = null;

            console.log('[Approval] 新客户端连接，等待认证...');

            // 认证超时：10 秒内未认证则断开
            authTimer = setTimeout(() => {
                if (!authenticated) {
                    console.log('[Approval] 客户端认证超时，断开连接');
                    ws.close(4001, '认证超时');
                }
            }, AUTH_TIMEOUT_MS);

            ws.on('message', (data) => {
                try {
                    const msg = JSON.parse(data.toString());

                    // 首条消息必须是认证
                    if (!authenticated) {
                        if (msg.type === 'auth' && msg.token === SHARED_SECRET) {
                            authenticated = true;
                            clearTimeout(authTimer);
                            this.clients.add(ws);
                            console.log('[Approval] 客户端认证成功');

                            // 发送连接确认
                            ws.send(JSON.stringify({
                                type: 'connected',
                                message: '审批服务已连接',
                            }));
                        } else {
                            console.log('[Approval] 客户端认证失败');
                            ws.close(4003, '认证失败');
                        }
                        return;
                    }

                    // 已认证：处理业务消息
                    this.handleClientMessage(ws, msg);
                } catch (e) {
                    console.error('[Approval] 无效消息:', e.message);
                }
            });

            ws.on('close', () => {
                clearTimeout(authTimer);
                if (authenticated) {
                    this.clients.delete(ws);
                }
                console.log('[Approval] 客户端已断开');
            });
        });

        console.log('[Approval] WebSocket 审批服务已启动');
        if (!process.env.HERMES_APPROVAL_SECRET) {
            console.warn('[Approval] ⚠ 使用默认密钥，生产环境请设置 HERMES_APPROVAL_SECRET 环境变量');
        }
    }

    /**
     * 创建审批请求
     * @param {Object} request
     * @param {string} request.id - 唯一请求 ID
     * @param {string} request.action - 敏感操作描述
     * @param {string} request.category - 操作类别: file/network/shell/message
     * @param {string} request.risk - 风险级别: low/medium/high/critical
     * @returns {Promise} - 用户决策后 resolve
     */
    createApproval(request) {
        // 输入校验
        if (!request || typeof request !== 'object') {
            return Promise.reject(new Error('审批请求不能为空'));
        }
        if (!request.action || typeof request.action !== 'string' || request.action.trim().length === 0) {
            return Promise.reject(new Error('审批操作描述 (action) 不能为空'));
        }
        if (request.action.length > 2000) {
            return Promise.reject(new Error('审批操作描述过长 (最大 2000 字符)'));
        }

        // 校验 category
        const VALID_CATEGORIES = ['file', 'network', 'shell', 'message', 'unknown'];
        const category = VALID_CATEGORIES.includes(request.category) ? request.category : 'unknown';

        // 校验 risk
        const VALID_RISKS = ['low', 'medium', 'high', 'critical'];
        const risk = VALID_RISKS.includes(request.risk) ? request.risk : 'medium';

        // 校验 timeout
        const timeout = (typeof request.timeout === 'number' && request.timeout >= 5000 && request.timeout <= 300000)
            ? request.timeout
            : 60000;

        // 最大并发审批数限制（防止内存耗尽）
        const MAX_PENDING_APPROVALS = 100;
        if (this.pendingApprovals.size >= MAX_PENDING_APPROVALS) {
            return Promise.reject(new Error(`审批队列已满 (最大 ${MAX_PENDING_APPROVALS} 条)`));
        }

        return new Promise((resolve, reject) => {
            const approval = {
                id: request.id || `approval_${Date.now()}`,
                action: request.action.trim(),
                category,
                risk,
                timestamp: Date.now(),
                timeout,
                status: 'pending',
                resolve,
                reject,
            };

            this.pendingApprovals.set(approval.id, approval);

            // 广播审批请求到所有已认证客户端
            this.broadcast({
                type: 'approval_request',
                approval: {
                    id: approval.id,
                    action: approval.action,
                    category: approval.category,
                    risk: approval.risk,
                    timestamp: approval.timestamp,
                },
            });

            console.log(`[Approval] 新建审批: ${approval.id} - ${approval.action}`);

            // 超时自动拒绝
            const timeoutHandle = setTimeout(() => {
                if (this.pendingApprovals.has(approval.id)) {
                    const pending = this.pendingApprovals.get(approval.id);
                    if (pending.status === 'pending') {
                        pending.status = 'timeout';
                        this.pendingApprovals.delete(approval.id);
                        this.broadcast({
                            type: 'approval_timeout',
                            approvalId: approval.id,
                        });
                        reject(new Error('审批请求超时'));
                    }
                }
            }, approval.timeout);

            // 清理定时器当审批被处理时
            const origResolve = approval.resolve;
            const origReject = approval.reject;
            approval.resolve = (val) => { clearTimeout(timeoutHandle); origResolve(val); };
            approval.reject = (err) => { clearTimeout(timeoutHandle); origReject(err); };
        });
    }

    /**
     * 处理客户端审批响应（仅在认证后调用）
     */
    handleClientMessage(ws, msg) {
        const { type, approvalId, decision, reason } = msg;

        if (type === 'approval_response') {
            const approval = this.pendingApprovals.get(approvalId);
            if (!approval) {
                ws.send(JSON.stringify({
                    type: 'error',
                    message: '审批请求不存在或已过期',
                }));
                return;
            }

            approval.status = decision;

            if (decision === 'approved') {
                approval.resolve({ approved: true, reason });
                this.broadcast({
                    type: 'approval_resolved',
                    approvalId,
                    decision: 'approved',
                    reason,
                });
            } else if (decision === 'rejected') {
                approval.reject(new Error(reason || '用户拒绝'));
                this.broadcast({
                    type: 'approval_resolved',
                    approvalId,
                    decision: 'rejected',
                    reason,
                });
            } else if (decision === 'modified') {
                // 用户修改了命令后批准
                approval.resolve({
                    approved: true,
                    modified: true,
                    modifiedAction: reason,
                });
                this.broadcast({
                    type: 'approval_resolved',
                    approvalId,
                    decision: 'modified',
                    reason,
                });
            } else {
                ws.send(JSON.stringify({
                    type: 'error',
                    message: `未知的决策类型: ${decision}`,
                }));
                return;
            }

            this.pendingApprovals.delete(approvalId);
            console.log(`[Approval] ${approvalId}: ${decision}`);
        }
    }

    /**
     * 广播消息到所有已认证客户端
     */
    broadcast(msg) {
        const data = JSON.stringify(msg);
        this.clients.forEach((client) => {
            if (client.readyState === WebSocket.OPEN) {
                client.send(data);
            }
        });
    }

    /**
     * 获取待审批列表
     */
    getPendingApprovals() {
        const list = [];
        this.pendingApprovals.forEach((approval) => {
            list.push({
                id: approval.id,
                action: approval.action,
                category: approval.category,
                risk: approval.risk,
                timestamp: approval.timestamp,
                status: approval.status,
            });
        });
        return list;
    }
}

module.exports = ApprovalManager;
