#!/usr/bin/env bash
# =============================================================================
# Hermes Enterprise — 容器入口
#
# 职责:
#   1. 校准 /opt/data、/workspace 卷的所有权(挂载后常被覆盖)
#   2. 从 SSH_PUBLIC_KEY 环境变量注入员工公钥
#   3. 首次启动:按 HERMES_DEFAULT_PROVIDER / 各 *_API_KEY 生成 config.yaml + .env
#               写入后落 /opt/data/.provisioned 作 sentinel,后续不再覆盖
#   4. 合并 L1/L2/L3/L4 四层 SOUL.md
#   5. root 启动 sshd,gosu 切 hermes 启 hermes-web-ui
# =============================================================================
set -euo pipefail

# ───── 路径 ─────
HERMES_HOME="/opt/data"                          # == ~/.hermes, 挂载卷
WORKSPACE="/workspace"                           # 工作目录, 挂载卷
WEBUI_DIR="/opt/hermes-web-ui"
AGENT_DIR="/opt/hermes"
VENV_BIN="${AGENT_DIR}/.venv/bin"
SENTINEL="${HERMES_HOME}/.provisioned"

export HERMES_HOME

# ───── 员工上下文(compose 注入) ─────
EMPLOYEE_NAME="${EMPLOYEE_NAME:-unknown}"
EMPLOYEE_SEQ="${EMPLOYEE_SEQ:-0}"
DOMAIN="${DOMAIN:-default}"
ROLE="${ROLE:-default}"

# ───── 默认模型渠道 ─────
HERMES_DEFAULT_PROVIDER="${HERMES_DEFAULT_PROVIDER:-deepseek}"
HERMES_DEFAULT_MODEL="${HERMES_DEFAULT_MODEL:-deepseek-v4-pro}"

# ───── Web UI / gateway 端口(容器内固定) ─────
SSH_PORT=8700
WEBUI_PORT=8701

log() { printf '\033[0;36m[entrypoint]\033[0m %s\n' "$*"; }

# ══════════════════════════════════════════════════════════════════
# 1. 挂载卷所有权修正
# ══════════════════════════════════════════════════════════════════
# Volume 首次挂载会把目录 uid 改成 docker 默认(通常 root), hermes 访问不到
mkdir -p \
    "${HERMES_HOME}/skills" \
    "${HERMES_HOME}/sessions" \
    "${HERMES_HOME}/logs" \
    "${HERMES_HOME}/.ssh" \
    "${HERMES_HOME}/.hermes-web-ui" \
    "${WORKSPACE}/projects" \
    "${WORKSPACE}/outputs" \
    "${WORKSPACE}/downloads"

chmod 700 "${HERMES_HOME}/.ssh"
chown -R hermes:hermes "${HERMES_HOME}" "${WORKSPACE}" || true

# ══════════════════════════════════════════════════════════════════
# 2. SSH 公钥注入
# ══════════════════════════════════════════════════════════════════
AUTH_KEYS="${HERMES_HOME}/.ssh/authorized_keys"
: > "${AUTH_KEYS}.tmp"

# 环境变量(单把或多把用 \n 分隔)
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    printf '%s\n' "${SSH_PUBLIC_KEY}" >> "${AUTH_KEYS}.tmp"
fi
# docker secrets 支持(compose secrets: 或 -v /path:/run/secrets/ssh_pubkey_xxx)
if [[ -d /run/secrets ]]; then
    for f in /run/secrets/ssh_pubkey_*; do
        [[ -f "$f" ]] && cat "$f" >> "${AUTH_KEYS}.tmp"
    done
fi
# 去空行 + 去重
grep -E '^(ssh-|ecdsa-|sk-|ssh-ed25519)' "${AUTH_KEYS}.tmp" 2>/dev/null | sort -u > "${AUTH_KEYS}" || : > "${AUTH_KEYS}"
rm -f "${AUTH_KEYS}.tmp"
chmod 600 "${AUTH_KEYS}"
chown hermes:hermes "${AUTH_KEYS}"

if [[ ! -s "${AUTH_KEYS}" ]]; then
    log "WARN: authorized_keys 为空,SSH 无法登录。请通过 SSH_PUBLIC_KEY 注入公钥。"
fi

# ssh 需要 /home/hermes/.ssh 指向 /opt/data/.ssh (挂载卷),这样换容器公钥保留
mkdir -p /home/hermes
if [[ ! -L /home/hermes/.ssh ]]; then
    rm -rf /home/hermes/.ssh
    ln -s "${HERMES_HOME}/.ssh" /home/hermes/.ssh
fi
chown -h hermes:hermes /home/hermes/.ssh

# 生成 Hermes → 外部 SSH 客户端密钥(首次)
if [[ ! -f "${HERMES_HOME}/.ssh/id_ed25519" ]]; then
    su - hermes -c "ssh-keygen -t ed25519 -f ${HERMES_HOME}/.ssh/id_ed25519 -N '' -q"
fi

# ══════════════════════════════════════════════════════════════════
# 3. Provider / config.yaml / .env 首次注入
# ══════════════════════════════════════════════════════════════════
# 设计:
#   - 首次启动: 依据 HERMES_DEFAULT_PROVIDER + 对应 API key 生成配置
#   - 生成后写 sentinel, 后续用户自改 config.yaml / .env 不被覆盖
#   - 如果检测不到 API key, 仍写占位文件, 用户可后续自己改

ENV_FILE="${HERMES_HOME}/.env"
CFG_FILE="${HERMES_HOME}/config.yaml"

if [[ ! -f "${SENTINEL}" ]]; then
    log "首次启动,注入 provider 配置 (${HERMES_DEFAULT_PROVIDER}/${HERMES_DEFAULT_MODEL})"

    # .env —— 仅注入存在的 key,空值跳过
    {
        for var in \
            OPENROUTER_API_KEY \
            OPENAI_API_KEY \
            ANTHROPIC_API_KEY \
            DEEPSEEK_API_KEY \
            GEMINI_API_KEY \
            BRAVE_API_KEY \
            GOOGLE_API_KEY \
            GITHUB_TOKEN \
            DINGTALK_CLIENT_ID \
            DINGTALK_CLIENT_SECRET \
            DINGTALK_ALLOWED_USERS ; do
            val="${!var:-}"
            [[ -n "$val" ]] && printf '%s=%s\n' "$var" "$val"
        done
    } > "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"

    # config.yaml —— 写入默认模型 + 外部技能目录 (guide-v2 4.4)
    cat > "${CFG_FILE}" <<YAML
# 由 hermes-entrypoint.sh 首次生成。用户可自行编辑,容器重启不覆盖。
provider: ${HERMES_DEFAULT_PROVIDER}
model: ${HERMES_DEFAULT_MODEL}

providers:
  deepseek:
    base_url: https://api.deepseek.com
  openrouter:
    base_url: https://openrouter.ai/api/v1
  openai:
    base_url: https://api.openai.com/v1
  anthropic:
    base_url: https://api.anthropic.com
  gemini:
    base_url: https://generativelanguage.googleapis.com

skills:
  external_dirs:
    - /opt/skills/L1   # 公司层, 只读
    - /opt/skills/L2   # 域层, 只读
    - /opt/skills/L3   # 角色层, 只读

platforms:
  dingtalk:
    enabled: false

employee:
  name: ${EMPLOYEE_NAME}
  seq: ${EMPLOYEE_SEQ}
  domain: ${DOMAIN}
  role: ${ROLE}
YAML

    chown hermes:hermes "${ENV_FILE}" "${CFG_FILE}"
    touch "${SENTINEL}"
    chown hermes:hermes "${SENTINEL}"
    log "provider 配置已写入 ${CFG_FILE} / ${ENV_FILE}"
else
    log "检测到 ${SENTINEL}, 跳过 provider 首次注入 (用户接管)"
fi

# ══════════════════════════════════════════════════════════════════
# 4. 四层 SOUL.md 合并
# ══════════════════════════════════════════════════════════════════
SOUL_OUT="${HERMES_HOME}/SOUL.md"
SOUL_PERSONAL="${HERMES_HOME}/SOUL-personal.md"

[[ -f "${SOUL_PERSONAL}" ]] || {
    cat > "${SOUL_PERSONAL}" <<'EOF'
## 个人偏好 (L4)
- 使用中文回复,简洁高效
- 代码输出使用绝对路径
EOF
    chown hermes:hermes "${SOUL_PERSONAL}"
}

{
    [[ -f "/opt/skills/L1/SOUL-company.md"              ]] && cat "/opt/skills/L1/SOUL-company.md"
    [[ -f "/opt/skills/L2/${DOMAIN}/SOUL-${DOMAIN}.md"  ]] && cat "/opt/skills/L2/${DOMAIN}/SOUL-${DOMAIN}.md"
    [[ -f "/opt/skills/L3/${DOMAIN}/${ROLE}/SOUL-${ROLE}.md" ]] && cat "/opt/skills/L3/${DOMAIN}/${ROLE}/SOUL-${ROLE}.md"
    cat "${SOUL_PERSONAL}"
} > "${SOUL_OUT}" 2>/dev/null || true
chown hermes:hermes "${SOUL_OUT}" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# 5. 启动 sshd (root) + hermes-web-ui (hermes)
# ══════════════════════════════════════════════════════════════════
# sshd 以 root 独立进程启动, 监听 8700
/usr/sbin/sshd -D -p "${SSH_PORT}" &
SSHD_PID=$!
log "sshd started  pid=${SSHD_PID}  port=${SSH_PORT}"

# 进程退出时同步结束 sshd
trap 'log "terminating..."; kill -TERM ${SSHD_PID} 2>/dev/null || true; wait' TERM INT

# ══════════════════════════════════════════════════════════════════
# 启动 Banner
# ══════════════════════════════════════════════════════════════════
HOST_HINT="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
cat <<BANNER

╔══════════════════════════════════════════════════════════════════╗
║             Hermes Enterprise Container — Ready                  ║
╠══════════════════════════════════════════════════════════════════╣
║  员工:     ${EMPLOYEE_NAME}  (seq=${EMPLOYEE_SEQ})
║  域/角色:  ${DOMAIN} / ${ROLE}
║  Provider: ${HERMES_DEFAULT_PROVIDER}  /  ${HERMES_DEFAULT_MODEL}
╠──────────────────────────────────────────────────────────────────╣
║  容器内端口:
║   ${SSH_PORT}       SSH
║   ${WEBUI_PORT}     hermes-web-ui
║   8702-8709  gateway / webhook
║   8710-8799  临时 web 服务 (bind 0.0.0.0)
║
║  宿主端口(请在 compose 中按员工 seq 映射):
║   eg. ports: "BASE-BASE_END:8700-8799"  (100 个)
║
║  数据卷:
║   /opt/data       ~/.hermes profile (config.yaml / .env / skills L4 / sessions)
║   /workspace      工作目录 (projects / outputs / downloads)
║   /opt/skills/L1  公司层 (只读)
║   /opt/skills/L2  域层   (只读)
║   /opt/skills/L3  角色层 (只读)
║
║  常用命令:
║   hermes                  交互式对话
║   hermes config           查看配置
║   hermes model            切换模型
║   hermes gateway run      启动网关 (钉钉等)
╚══════════════════════════════════════════════════════════════════╝

BANNER

# ── hermes-web-ui ─────────────────────────────────────────────────
# 用 gosu 降到 hermes 跑,避免 node 以 root 身份运行
cd "${WEBUI_DIR}"
export HOME=/home/hermes
export HERMES_HOME
export PORT="${WEBUI_PORT}"
export HERMES_BIN

log "starting hermes-web-ui on :${WEBUI_PORT}"
exec gosu hermes:hermes node dist/server/index.js
