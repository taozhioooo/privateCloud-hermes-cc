#!/bin/bash
# =============================================================================
# Claude Code Container — Entrypoint
# 支持通过 DEEPSEEK_MODEL 环境变量配置模型
# 支持 SSH 接入 和 docker exec 两种调用方式
# =============================================================================

set -e

CLAUDE_HOME="/home/claude"

EMPLOYEE_NAME="${EMPLOYEE_NAME:-unknown}"
EMPLOYEE_SEQ="${EMPLOYEE_SEQ:-??}"
# Host-facing SSH port published by Docker Compose (for banner/docs only).
# Inside the container sshd must listen on 22 because compose maps host {{c_ssh_port}} -> container 22.
SSH_PORT="${SSH_PORT:-22}"
SSHD_LISTEN_PORT="${SSHD_LISTEN_PORT:-22}"
WEB_PORT_START="${WEB_PORT_START:-11002}"
WEB_PORT_END="${WEB_PORT_END:-11099}"
CLAUDE_SSH_PASS="${CLAUDE_SSH_PASS:-claude}"
HERMES_HOST="${HERMES_HOST:-not configured}"

# 模型配置：优先 DEEPSEEK_MODEL，其次 CLAUDE_MODEL，默认 deepseek-v4-pro
CLAUDE_MODEL="${DEEPSEEK_MODEL:-${CLAUDE_MODEL:-deepseek-v4-pro}}"

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")

# ══════════════════════════════════════════════════════════════════
# 1. SSH 配置
# ══════════════════════════════════════════════════════════════════

echo "claude:${CLAUDE_SSH_PASS}" | chpasswd
mkdir -p "${CLAUDE_HOME}/.ssh"
touch "${CLAUDE_HOME}/.ssh/authorized_keys"
chown -R claude:claude "${CLAUDE_HOME}/.ssh"
chmod 700 "${CLAUDE_HOME}/.ssh"
chmod 600 "${CLAUDE_HOME}/.ssh/authorized_keys"

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
# 2. API Key / Claude Code environment 配置
# ══════════════════════════════════════════════════════════════════

# Claude Code does not reliably export settings.json.env into every SSH/login shell.
# Persist those env vars in a separate shell snippet so both interactive `claude`
# and `claude -p` can use the company Anthropic-compatible endpoint without OAuth login.
CLAUDE_ENV_FILE="${CLAUDE_HOME}/.claude/claude-code-env.sh"
write_claude_env_file() {
    if [ -f "${CLAUDE_SETTINGS_DST}" ]; then
        SETTINGS_PATH="${CLAUDE_SETTINGS_DST}" ENV_OUT="${CLAUDE_ENV_FILE}" python3 - <<'PY'
import json, os, shlex
from pathlib import Path
settings = Path(os.environ['SETTINGS_PATH'])
out = Path(os.environ['ENV_OUT'])
try:
    env = json.loads(settings.read_text(encoding='utf-8')).get('env') or {}
except Exception:
    env = {}
lines = [
    '# Auto-generated from ~/.claude/settings.json env on container start.',
    '# Edit ~/.claude/settings.json, then restart the container to regenerate this file.',
]
for key, value in env.items():
    if not isinstance(key, str) or not key.replace('_', '').isalnum() or key[0].isdigit():
        continue
    if value is None:
        continue
    lines.append(f'export {key}={shlex.quote(str(value))}')
out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
        chown claude:claude "${CLAUDE_ENV_FILE}"
        chmod 600 "${CLAUDE_ENV_FILE}"
    fi
}

ensure_bashrc_source() {
    local line="[ -f \"${CLAUDE_ENV_FILE}\" ] && . \"${CLAUDE_ENV_FILE}\""
    grep -qF "${CLAUDE_ENV_FILE}" "${CLAUDE_HOME}/.bashrc" 2>/dev/null || echo "${line}" >> "${CLAUDE_HOME}/.bashrc"
}

# ══════════════════════════════════════════════════════════════════
# 3. Claude Code settings.json — 写入模型配置
# ══════════════════════════════════════════════════════════════════

mkdir -p "${CLAUDE_HOME}/.claude"
CLAUDE_SETTINGS_SRC="/etc/claude/settings.json"
CLAUDE_SETTINGS_DST="${CLAUDE_HOME}/.claude/settings.json"
CLAUDE_ENV_FILE="${CLAUDE_HOME}/.claude/claude-code-env.sh"

# 首次启动才初始化 settings.json；后续保留用户自定义，不再覆盖 model/permissions/env 等字段。
if [ -f "${CLAUDE_SETTINGS_DST}" ]; then
    echo "[settings] using existing user-customized settings.json"
elif [ -f "${CLAUDE_SETTINGS_SRC}" ]; then
    cp "${CLAUDE_SETTINGS_SRC}" "${CLAUDE_SETTINGS_DST}"
    echo "[settings] initialized from ${CLAUDE_SETTINGS_SRC}"
else
    cat > "${CLAUDE_SETTINGS_DST}" << EOF
{
  "model": "${CLAUDE_MODEL}",
  "permissions": {
    "allow": ["Read", "Edit", "Write", "Bash", "WebSearch", "WebFetch"],
    "deny": ["Bash(rm -rf /)", "Bash(:(){ :|:& };:)"]
  }
}
EOF
    echo "[settings] created fallback settings.json: model=${CLAUDE_MODEL}"
fi

chown -R claude:claude "${CLAUDE_HOME}/.claude"
write_claude_env_file
ensure_bashrc_source
chown claude:claude "${CLAUDE_HOME}/.bashrc"

# workspace 目录权限修正（共享卷首次挂载可能是 root 所有）
mkdir -p "${CLAUDE_HOME}/workspace"
chown claude:claude "${CLAUDE_HOME}/workspace"

# ══════════════════════════════════════════════════════════════════
# 4. 打印启动信息
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
║  模型:  ${CLAUDE_MODEL}
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
║  ┌─ docker exec 调用 ──────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  docker exec -u claude claude-${EMPLOYEE_NAME} \
║  │    claude -p "任务描述"
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ Web 服务端口 ──────────────────────────────────────────────┐ ║
║  │  可用端口: ${WEB_PORT_START} - ${WEB_PORT_END}
║  │  局域网访问: http://${HOST_IP}:${WEB_PORT_START}
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ 从 Hermes 容器调用 ────────────────────────────────────────┐ ║
║  │  ssh claude@${HERMES_HOST} "claude -p '任务'"
║  │  docker exec -u claude claude-${EMPLOYEE_NAME} claude -p "任务"
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

BANNER

# ══════════════════════════════════════════════════════════════════
# 5. 启动 SSH Server
# ══════════════════════════════════════════════════════════════════

# Listen on container port 22; Docker Compose publishes the per-employee host port.
exec /usr/sbin/sshd -D -o "Port ${SSHD_LISTEN_PORT:-22}"
