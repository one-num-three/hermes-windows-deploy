/**
 * =============================================================================
 * Hermes Agent Chat API — SSE 流式对话端点
 * 挂载到 hermes-web-ui 后端，提供实时对话能力
 * =============================================================================
 */

const express = require('express');
const { spawn, execFileSync } = require('child_process');
const router = express.Router();

/**
 * POST /api/chat
 * 发送消息到 Hermes Agent，返回 SSE 流
 *
 * Body: { message: string, sessionId?: string, model?: string }
 * Response: SSE stream
 *
 * 事件类型:
 *   - token: 流式输出 token
 *   - tool_call: Agent 调用工具
 *   - tool_result: 工具执行结果
 *   - done: 对话完成
 *   - error: 错误信息
 */
router.post('/chat', requireAuth, async (req, res) => {
    const { message, sessionId, model } = req.body;

    // 输入校验：message 必须是非空字符串
    if (!message || typeof message !== 'string' || message.trim().length === 0) {
        return res.status(400).json({ error: 'message is required and must be a non-empty string' });
    }

    // 输入校验：message 长度限制，防止超大 payload
    const MAX_MESSAGE_LENGTH = 32000;
    if (message.length > MAX_MESSAGE_LENGTH) {
        return res.status(400).json({ error: `message exceeds max length of ${MAX_MESSAGE_LENGTH}` });
    }

    // 校验 model 参数格式（仅允许字母数字、点、连字符、冒号）
    if (model && !/^[a-zA-Z0-9._:\/-]+$/.test(model)) {
        return res.status(400).json({ error: 'invalid model format' });
    }

    // 设置 SSE 头
    res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
    });

    // 校验 sessionId 格式，否则生成安全的随机 ID（不可预测）
    const chatId = (sessionId && /^[a-zA-Z0-9_-]{1,64}$/.test(sessionId))
        ? sessionId
        : `chat_${require('crypto').randomUUID()}`;

    // 发送连接确认
    res.write(`event: connected\ndata: ${JSON.stringify({ chatId })}\n\n`);

    try {
        // 调用 hermes CLI（流式模式）
        // 通过 stdin 传递消息，避免命令行参数注入风险
        const args = ['chat', '--stream'];
        if (model) {
            args.push('--model', model);
        }

        const proc = spawn('hermes', args, {
            env: { ...process.env, HOME: process.env.HOME },
            stdio: ['pipe', 'pipe', 'pipe'],
        });

        // 用于防御 res.end() 被多次调用
        let responseEnded = false;

        // 安全：消息通过 stdin 传递，而非命令行参数
        proc.stdin.write(message);
        proc.stdin.end();

        // 收集输出
        let buffer = '';
        let isToolCall = false;

        proc.stdout.on('data', (data) => {
            const text = data.toString();
            buffer += text;

            // 检测工具调用
            if (text.includes('[TOOL_CALL]') && !isToolCall) {
                isToolCall = true;
                res.write(`event: tool_call\ndata: ${JSON.stringify({
                    type: 'tool_call',
                    message: 'Agent 正在调用工具...'
                })}\n\n`);
                return;
            }

            if (text.includes('[TOOL_RESULT]')) {
                isToolCall = false;
                res.write(`event: tool_result\ndata: ${JSON.stringify({
                    type: 'tool_result',
                    message: '工具执行完成'
                })}\n\n`);
                return;
            }

            // 发送 token
            if (!isToolCall) {
                res.write(`event: token\ndata: ${JSON.stringify({
                    type: 'token',
                    content: text,
                    chatId,
                })}\n\n`);
            }
        });

        proc.stderr.on('data', (data) => {
            // stderr 通常是非关键信息
            console.error(`[hermes chat stderr] ${data}`);
        });

        proc.on('close', (code) => {
            if (responseEnded) return;
            responseEnded = true;
            if (code === 0) {
                res.write(`event: done\ndata: ${JSON.stringify({
                    type: 'done',
                    chatId,
                    timestamp: Date.now(),
                })}\n\n`);
            } else {
                res.write(`event: error\ndata: ${JSON.stringify({
                    type: 'error',
                    message: `Agent 退出码: ${code}`,
                    chatId,
                })}\n\n`);
            }
            res.end();
        });

        proc.on('error', (err) => {
            if (responseEnded) return;
            responseEnded = true;
            res.write(`event: error\ndata: ${JSON.stringify({
                type: 'error',
                message: err.message,
                chatId,
            })}\n\n`);
            res.end();
        });

        // 客户端断开时终止进程
        req.on('close', () => {
            proc.kill('SIGTERM');
        });

    } catch (err) {
        res.write(`event: error\ndata: ${JSON.stringify({
            type: 'error',
            message: err.message,
            chatId,
        })}\n\n`);
        res.end();
    }
});

// 简单 API Key 认证中间件（生产环境应使用更完善的方案）
const API_KEY = process.env.HERMES_API_KEY || '';
const crypto = require('crypto');

// 常量时间字符串比较，防止时序攻击泄露密钥
function safeCompare(a, b) {
    const bufA = Buffer.from(String(a));
    const bufB = Buffer.from(String(b));
    return bufA.length === bufB.length && crypto.timingSafeEqual(bufA, bufB);
}

function requireAuth(req, res, next) {
    // 如果未配置 API_KEY 则跳过认证（开发模式）
    if (!API_KEY) {
        return next();
    }
    const providedKey = req.headers['x-api-key'] || req.query.api_key || '';
    if (!safeCompare(providedKey, API_KEY)) {
        return res.status(401).json({ error: 'unauthorized: invalid or missing API key' });
    }
    next();
}

/**
 * GET /api/chat/history
 * 获取对话历史（需要认证）
 */
router.get('/history', requireAuth, async (req, res) => {
    try {
        // 使用 execFileSync 代替 execSync，避免 shell 注入
        const output = execFileSync('hermes', ['session', 'list', '--json'], {
            encoding: 'utf-8',
            timeout: 5000,
        });
        try {
            res.json({ sessions: JSON.parse(output) });
        } catch (parseErr) {
            res.status(500).json({ error: 'Failed to parse session data' });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

/**
 * DELETE /api/chat/session/:id
 * 删除对话会话（需要认证）
 */
router.delete('/session/:id', requireAuth, async (req, res) => {
    const sessionId = req.params.id;

    // 严格校验 session ID 格式（仅允许字母数字、连字符、下划线，1-64 字符）
    if (!sessionId || !/^[a-zA-Z0-9_-]{1,64}$/.test(sessionId)) {
        return res.status(400).json({ error: 'invalid session id format' });
    }

    try {
        // 安全：使用 execFileSync + 正则校验后的 sessionId，杜绝 shell 注入
        execFileSync('hermes', ['session', 'delete', sessionId], {
            timeout: 5000,
        });
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
