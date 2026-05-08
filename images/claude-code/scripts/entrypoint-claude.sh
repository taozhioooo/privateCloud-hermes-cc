#!/bin/bash
# =============================================================================
# Claude Code Container — Entrypoint
# 启动时打印完整使用信息
# =============================================================================

set -e

CLAUDE_HOME="/home/claude"

EMPLOYEE_NAME="${EMPLOYEE_NAME:-unknown}"
EMPLOYEE_SEQ="${EMPLOYEE_SEQ:-??}"
SSH_PORT="${SSH_PORT:-22}"
WEB_PORT_START="${WEB_PORT_START:-11002}"
WEB_PORT_END="${WEB_PORT_END:-11099}"
CLAUDE_SSH_PASS="${CLAUDE_SSH_PASS:-claude}"
HERMES_HOST="${HERMES_HOST:-not configured}"

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")

# ══════════════════════════════════════════════════════════════════
# 1. SSH 配置
# ══════════════════════════════════════════════════════════════════

echo "claude:${CLAUDE_SSH_PASS}" | sudo chpasswd

# 导入用户公钥
if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "$SSH_PUBLIC_KEY" >> "${CLAUDE_HOME}/.ssh/authorized_keys"
fi

# 导入 Hermes 容器的公钥（自动免密）
HERMES_PUB="/hermes-ssh-pub/hermes.pub"
if [ -f "$HERMES_PUB" ]; then
    if ! grep -qF "$(cat "$HERMES_PUB")" "${CLAUDE_HOME}/.ssh/authorized_keys" 2>/dev/null; then
        cat "$HERMES_PUB" >> "${CLAUDE_HOME}/.ssh/authorized_keys"
    fi
fi

[ -f "${CLAUDE_HOME}/.ssh/authorized_keys" ] && chmod 600 "${CLAUDE_HOME}/.ssh/authorized_keys"

# ══════════════════════════════════════════════════════════════════
# 2. API Key
# ══════════════════════════════════════════════════════════════════

if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "export ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${CLAUDE_HOME}/.bashrc"
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
fi

# ══════════════════════════════════════════════════════════════════
# 3. Claude Code 配置
# ══════════════════════════════════════════════════════════════════

mkdir -p "${CLAUDE_HOME}/.claude"

if [ ! -f "${CLAUDE_HOME}/.claude/settings.json" ]; then
    cat > "${CLAUDE_HOME}/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read","Edit","Write","Bash","WebSearch","WebFetch"],
    "deny": ["Bash(rm -rf /)","Bash(:(){ :|:& };:)"]
  }
}
EOF
fi

mkdir -p "${CLAUDE_HOME}/workspace"

# ══════════════════════════════════════════════════════════════════
# 4. 启动 SSH + 打印信息
# ══════════════════════════════════════════════════════════════════

CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")

cat << BANNER

╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║             Claude Code — 启动成功                               ║
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  员工:  ${EMPLOYEE_NAME} (序号: ${EMPLOYEE_SEQ})
║  版本:  Claude Code ${CLAUDE_VERSION}  |  Node.js ${NODE_VERSION}
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  ┌─ SSH 接入 ──────────────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  ssh claude@${HOST_IP} -p ${SSH_PORT}
║  │  密码: ${CLAUDE_SSH_PASS}
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ Web 服务端口 ──────────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  可用端口: ${WEB_PORT_START} - ${WEB_PORT_END} (共 98 个)
║  │                                                              │ ║
║  │  使用方法 (容器内绑定 0.0.0.0):                              │ ║
║  │    python3 -m http.server ${WEB_PORT_START} --bind 0.0.0.0
║  │    npx serve -l ${WEB_PORT_START}
║  │    npm run dev -- -p ${WEB_PORT_START}
║  │                                                              │ ║
║  │  局域网访问: http://${HOST_IP}:${WEB_PORT_START}
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ Claude Code 使用 ──────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  claude                         交互式 REPL                  │ ║
║  │  claude -p "任务描述"           非交互模式 (print mode)      │ ║
║  │  claude auth status             认证状态                     │ ║
║  │  claude --version               版本号                       │ ║
║  │                                                              │ ║
║  │  编码示例:                                                    │ ║
║  │  claude -p "写一个 FastAPI 项目"                             │ ║
║  │  claude -p "分析 src/ 下的代码并生成文档"                    │ ║
║  │  claude -p "修复所有 lint 错误" --max-turns 10              │ ║
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ 从 Hermes 容器调用 ────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  Hermes 容器已配置免密 SSH 到本容器                          │ ║
║  │  Hermes 内部调用:                                            │ ║
║  │    ssh claude@${HERMES_HOST} "claude -p '任务'"              │ ║
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

BANNER

# 启动 SSH Server
exec sudo /usr/sbin/sshd -D
