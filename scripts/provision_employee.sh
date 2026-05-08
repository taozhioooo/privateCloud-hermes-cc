#!/bin/bash
# =============================================================================
# Hermes Enterprise — 员工开通脚本
# 用法: ./provision_employee.sh <用户名> <域> <角色> <序号> [SSH公钥或公钥文件路径]
# 示例: ./provision_employee.sh zhaoliu engineering senior-engineer 04 ~/.ssh/id_ed25519.pub
#
# 端口自动计算:
#   Hermes: 10N01=SSH, 10N02-10N99=Web  (N=序号)
#   Claude: 11N01=SSH, 11N02-11N99=Web
# =============================================================================

set -e

USERNAME="$1"
DOMAIN="${2:-engineering}"
ROLE="${3:-engineer}"
SEQ="${4}"
SSH_PUB_INPUT="${5:-}"
SSH_PUBLIC_KEY=""

if [ -n "$SSH_PUB_INPUT" ]; then
    if [ -f "$SSH_PUB_INPUT" ]; then
        SSH_PUBLIC_KEY=$(tr -d '\r\n' < "$SSH_PUB_INPUT")
    else
        SSH_PUBLIC_KEY="$SSH_PUB_INPUT"
    fi
fi

if [ -z "$USERNAME" ] || [ -z "$SEQ" ]; then
    echo "用法: $0 <用户名> [域] [角色] <序号(01-70)> [SSH公钥或公钥文件路径]"
    echo ""
    echo "示例:"
    echo "  $0 zhaoliu engineering senior-engineer 04 ~/.ssh/id_ed25519.pub"
    echo "  $0 sunqi marketing product-manager 05 \"ssh-ed25519 AAAA... user@host\""
    echo ""
    echo "端口分配 (序号 N):"
    echo "  Hermes SSH:  10N01   (如 10001)"
    echo "  Hermes Web:  10N02-10N99 (如 10002-10099)"
    echo "  Claude SSH:  11N01   (如 11001)"
    echo "  Claude Web:  11N02-11N99 (如 11002-11099)"
    exit 1
fi

COMPOSE_FILE="docker-compose.yml"

if grep -q "hermes-${USERNAME}:" "$COMPOSE_FILE" 2>/dev/null; then
    echo "[ERROR] 员工 ${USERNAME} 已存在"
    exit 1
fi

if [ -n "$SSH_PUBLIC_KEY" ] && ! printf '%s' "$SSH_PUBLIC_KEY" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh.com) '; then
    echo "[ERROR] SSH 公钥格式不正确"
    exit 1
fi

SSH_PUBLIC_KEY_YAML=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\r\n"))[1:-1])' <<< "$SSH_PUBLIC_KEY")

SEQ_NUM=$((10#$SEQ))
H_BASE=$((10001 + (SEQ_NUM - 1) * 100))
C_BASE=$((11001 + (SEQ_NUM - 1) * 100))
H_SSH="$H_BASE"
H_WEB_START=$((H_BASE + 1))
H_WEB_END=$((H_BASE + 98))
C_SSH="$C_BASE"
C_WEB_START=$((C_BASE + 1))
C_WEB_END=$((C_BASE + 98))

cat << INFO
============================================
  开通员工: ${USERNAME} (序号: ${SEQ})
  域: ${DOMAIN} | 角色: ${ROLE}
────────────────────────────────────────
  Hermes:
    SSH:  ${H_SSH}
    Web:  ${H_WEB_START}-${H_WEB_END}
  Claude Code:
    SSH:  ${C_SSH}
    Web:  ${C_WEB_START}-${C_WEB_END}
────────────────────────────────────────
  局域网访问:
    ssh hermes@服务器 -p ${H_SSH}
    ssh claude@服务器 -p ${C_SSH}
============================================
INFO

INSERT_LINE=$(grep -n "^networks:" "$COMPOSE_FILE" | head -1 | cut -d: -f1)

TMPFILE=$(mktemp)
cat > "$TMPFILE" << EOF

  # ═══════════════════════════════════════════
  #  员工: ${USERNAME} (序号: ${SEQ})
  #  Hermes: ${H_SSH}=SSH, ${H_WEB_START}-${H_WEB_END}=Web
  #  Claude: ${C_SSH}=SSH, ${C_WEB_START}-${C_WEB_END}=Web
  # ═══════════════════════════════════════════

  hermes-${USERNAME}:
    image: registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:latest
    container_name: hermes-${USERNAME}
    restart: unless-stopped
    hostname: hermes-${USERNAME}
    environment:
      - DEEPSEEK_API_KEY=\${DEEPSEEK_API_KEY:-}
      - MINIMAX_API_KEY=\${MINIMAX_API_KEY:-}
      - DASHSCOPE_API_KEY=\${DASHSCOPE_API_KEY:-}
      - ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-}
      - OPENROUTER_API_KEY=\${OPENROUTER_API_KEY:-}
      - CUSTOM_API_KEY=\${CUSTOM_API_KEY:-}
      - BRAVE_API_KEY=\${BRAVE_API_KEY:-}
      - GOOGLE_API_KEY=\${GOOGLE_API_KEY:-}
      - GITHUB_TOKEN=\${GITHUB_TOKEN:-}
      - DINGTALK_APP_KEY=\${DINGTALK_APP_KEY:-}
      - DINGTALK_APP_SECRET=\${DINGTALK_APP_SECRET:-}
$(if [ -n "$SSH_PUBLIC_KEY" ]; then echo "      - SSH_PUBLIC_KEY=\"${SSH_PUBLIC_KEY_YAML}\""; fi)
      - EMPLOYEE_NAME=${USERNAME}
      - EMPLOYEE_SEQ=${SEQ}
      - DOMAIN=${DOMAIN}
      - ROLE=${ROLE}
      - SSH_PORT=${H_SSH}
      - WEB_PORT_START=${H_WEB_START}
      - WEB_PORT_END=${H_WEB_END}
      - CLAUDE_HOST=claude-${USERNAME}
      - CLAUDE_SSH_PORT=${C_SSH}
      - HERMES_SSH_PASS=hermes
      - HERMES_MODE=gateway
    ports:
      - "${H_SSH}-${H_WEB_END}:${H_SSH}-${H_WEB_END}"
    volumes:
      - ${USERNAME}_hermes:/home/hermes/.hermes
      - ${USERNAME}_workspace:/home/hermes/workspace
      - ${USERNAME}_ssh_pub:/home/hermes/.ssh-pub
      - ./skills/L1:/opt/skills/L1:ro
      - ./skills/L2:/opt/skills/L2:ro
      - ./skills/L3:/opt/skills/L3:ro
    networks:
      - hermes-net
    depends_on:
      redis:
        condition: service_healthy
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2G
    security_opt:
      - no-new-privileges:true

  claude-${USERNAME}:
    image: registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:latest
    container_name: claude-${USERNAME}
    restart: unless-stopped
    hostname: claude-${USERNAME}
    environment:
      - ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-}
      - CLAUDE_SSH_PASS=claude
$(if [ -n "$SSH_PUBLIC_KEY" ]; then echo "      - SSH_PUBLIC_KEY=\"${SSH_PUBLIC_KEY_YAML}\""; fi)
      - EMPLOYEE_NAME=${USERNAME}
      - EMPLOYEE_SEQ=${SEQ}
      - SSH_PORT=${C_SSH}
      - WEB_PORT_START=${C_WEB_START}
      - WEB_PORT_END=${C_WEB_END}
      - HERMES_HOST=hermes-${USERNAME}
    ports:
      - "${C_SSH}-${C_WEB_END}:${C_SSH}-${C_WEB_END}"
    volumes:
      - ${USERNAME}_workspace:/home/claude/workspace
      - ${USERNAME}_ssh_pub:/hermes-ssh-pub:ro
    networks:
      - hermes-net
    deploy:
      resources:
        limits:
          cpus: "4.0"
          memory: 4G
    security_opt:
      - no-new-privileges:true
EOF

head -n $((INSERT_LINE - 1)) "$COMPOSE_FILE" > "${COMPOSE_FILE}.new"
cat "$TMPFILE" >> "${COMPOSE_FILE}.new"
tail -n +"$INSERT_LINE" "$COMPOSE_FILE" >> "${COMPOSE_FILE}.new"
mv "${COMPOSE_FILE}.new" "$COMPOSE_FILE"
rm "$TMPFILE"

for VOL in "${USERNAME}_hermes" "${USERNAME}_workspace" "${USERNAME}_ssh_pub"; do
    if ! grep -q "  ${VOL}:" "$COMPOSE_FILE"; then
        sed -i "/^volumes:/a\\  ${VOL}:" "$COMPOSE_FILE"
    fi
done

echo ""
echo "[OK] 员工 ${USERNAME} 已添加"
echo ""
echo "启动:"
echo "  docker compose pull hermes-${USERNAME} claude-${USERNAME}"
echo "  docker compose up -d hermes-${USERNAME} claude-${USERNAME}"
echo ""
echo "SSH:"
echo "  ssh hermes@服务器 -p ${H_SSH}    # Hermes"
echo "  ssh claude@服务器 -p ${C_SSH}    # Claude Code"
echo ""
echo "Web 服务:"
echo "  Hermes: http://服务器:${H_WEB_START} ~ ${H_WEB_END}"
echo "  Claude: http://服务器:${C_WEB_START} ~ ${C_WEB_END}"
