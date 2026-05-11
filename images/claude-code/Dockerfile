# =============================================================================
# Claude Code CLI — 独立镜像
# 包含: SSH Server(用户接入 + Hermes远程调用) + Claude Code CLI
# 模型通过 DEEPSEEK_MODEL 环境变量配置，写入 settings.json
# =============================================================================

FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/node:20

LABEL maintainer="Hermes Enterprise Platform"
LABEL description="Claude Code CLI — SSH Accessible Coding Agent"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# ── 系统依赖 ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git ca-certificates \
    vim nano tmux jq htop \
    dnsutils iputils-ping net-tools \
    openssh-server openssh-client \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ── 安装 Claude Code CLI ──
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# ── 常用全局 npm 工具 ──
RUN npm install -g typescript ts-node 2>/dev/null || true \
    && npm cache clean --force

# ── 创建 claude 用户（非 root，UID=1000）──
RUN groupadd -g 1000 claude \
    && useradd -u 1000 -g claude -m -s /bin/bash claude \
    && echo "claude:claude" | chpasswd \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# ── SSH Server 配置 ──
RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers claude" >> /etc/ssh/sshd_config

USER claude
WORKDIR /home/claude

# ── Claude Code 配置目录 + SSH 目录 ──
RUN mkdir -p \
    /home/claude/.claude \
    /home/claude/.ssh \
    /home/claude/workspace \
    && chmod 700 /home/claude/.ssh

# ── Claude Code 默认 settings.json
# model 字段在 entrypoint 运行时由 DEEPSEEK_MODEL 环境变量覆盖写入
RUN cat > /home/claude/.claude/settings.json << 'EOF'
{
  "model": "deepseek-v4-pro",
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Write",
      "Bash",
      "WebSearch",
      "WebFetch"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(:(){ :|:& };:)"
    ]
  }
}
EOF

# ── 启动脚本 ──
COPY --chown=claude:claude scripts/entrypoint-claude.sh /home/claude/entrypoint.sh
RUN chmod +x /home/claude/entrypoint.sh

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD claude --version || exit 1

WORKDIR /home/claude/workspace
ENTRYPOINT ["/home/claude/entrypoint.sh"]
