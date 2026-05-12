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

# ───── 模型渠道配置文件 ─────
# 首次启动时从该 YAML 读取可用 provider 列表、默认模型、API key 环境变量名。
# 优先使用 /opt/data/company-providers.yaml，便于运维通过 volume 覆盖；否则用镜像内置默认配置。
COMPANY_PROVIDERS_FILE="${COMPANY_PROVIDERS_FILE:-}"
if [[ -z "${COMPANY_PROVIDERS_FILE}" ]]; then
    if [[ -f "${HERMES_HOME}/company-providers.yaml" ]]; then
        COMPANY_PROVIDERS_FILE="${HERMES_HOME}/company-providers.yaml"
    else
        COMPANY_PROVIDERS_FILE="/opt/hermes/company-providers.yaml"
    fi
fi
# 兼容覆盖：如显式传入 HERMES_DEFAULT_PROVIDER / HERMES_DEFAULT_MODEL，则优先于配置文件选择结果。
HERMES_DEFAULT_PROVIDER="${HERMES_DEFAULT_PROVIDER:-}"
HERMES_DEFAULT_MODEL="${HERMES_DEFAULT_MODEL:-}"
SELECTED_PROVIDER="${HERMES_DEFAULT_PROVIDER:-}"
SELECTED_MODEL="${HERMES_DEFAULT_MODEL:-}"

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
#   - 首次启动: 从 company-providers.yaml 读取多个模型渠道定义
#   - 根据配置文件 priority + 实际传入的 API key 自动选择默认 provider/model
#   - 写入所有非空 provider key 和 extra_env_vars 到 .env
#   - 生成后写 sentinel, 后续用户自改 config.yaml / .env 不被覆盖
#   - 运维可通过 /opt/data/company-providers.yaml 或 COMPANY_PROVIDERS_FILE 覆盖默认配置

ENV_FILE="${HERMES_HOME}/.env"
CFG_FILE="${HERMES_HOME}/config.yaml"
PROVIDER_STATE="$(mktemp)"

if [[ ! -f "${SENTINEL}" ]]; then
    log "首次启动,从 ${COMPANY_PROVIDERS_FILE} 读取模型渠道配置"

    if [[ ! -f "${COMPANY_PROVIDERS_FILE}" ]]; then
        log "WARN: 未找到模型渠道配置文件 ${COMPANY_PROVIDERS_FILE}, 使用 deepseek/deepseek-v4-pro 兜底"
    fi

    COMPANY_PROVIDERS_FILE="${COMPANY_PROVIDERS_FILE}" \
    ENV_FILE="${ENV_FILE}" \
    CFG_FILE="${CFG_FILE}" \
    EMPLOYEE_NAME="${EMPLOYEE_NAME}" \
    EMPLOYEE_SEQ="${EMPLOYEE_SEQ}" \
    DOMAIN="${DOMAIN}" \
    ROLE="${ROLE}" \
    HERMES_DEFAULT_PROVIDER="${HERMES_DEFAULT_PROVIDER}" \
    HERMES_DEFAULT_MODEL="${HERMES_DEFAULT_MODEL}" \
    PROVIDER_STATE="${PROVIDER_STATE}" \
    python3 - <<'PY'
import os
from pathlib import Path

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML unavailable: {exc}")

providers_file = Path(os.environ.get("COMPANY_PROVIDERS_FILE") or "/opt/hermes/company-providers.yaml")
env_file = Path(os.environ["ENV_FILE"])
cfg_file = Path(os.environ["CFG_FILE"])
state_file = Path(os.environ["PROVIDER_STATE"])

if providers_file.exists():
    data = yaml.safe_load(providers_file.read_text(encoding="utf-8")) or {}
else:
    data = {}

providers = data.get("providers") or {
    "deepseek": {
        "display_name": "DeepSeek",
        "model": "deepseek-v4-pro",
        "api_key_env": "DEEPSEEK_API_KEY",
        "base_url": "https://api.deepseek.com",
    }
}
priority = data.get("default_provider_priority") or list(providers.keys())
extra_env_vars = data.get("extra_env_vars") or []

forced_provider = (os.environ.get("HERMES_DEFAULT_PROVIDER") or "").strip()
forced_model = (os.environ.get("HERMES_DEFAULT_MODEL") or "").strip()

available = []
for name in priority:
    spec = providers.get(name) or {}
    key_env = spec.get("api_key_env")
    if key_env and os.environ.get(key_env):
        available.append(name)

if forced_provider:
    selected = forced_provider
elif available:
    selected = available[0]
elif priority:
    selected = priority[0]
else:
    selected = "deepseek"

selected_spec = providers.get(selected) or {}
selected_model = forced_model or selected_spec.get("model") or "deepseek-v4-pro"

# .env: 写入所有 provider 的非空 key + extra_env_vars + 固定 gateway 端口。
# 这样用户可默认拥有多个模型渠道，进容器后通过 hermes model/config 切换。
lines = []
seen = set()
for spec in providers.values():
    key_env = spec.get("api_key_env")
    if key_env and key_env not in seen and os.environ.get(key_env):
        lines.append(f"{key_env}={os.environ[key_env]}")
        seen.add(key_env)
for var in extra_env_vars:
    if var and var not in seen and os.environ.get(var):
        lines.append(f"{var}={os.environ[var]}")
        seen.add(var)
# 使用 hermes-agent 官方默认 API server 端口 8642。
# 容器外如需企业连续端口规划，可将宿主机 BASE+2 映射到容器 8642。
for var, val in (("API_SERVER_HOST", "127.0.0.1"),):
    lines.append(f"{var}={val}")
env_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
env_file.chmod(0o600)

cfg = {
    "provider": selected,
    "model": selected_model,
    "providers": {},
    "skills": {
        "external_dirs": [
            "/opt/skills/L1",
            "/opt/skills/L2",
            "/opt/skills/L3",
        ]
    },
    "platforms": {
        "api_server": {
            "enabled": True,
            "key": "",
            "cors_origins": "*",
            "extra": {"host": "127.0.0.1", "port": 8642},
        },
        "dingtalk": {"enabled": False},
    },
    "employee": {
        "name": os.environ.get("EMPLOYEE_NAME", "unknown"),
        "seq": os.environ.get("EMPLOYEE_SEQ", "0"),
        "domain": os.environ.get("DOMAIN", "default"),
        "role": os.environ.get("ROLE", "default"),
    },
}

for name, spec in providers.items():
    item = {}
    for key in ("base_url", "context_length", "display_name"):
        if spec.get(key) is not None:
            item[key] = spec[key]
    if spec.get("api_key_env"):
        item["api_key_env"] = spec["api_key_env"]
    if spec.get("model"):
        item["model"] = spec["model"]
    cfg["providers"][name] = item

header = (
    "# 由 hermes-entrypoint.sh 首次生成。用户可自行编辑,容器重启不覆盖。\n"
    f"# 模型渠道来源: {providers_file}\n"
)
cfg_file.write_text(header + yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False), encoding="utf-8")

state_file.write_text(f"{selected}\n{selected_model}\n", encoding="utf-8")
PY

    SELECTED_PROVIDER="$(sed -n '1p' "${PROVIDER_STATE}" 2>/dev/null || true)"
    SELECTED_MODEL="$(sed -n '2p' "${PROVIDER_STATE}" 2>/dev/null || true)"
    SELECTED_PROVIDER="${SELECTED_PROVIDER:-deepseek}"
    SELECTED_MODEL="${SELECTED_MODEL:-deepseek-v4-pro}"

    chown hermes:hermes "${ENV_FILE}" "${CFG_FILE}"
    touch "${SENTINEL}"
    chown hermes:hermes "${SENTINEL}"
    log "provider 配置已写入 ${CFG_FILE} / ${ENV_FILE} (${SELECTED_PROVIDER}/${SELECTED_MODEL})"
else
    log "检测到 ${SENTINEL}, 跳过 provider 首次注入 (用户接管)"
    if [[ -f "${CFG_FILE}" ]]; then
        SELECTED_PROVIDER="$(python3 - <<PY 2>/dev/null || true
import yaml
try:
    data=yaml.safe_load(open('${CFG_FILE}', encoding='utf-8')) or {}
    print(data.get('provider',''))
except Exception:
    pass
PY
)"
        SELECTED_MODEL="$(python3 - <<PY 2>/dev/null || true
import yaml
try:
    data=yaml.safe_load(open('${CFG_FILE}', encoding='utf-8')) or {}
    print(data.get('model',''))
except Exception:
    pass
PY
)"
    fi
fi
rm -f "${PROVIDER_STATE}"
SELECTED_PROVIDER="${SELECTED_PROVIDER:-${HERMES_DEFAULT_PROVIDER:-deepseek}}"
SELECTED_MODEL="${SELECTED_MODEL:-${HERMES_DEFAULT_MODEL:-deepseek-v4-pro}}"

# 将首次生成/用户维护的 .env 导出到当前进程环境。
# hermes-web-ui 的 GatewayManager 启动 `hermes gateway run` 时继承 process.env；
# 这里用 Python 安全解析 key=value，避免 source .env 执行任意 shell。
if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r kv; do
        [[ -z "${kv}" ]] && continue
        export "${kv}"
    done < <(ENV_FILE="${ENV_FILE}" python3 - <<'PY'
import os, re
from pathlib import Path
p = Path(os.environ['ENV_FILE'])
for raw in p.read_text(encoding='utf-8').splitlines():
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, val = line.split('=', 1)
    key = key.strip()
    if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', key):
        continue
    val = val.strip()
    if (len(val) >= 2) and ((val[0] == val[-1]) and val[0] in {'"', "'"}):
        val = val[1:-1]
    print(f'{key}={val}')
PY
    )
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
║  Provider: ${SELECTED_PROVIDER}  /  ${SELECTED_MODEL}
╠──────────────────────────────────────────────────────────────────╣
║  容器内端口:
║   ${SSH_PORT}       SSH
║   ${WEBUI_PORT}     hermes-web-ui
║   8642       gateway / API server (default)
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
