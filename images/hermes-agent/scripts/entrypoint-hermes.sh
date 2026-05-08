#!/bin/bash
# =============================================================================
# Hermes Agent Container — Entrypoint
# 启动时在控制台打印完整的使用信息
# =============================================================================

set -e

HERMES_HOME="/home/hermes"
export HERMES_HOME
VENV="${HERMES_HOME}/.venv"
export PATH="${VENV}/bin:${HERMES_HOME}/.local/bin:${PATH}"

fix_ownership() {
    chown -R hermes:hermes "${HERMES_HOME}/.ssh" "${HERMES_HOME}/.ssh-pub" "${HERMES_HOME}/.hermes" "${HERMES_HOME}/workspace" 2>/dev/null || true
}

# ── 默认值 ──
EMPLOYEE_NAME="${EMPLOYEE_NAME:-unknown}"
EMPLOYEE_SEQ="${EMPLOYEE_SEQ:-??}"
SSH_PORT="${SSH_PORT:-22}"
WEB_PORT_START="${WEB_PORT_START:-10002}"
WEB_PORT_END="${WEB_PORT_END:-10099}"
CLAUDE_HOST="${CLAUDE_HOST:-not configured}"
CLAUDE_SSH_PORT="${CLAUDE_SSH_PORT:-22}"
HERMES_SSH_PASS="${HERMES_SSH_PASS:-hermes}"
DOMAIN="${DOMAIN:-N/A}"
ROLE="${ROLE:-N/A}"

# 获取宿主机 IP（尝试多种方式）
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")

# ══════════════════════════════════════════════════════════════════
# 1. SSH 配置
# ══════════════════════════════════════════════════════════════════

echo "hermes:${HERMES_SSH_PASS}" | sudo chpasswd

if [ -d "/run/secrets" ]; then
    for pubkey in /run/secrets/ssh_pubkey_*; do
        [ -f "$pubkey" ] && cat "$pubkey" >> "${HERMES_HOME}/.ssh/authorized_keys"
    done
fi
if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "$SSH_PUBLIC_KEY" >> "${HERMES_HOME}/.ssh/authorized_keys"
fi
[ -f "${HERMES_HOME}/.ssh/authorized_keys" ] && chmod 600 "${HERMES_HOME}/.ssh/authorized_keys"

# SSH Client (Hermes → Claude Code)
SSH_KEY="${HERMES_HOME}/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
fi
cat > "${HERMES_HOME}/.ssh/config" << 'SSHEOF'
Host claude-*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ConnectTimeout 10
SSHEOF
chmod 600 "${HERMES_HOME}/.ssh/config"
mkdir -p "${HERMES_HOME}/.ssh-pub"
cp "${SSH_KEY}.pub" "${HERMES_HOME}/.ssh-pub/hermes.pub"

# ══════════════════════════════════════════════════════════════════
# 2. 自动配置 Provider + API Key
# ══════════════════════════════════════════════════════════════════

ENV_FILE="${HERMES_HOME}/.hermes/.env"
CONFIG_FILE="${HERMES_HOME}/.hermes/config.yaml"
COMPANY_PROVIDERS="/home/hermes/config/company-providers.yaml"

mkdir -p "${HERMES_HOME}/.hermes/skills" "${HERMES_HOME}/.hermes/logs"
fix_ownership

# Provider 自动配置
python3 << 'PYEOF'
import os, sys, yaml
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/home/hermes"))
CONFIG_FILE = HERMES_HOME / ".hermes" / "config.yaml"
ENV_FILE = HERMES_HOME / ".hermes" / ".env"
COMPANY_PROVIDERS = Path("/home/hermes/config/company-providers.yaml")
user_override = HERMES_HOME / ".hermes" / ".user_provider_override"

if not COMPANY_PROVIDERS.exists():
    print("[provider] company-providers.yaml not found, skipping")
    sys.exit(0)

if user_override.exists():
    print("[provider] User override detected, keeping user config")
    sys.exit(0)

with open(COMPANY_PROVIDERS) as f:
    company = yaml.safe_load(f)

providers = company.get("providers", {})
priority = company.get("default_provider_priority", [])

available = []
for name in priority:
    p = providers.get(name)
    if not p:
        continue
    env_key = p.get("api_key_env", "")
    api_key = os.environ.get(env_key, "")
    if api_key and not api_key.startswith("xxx"):
        available.append((name, p, api_key))

if not available:
    print("[provider] No API key found. Set one in .env:")
    for name in priority:
        p = providers.get(name, {})
        print(f"  {p.get('api_key_env', name)}")
    sys.exit(0)

selected_name, selected, api_key = available[0]
model_name = selected.get("model", "")
base_url = selected.get("base_url", "")

existing_config = {}
if CONFIG_FILE.exists():
    with open(CONFIG_FILE) as f:
        existing_config = yaml.safe_load(f) or {}

config = existing_config.copy()
config["model"] = model_name

if base_url:
    if "providers" not in config:
        config["providers"] = {}
    config["providers"][model_name.split("/")[0]] = {"base_url": base_url}

with open(CONFIG_FILE, "w") as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

llm_env_keys = {p.get("api_key_env") for p in providers.values()}
llm_env_keys.discard(None)

env_lines = []
if ENV_FILE.exists():
    with open(ENV_FILE) as f:
        env_lines = [l for l in f.readlines() if not any(l.startswith(k + "=") for k in llm_env_keys)]

for name, p, key in available:
    env_key = p.get("api_key_env", "")
    if env_key and not any(l.startswith(env_key + "=") for l in env_lines):
        env_lines.append(f"{env_key}={key}\n")

for var in ["BRAVE_API_KEY", "GOOGLE_API_KEY", "GITHUB_TOKEN", "DINGTALK_APP_KEY", "DINGTALK_APP_SECRET", "CLAUDE_HOST", "CLAUDE_SSH_PORT"]:
    val = os.environ.get(var, "")
    if val and not any(l.startswith(var + "=") for l in env_lines):
        env_lines.append(f"{var}={val}\n")

with open(ENV_FILE, "w") as f:
    f.writelines(env_lines)

os.chown(CONFIG_FILE, 1000, 1000)
os.chmod(CONFIG_FILE, 0o644)
os.chown(ENV_FILE, 1000, 1000)
os.chmod(ENV_FILE, 0o600)

# 输出供 banner 使用
print(f"PROVIDER_NAME={selected.get('display_name', selected_name)}")
print(f"PROVIDER_MODEL={model_name}")

PYEOF

chown hermes:hermes "$ENV_FILE" "$CONFIG_FILE" 2>/dev/null || true
chmod 600 "$ENV_FILE"
fix_ownership

# 读取 provider 信息
PROVIDER_NAME=$(python3 -c "
import yaml; f=open('/home/hermes/config/company-providers.yaml'); c=yaml.safe_load(f)
import os
for n in c.get('default_provider_priority',[]):
    p=c['providers'].get(n)
    if p and os.environ.get(p['api_key_env'],'') and not os.environ.get(p['api_key_env'],'').startswith('xxx'):
        print(p.get('display_name',n)); break
" 2>/dev/null || echo "Unknown")

PROVIDER_MODEL=$(python3 -c "
import yaml; f=open('/home/hermes/config/company-providers.yaml'); c=yaml.safe_load(f)
import os
for n in c.get('default_provider_priority',[]):
    p=c['providers'].get(n)
    if p and os.environ.get(p['api_key_env'],'') and not os.environ.get(p['api_key_env'],'').startswith('xxx'):
        print(p.get('model','')); break
" 2>/dev/null || echo "")

# ══════════════════════════════════════════════════════════════════
# 3. 构建 SOUL.md
# ══════════════════════════════════════════════════════════════════

SOUL_FILE="${HERMES_HOME}/.hermes/SOUL.md"
if [ ! -f "$SOUL_FILE" ]; then
    cat > "$SOUL_FILE" << 'EOF'
# Hermes AI Assistant
## 基本行为
- 使用中文回复，简洁高效
- 代码输出使用绝对路径
## 安全合规
- 不泄露 API 密钥
- 执行危险命令前必须确认
EOF
fi

if [ -d "/opt/skills/L1" ]; then
    {
        [ -f "/opt/skills/L1/SOUL-company.md" ] && cat /opt/skills/L1/SOUL-company.md
        [ -f "/opt/skills/L2/SOUL-${DOMAIN}.md" ] && cat /opt/skills/L2/SOUL-${DOMAIN}.md
        [ -f "/opt/skills/L3/SOUL-${ROLE}.md" ] && cat /opt/skills/L3/SOUL-${ROLE}.md
        [ -f "${HERMES_HOME}/.hermes/SOUL-personal.md" ] && cat ${HERMES_HOME}/.hermes/SOUL-personal.md
    } > "$SOUL_FILE" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════
# 4. 启动 SSH + 打印信息
# ══════════════════════════════════════════════════════════════════

sudo /usr/sbin/sshd

cat << BANNER

╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║               Hermes Agent — 启动成功                            ║
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  员工:  ${EMPLOYEE_NAME} (序号: ${EMPLOYEE_SEQ})
║  域:    ${DOMAIN}
║  角色:  ${ROLE}
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  ┌─ SSH 接入 ──────────────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  ssh hermes@${HOST_IP} -p ${SSH_PORT}
║  │  密码: ${HERMES_SSH_PASS}
║  │                                                              │ ║
║  │  Claude Code 直连:                                           │ ║
║  │  ssh claude@${HOST_IP} -p ${CLAUDE_SSH_PORT}
║  │  密码: claude                                                │ ║
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ Web 服务端口 ──────────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  可用端口: ${WEB_PORT_START} - ${WEB_PORT_END} (共 98 个)
║  │                                                              │ ║
║  │  使用方法 (容器内绑定 0.0.0.0):                              │ ║
║  │    python3 -m http.server ${WEB_PORT_START} --bind 0.0.0.0
║  │    flask run --host 0.0.0.0 --port ${WEB_PORT_START}
║  │    jupyter notebook --port ${WEB_PORT_START} --ip 0.0.0.0
║  │    npx serve -l ${WEB_PORT_START}
║  │                                                              │ ║
║  │  局域网访问: http://${HOST_IP}:${WEB_PORT_START}
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ 模型配置 ──────────────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  当前 Provider: ${PROVIDER_NAME}
║  │  当前模型:      ${PROVIDER_MODEL:-未配置}
║  │                                                              │ ║
║  │  切换模型:     hermes model                                  │ ║
║  │  查看配置:     hermes config                                 │ ║
║  │  测试对话:     hermes chat -q "你好"                         │ ║
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
║  ┌─ 常用命令 ──────────────────────────────────────────────────┐ ║
║  │                                                              │ ║
║  │  hermes                        交互式对话                    │ ║
║  │  hermes chat -q "问题"         单次查询                      │ ║
║  │  hermes doctor                 环境诊断                      │ ║
║  │  hermes gateway status         钉钉连接状态                  │ ║
║  │  hermes skills list            查看技能                      │ ║
║  │  hermes tools list             查看工具                      │ ║
║  │                                                              │ ║
║  │  远程调用 Claude Code:                                       │ ║
║  │  ssh claude@${CLAUDE_HOST} "claude -p '任务描述'"            │ ║
║  │                                                              │ ║
║  └──────────────────────────────────────────────────────────────┘ ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

BANNER

# ══════════════════════════════════════════════════════════════════
# 5. 启动模式
# ══════════════════════════════════════════════════════════════════

if [ "${HERMES_MODE}" = "gateway" ]; then
    echo "[启动] Hermes Gateway 模式..."
    exec su - hermes -c "cd /home/hermes/workspace && hermes gateway run"
else
    echo "[启动] 交互模式 — 输入 hermes 开始对话"
    exec tail -f /dev/null
fi
