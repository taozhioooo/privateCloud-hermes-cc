# =============================================================================
# Claude Code CLI — 独立镜像
# 包含: SSH Server(用户接入 + Hermes远程调用) + Claude Code CLI
# =============================================================================

FROM ubuntu:24.04

LABEL maintainer="Hermes Enterprise Platform"
LABEL description="Claude Code CLI — SSH Accessible Coding Agent"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# ── 系统依赖 ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git ca-certificates gnupg lsb-release \
    python3 python3-pip python3-venv \
    vim nano tmux jq htop \
    build-essential \
    dnsutils iputils-ping net-tools \
    openssh-server openssh-client \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ── 安装 Node.js 22.x LTS ──
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── 安装 Claude Code CLI ──
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# ── 常用全局 npm 工具 ──
RUN npm install -g typescript ts-node 2>/dev/null || true \
    && npm cache clean --force

# ── 创建 claude 用户 ──
RUN groupadd -r claude \
    && useradd -r -g claude -m -s /bin/bash -G sudo claude \
    && echo "claude:claude" | chpasswd \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/claude

USER claude
WORKDIR /home/claude

# ── Claude Code 配置目录 + SSH 目录 ──
RUN mkdir -p \
    /home/claude/.claude \
    /home/claude/.ssh \
    /home/claude/workspace

RUN chmod 700 /home/claude/.ssh

# ── Claude Code 默认权限（允许远程调用时自动审批）──
RUN cat > /home/claude/.claude/settings.json << 'EOF'
{
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

# ── SSH Server 配置 ──
USER root
RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers claude" >> /etc/ssh/sshd_config

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD claude --version || exit 1

WORKDIR /home/claude/workspace
ENTRYPOINT ["/home/claude/entrypoint.sh"]
